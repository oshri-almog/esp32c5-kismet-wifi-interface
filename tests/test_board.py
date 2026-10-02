"""Offline tests for the Python remote helper's link to a board (esp32c5_kismet/board.py): stream framing,
frames that carry the restart signature, channel specs, port names, the port lock and telling from
/proc/locks that another process holds a port, the handshake against a fake board ("capturing" only once
the header has the radio's link type, and no longer once the port goes away; asked again until capturing, a
board that sends part of a header and goes quiet included; every status by the source's name, in the C
helper's words), knowing a board again by its MAC, and whether a port is there.

No board, no Kismet needed; pyserial is. The streams are the ones tests/c/test_parser.c gives the C helper,
so the two helpers are held to the same rule. Windows' port names are tested everywhere, the platform being
passed in. The pseudo-terminal and lock cases run on POSIX only, and print SKIP elsewhere. Of those, the
tty exclusive mode (TIOCEXCL) and /proc/locks cases run on Linux only, and are left out without a word on
the other POSIX systems; an open refused because another helper has the tty in exclusive mode runs only as
root with capsh, which runs that open without CAP_SYS_ADMIN (exclusive mode lets that capability through),
and prints SKIP otherwise. Each check prints PASS or FAIL; the first FAIL exits with status 1, and a clean
run ends with ALL OK. More on the wiki page Development-and-Testing.

    python tests/test_board.py
"""
import os
import random
import re
import struct
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import serial  # noqa: E402
from esp32c5_kismet import board as bd  # noqa: E402

NONCE = b"deadbeef"
CHUNKS = (1, 3, 7, 11, 64, 4096, 1 << 20)
MAGIC8 = bytes.fromhex("d4c3b2a102000400")


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        sys.exit(1)


def raises(exc, fn, *args):
    try:
        fn(*args)
    except exc as e:
        return e
    return None


def global_hdr(linktype=127):
    return struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, linktype)


GLOBAL = global_hdr(127)


def marker(nonce=None):
    """"\\n<<START>> <nonce>\\n" as the firmware answers START, or its boot marker"""
    return b"\n<<START>>" + (b" " + nonce if nonce else b"") + b"\n"


def start(linktype=127):
    """The start of a synced stream: our marker and the header"""
    return marker(NONCE) + global_hdr(linktype)


def hdr(sec, usec, incl, orig):
    return struct.pack("<IIII", sec, usec, incl, orig)


def rec_with(i, payload):
    return hdr(1700000000 + i, (i * 1237) % 1000000, len(payload), len(payload)) + payload


def rec(i, n=None):
    n = 40 + (i * 37) % 900 if n is None else n
    return rec_with(i, bytes((i + k) & 0xFF for k in range(n)))


def recs(a, b):
    return b"".join(rec(i) for i in range(a, b))


def parsed(r):
    ts_sec, ts_usec, _, orig_len = struct.unpack_from("<IIII", r)
    return (ts_sec, ts_usec, orig_len, r[16:])


def parse_all(stream):
    """The records of a plain run of records, as the framer passes them on."""
    out, pos = [], 0
    while pos < len(stream):
        n = struct.unpack_from("<I", stream, pos + 8)[0]
        out.append(parsed(stream[pos:pos + 16 + n]))
        pos += 16 + n
    return out


def run(stream, nonce, chunk, linktype=None):
    """Feeds a stream the way BoardLink does: returns (records, n_synclost, most bytes the framer held)."""
    scanner, framer = bd.MarkerScanner(), bd.PcapFramer(linktype)
    synced, items, lost, most = False, [], 0, 0
    for off in range(0, len(stream), chunk):
        data = stream[off:off + chunk]
        while True:
            if not synced:
                data = scanner.feed(data, nonce)
                if data is None:
                    break
                synced = True
            items += framer.feed(data)
            most = max(most, len(framer.buf))
            if not framer.sync_lost:
                break
            lost += 1
            synced = False
            data = framer.resync()
    return items, lost, most


def expect(name, stream, want, losses, nonce=NONCE, linktype=127, chunks=CHUNKS):
    """Every chunk size must pass on exactly want (a run of records) with this many losses of sync."""
    want = parse_all(want)
    for chunk in chunks:
        items, lost, _ = run(stream, nonce, chunk, linktype)
        check("%s chunk=%d (%d records, %d lost sync)" % (name, chunk, len(items), lost),
              items == want and lost == losses)


def expect_ends(name, stream, head, tail, nonce=NONCE, linktype=127):
    """A resync that may pass on a truncated record: what comes before and after it must be right, and
    sync must have been lost."""
    head, tail = parse_all(head), parse_all(tail)
    for chunk in CHUNKS:
        items, lost, _ = run(stream, nonce, chunk, linktype)
        check("%s chunk=%d (%d records, %d lost sync)" % (name, chunk, len(items), lost),
              items[:len(head)] == head and items[-len(tail):] == tail and lost >= 1)


# ----------------------------------------------------------------------------------------------
# Framing: the cases the Wireshark project had, without a nonce as its host asked for none
# ----------------------------------------------------------------------------------------------

old = [rec(i, 40 + (i * 37) % 900) for i in range(60)]
# payloads deliberately contain 0x0A / 0x0D / marker-like bytes
old[5] = struct.pack("<IIII", 5, 5, 64, 64) + b"<<START>>\n" + bytes(54)
P = [parsed(r) for r in old]

for chunk in CHUNKS:
    s = b"ESP-ROM:esp32c5-eco2\r\nboot text\r\n\n<<START>>\n" + GLOBAL + b"".join(old[:5] + old[6:])
    items, lost, _ = run(s, None, chunk)
    check("plain marker chunk=%d" % chunk, items == P[:5] + P[6:] and lost == 0)

    stale = b"".join(old[20:30]) + b"\n<<START>>\n" + GLOBAL + b"".join(old[30:40])
    s = stale + b"\n<<START>> deadbeef\n" + GLOBAL + b"".join(old[:10])
    items, lost, _ = run(s, b"deadbeef", chunk)
    check("nonce skips stale marker chunk=%d" % chunk, items == P[:10] and lost == 0)

    items, lost, _ = run(b"\n<<START>> 0badc0de\n" + GLOBAL + b"".join(old[:3]), b"deadbeef", chunk)
    check("wrong nonce ignored chunk=%d" % chunk, items == [] and lost == 0)

    s = (b"\n<<START>>\n" + GLOBAL + b"".join(old[:10]) + old[10][:30]
         + b"ESP-ROM:esp32c5\r\nrst:0x15\r\n" + b"\n<<START>>\n" + GLOBAL + b"".join(old[40:50]))
    items, lost, _ = run(s, None, chunk)
    check("reboot mid-stream resyncs chunk=%d" % chunk,
          items[:10] == P[:10] and items[-10:] == P[40:50] and lost >= 1)

    s = (b"\n<<START>>\n" + GLOBAL + b"".join(old[:10]) + b"\n<<START>>\n" + GLOBAL + b"".join(old[40:50]))
    items, lost, _ = run(s, None, chunk)
    check("marker at record boundary chunk=%d" % chunk, items == P[:10] + P[40:50] and lost == 1)

random.seed(1)
garbage = bytes(random.getrandbits(8) for _ in range(200000))
items, lost, _ = run(garbage, None, 4096)
check("random garbage yields nothing", items == [])

# A board still on another radio announces another link type. That is lost sync, never a record.
items, lost, _ = run(b"\n<<START>>\n" + global_hdr(283) + b"".join(old[:5]), None, 4096, linktype=127)
check("wrong link type is refused", items == [] and lost == 1)

# ----------------------------------------------------------------------------------------------
# Framing: the C helper's cases (tests/c/test_parser.c test_framing), with our nonce
# ----------------------------------------------------------------------------------------------

payload = b"<<START>>\n" + bytes(54)
s = b"ESP-ROM:esp32c5-eco2\r\nboot text\r\n" + start() + recs(0, 5) + rec_with(5, payload) + recs(6, 60)
e = recs(0, 5) + rec_with(5, payload) + recs(6, 60)
expect("C: plain marker", s, e, 0)
check("the framer holds at most a kept and a partial record",
      all(run(s, NONCE, c, 127)[2] <= 2 * (16 + bd.MAX_RECORD_LEN) + c for c in CHUNKS))

expect("C: CRLF marker", b"boot\r\n\r\n<<START>> deadbeef\r\n" + GLOBAL + recs(0, 10), recs(0, 10), 0)
s = (recs(20, 30) + marker() + GLOBAL + recs(30, 40) + marker(b"0badc0de") + GLOBAL + recs(40, 45)
     + start() + recs(0, 10))
expect("C: nonce skips stale markers", s, recs(0, 10), 0)
expect("C: wrong nonce ignored", marker(b"0badc0de") + GLOBAL + recs(0, 3), b"", 0)
s = (marker(NONCE + b"00") + GLOBAL + recs(0, 3) + b"\n<<START>> deadbeefx1\r\n" + GLOBAL + recs(0, 3)
     + start() + recs(3, 6))
expect("C: nonce that is a prefix of a longer one", s, recs(3, 6), 0)

# A board that rebooted while its port stayed open cut record 10 short; the new marker is inside what
# record 10 claims
s = start() + recs(0, 10) + rec(10)[:30] + b"ESP-ROM:esp32c5\r\nrst:0x15\r\n" + start() + recs(40, 50)
expect_ends("C: reboot mid-stream resyncs", s, recs(0, 10), recs(40, 50))
s = start() + recs(0, 10) + rec(10)[:30] + start() + recs(40, 50)
expect_ends("C: truncated record, then marker and header", s, recs(0, 10), recs(40, 50))
# the truncated record claims less than the boot text that follows: the marker comes after the damaged
# header, where the scan finds it anyway
s = (start() + recs(0, 10) + hdr(1700000010, 5, 100, 100) + b"0123456789abcd" + b"boot text line\r\n" * 20
     + start() + recs(40, 50))
expect_ends("C: truncated record, long boot text, then marker", s, recs(0, 10), recs(40, 50))
# a reset between records: the boot marker (no nonce) at a record boundary, and the answer to the START
# that follows
s = start() + recs(0, 10) + marker() + GLOBAL + recs(30, 35) + start() + recs(40, 50)
expect("C: boot marker at a record boundary", s, recs(0, 10) + recs(40, 50), 1)
expect("C: marker at record boundary", start() + recs(0, 10) + start() + recs(40, 50), recs(0, 10) + recs(40, 50), 1)
s = start() + recs(0, 10) + b"\r\n<<START>> deadbeef\r\n" + GLOBAL + recs(40, 50)
expect("C: CRLF marker at record boundary", s, recs(0, 10) + recs(40, 50), 1)
for what, usec, incl, orig in (("incl_len 0xFFFF", 5, 0xFFFF, 0xFFFF), ("incl_len > orig_len", 5, 100, 99),
                               ("ts_usec >= 1000000", 1000000, 60, 60), ("incl_len 0", 5, 0, 60)):
    s = start() + recs(0, 10) + hdr(1700000000, usec, incl, orig) + recs(10, 15) + start() + recs(40, 50)
    expect("C: damaged record (%s) resyncs" % what, s, recs(0, 10) + recs(40, 50), 1)
expect("C: wrong link type is refused", start(283) + recs(0, 5), b"", 1)
big = b"".join(rec(i, bd.MAX_RECORD_LEN if i % 2 else None) for i in range(12))
expect("C: 16384 byte records", start() + big, big, 0)
check("... and the framer still holds at most a kept and a partial record",
      all(run(start() + big, NONCE, c, 127)[2] <= 2 * (16 + bd.MAX_RECORD_LEN) + c for c in CHUNKS))

# ----------------------------------------------------------------------------------------------
# Frames that carry the restart signature: anyone on the air can send one (test_injection)
# ----------------------------------------------------------------------------------------------

injected = [
    # the signature from the finding: an SSID of "<<START>>\n" and the magic
    b"\x80\x00ssid:" + b"<<START>>\n" + MAGIC8 + b"tail",
    # the payload is exactly a stream start with a whole global header
    marker() + GLOBAL,
    # with a nonce, CRLF, and at the very end of the payload
    b"xx" + b"<<START>> 0badc0de\r\n" + MAGIC8,
    # with our own nonce (which no transmitter can know), a header and a record
    start() + hdr(1, 2, 20, 20) + b"01234567890123456789",
    # a payload that ends in the middle of the marker
    b"abc\n<<START>>",
    # one claiming a record far longer than anything that follows
    start() + hdr(1, 2, 16000, 16000),
]
body = recs(0, 10) + rec_with(100, injected[0]) + recs(10, 12)
body += b"".join(rec_with(101 + k, p) for k, p in enumerate(injected[1:])) + recs(12, 20)
# and as the last record, with nothing after it: it must not be held back
body += rec_with(106, b"<<START>>\n" + MAGIC8 + GLOBAL)
expect("payloads holding the restart signature all come through", start() + body, body, 0)
# a damaged header after such a record: the signature in it is a candidate now, but it has no nonce of
# ours, so the scan goes on to the real answer
s = start() + body + hdr(1700000000, 5, 0xFFFF, 0xFFFF) + recs(30, 33) + start() + recs(40, 45)
expect("damaged header after a signature payload", s, body + recs(40, 45), 1)

# The same in 802.15.4: the check is in the framing, before the radios
tap = bytes([0, 0, 48, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 4, 0, 0, 0, 0x5C, 0xC2, 3, 0, 3, 0, 15, 0, 0, 0,
             10, 0, 1, 0, 200, 0, 0, 0, 5, 0, 8, 0, 1, 2, 3, 4, 5, 6, 7, 8])
frames = b"".join(rec_with(k, tap + b"\x41\x88\x01\x34\x12\xff\xff\x01\x10"
                           + (b"\n<<START>>\n" + MAGIC8 if k % 2 else b"plain payload")) for k in range(6))
items, lost, _ = run(start(283) + frames, NONCE, 7, 283)
check("802.15.4 payloads holding the signature come through (%d)" % len(items), len(items) == 6 and lost == 0)

# The signature itself
check("signature_at: a whole signature", bd.signature_at(b"x<<START>>\n" + MAGIC8, 1) == 1 and
      bd.signature_at(b"<<START>> 0badc0de\r\n" + MAGIC8, 0) == 1)
check("signature_at: every prefix of one could still be one",
      all(bd.signature_at((b"<<START>> ab12\r\n" + MAGIC8)[:n], 0) == -1 for n in range(1, 24)))
check("signature_at: not one", bd.signature_at(b"<<START>>\n" + b"\xd4\xc3\xb2\xa1\x02\x00\x04\x01", 0) == 0 and
      bd.signature_at(b"<<START>>x\n" + MAGIC8, 0) == 0 and bd.signature_at(b"<<START>> \n" + MAGIC8, 0) == 0 and
      bd.signature_at(b"<<START>> " + b"a" * 17 + b"\n" + MAGIC8, 0) == 0 and
      bd.signature_at(b"<<START>>\r\r\n" + MAGIC8, 0) == 0 and bd.signature_at(b"<START>>\n" + MAGIC8, 0) == 0)
check("find_signature: the first in range", bd.find_signature(b"<<<START>>\n" + MAGIC8, 0, 5) == 1 and
      bd.find_signature(b"<<<START>>\n" + MAGIC8, 2, 5) is None)


# ----------------------------------------------------------------------------------------------
# Channel specs
# ----------------------------------------------------------------------------------------------

check("every wifi channel is one range", bd.format_channel_spec(bd.all_channels("wifi")) == "1-177")
check("three channels", bd.format_channel_spec([11, 1, 6]) == "1,6,11")
check("5 GHz run", bd.format_channel_spec([36, 40, 44, 48]) == "36-48")
check("802.15.4 all", bd.format_channel_spec(range(11, 27), "802154") == "11-26")
check("ble", bd.format_channel_spec([37], "ble") == "37")
random.seed(2)
wifi = bd.all_channels("wifi")
for _ in range(500):
    pick = random.sample(wifi, random.randint(1, len(wifi)))
    spec = bd.format_channel_spec(pick)
    if bd.parse_channel_spec(spec) != sorted(pick) or len("CHANNELS %s\n" % spec) > 256:
        check("round trip %r" % pick, False)
check("random channel lists survive the round trip", True)


# ----------------------------------------------------------------------------------------------
# Ports: one spelling each, the lock, and the ports without modem lines
# ----------------------------------------------------------------------------------------------

check("port key: COM names in any spelling", bd.port_key("\\\\.\\com32", "win32") == "COM32" and
      bd.port_key("com7", "win32") == "COM7" and bd.port_key("COM014", "win32") == "COM14")
check("port key: other Windows names compare without case", bd.port_key("\\\\.\\cnca0", "win32") == "CNCA0")
check("an access-denied open on Windows means the port is in use",
      bd.port_busy_error(serial.SerialException(
          "could not open port 'COM32': PermissionError(13, 'Access is denied.', None, 5)"), "win32") and
      not bd.port_busy_error(serial.SerialException(
          "could not open port 'COM99': FileNotFoundError(2, 'The system cannot find the file specified.', None, 2)"),
          "win32"))
check("a held flock on POSIX means the port is in use",
      bd.port_busy_error(serial.SerialException(11, "Could not exclusively lock port /dev/ttyACM0"), "linux") and
      not bd.port_busy_error(serial.SerialException(2, "could not open port /dev/ttyACM9"), "linux"))
check("so does an open refused with EBUSY: another helper has the tty in exclusive mode",
      bd.port_busy_error(serial.SerialException(
          16, "could not open port /dev/ttyACM0: [Errno 16] Device or resource busy: '/dev/ttyACM0'"), "linux"))

tmp = tempfile.mkdtemp()
try:
    os.symlink(os.path.join(tmp, "ttyACM3"), os.path.join(tmp, "by-id-link"))
    check("port key: a link is the port it points at",
          bd.port_key(os.path.join(tmp, "by-id-link"), "linux") == bd.port_key(os.path.join(tmp, "ttyACM3"), "linux"))
except (OSError, NotImplementedError):
    print("SKIP port key through a symbolic link (no permission to make one here)")

REAL_OPEN = bd.open_serial
if os.name == "posix":
    master, slave = os.openpty()
    pts = os.ttyname(slave)
    ser = bd.open_serial(pts)
    check("a pseudo-terminal opens, though it has no DTR or RTS (ENOTTY)", ser.is_open)
    e = raises(bd.PortBusy, bd.open_serial, pts)
    check("a second open of the port is refused: %s" % e,
          e is not None and "already in use by another capture" in str(e))
    link = os.path.join(tmp, "fake")
    os.symlink(pts, link)
    check("... and through a link to it, the lock being on the device node",
          raises(bd.PortBusy, bd.open_serial, link) is not None)
    bd.close_serial(ser)
    ser = bd.open_serial(link)
    check("the port is free once closed", ser.is_open)
    bd.close_serial(ser)

    # Exclusive mode (TIOCEXCL), which is on the tty, not on a node. Not on a pseudo-terminal, whose tty, and
    # the mode with it, outlives the helper's close for as long as the other end is open. The test's own
    # slave fd stands for another program that has the tty open all along.
    if sys.platform.startswith("linux"):
        import fcntl
        import shutil
        import subprocess
        import termios
        TIOCGEXCL = getattr(termios, "TIOCGEXCL", 0x80045440)

        def exclusive(fd):
            return struct.unpack("i", fcntl.ioctl(fd, TIOCGEXCL, b"\0" * 4))[0]

        ser = bd.open_serial(pts)
        check("a pseudo-terminal is known as one, and not put in exclusive mode",
              bd.pseudo_terminal(ser.fd) and not bd.pseudo_terminal(ser.fd, "darwin") and exclusive(slave) == 0)
        fcntl.ioctl(ser.fd, termios.TIOCEXCL)  # as a tty that is not one gets it
        before = exclusive(slave)
        bd.close_serial(ser)
        check("close_serial ends the mode, which the close alone leaves while another program has the tty open",
              before == 1 and exclusive(slave) == 0)

        # Another helper has the tty in exclusive mode: the open fails with EBUSY, for any process without
        # CAP_SYS_ADMIN (this test, run as root, has it, so a child without it tries)
        if os.geteuid() == 0 and shutil.which("capsh"):
            fcntl.ioctl(slave, termios.TIOCEXCL)
            code = ("import sys\nsys.path.insert(0, %r)\nfrom esp32c5_kismet import board as bd\n"
                    "try:\n    bd.open_serial(%r)\nexcept bd.PortBusy as e:\n    print('BUSY', e)\n"
                    "except Exception as e:\n    print('OTHER', e)\nelse:\n    print('OPENED')\n") % (
                        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), pts)
            got = subprocess.run(["capsh", "--drop=cap_sys_admin", "--", "-c", '"$0" -c "$1"', sys.executable,
                                  code], capture_output=True, text=True).stdout.strip()
            fcntl.ioctl(slave, termios.TIOCNXCL)
            check("a port another helper has in exclusive mode is refused as in use (EBUSY): %s" % got,
                  got.startswith("BUSY") and "already in use by another capture" in got)
        else:
            print("SKIP an open refused with EBUSY (needs root and capsh, to try it without CAP_SYS_ADMIN)")

        # Another process has the port: /proc/locks says so without the port being opened here
        code = ("import sys\nsys.path.insert(0, %r)\nfrom esp32c5_kismet import board as bd\n"
                "ser = bd.open_serial(sys.argv[1])\nprint('held', flush=True)\nsys.stdin.read()\n") % (
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        holder = subprocess.Popen([sys.executable, "-c", code, pts], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True)
        check("another helper holds the pseudo-terminal: %s" % holder.stdout.readline().strip(), holder.poll() is None)
        check("... which /proc/locks shows: the port is locked, by name and through a link to it",
              bd.port_locked(pts) and bd.port_locked(link))
        holder.stdin.close()
        holder.wait(10)
        check("... and not once that process has let it go", not bd.port_locked(pts))
        ser = bd.open_serial(pts)
        check("this process's own lock does not count: it holds one on every port it has open",
              not bd.port_locked(pts))
        bd.close_serial(ser)
    os.close(master)
    os.close(slave)
else:
    print("SKIP pseudo-terminal and lock tests (POSIX only)")

# port_locked() reads /proc/locks as the C helper's port_locked() does: a FLOCK line with the device and inode
# of the node, of another process
held = os.path.join(tmp, "ttyHELD")
open(held, "w").close()
check("nothing is known to be locked except on Linux",
      not bd.port_locked(held, "win32", os.devnull) and not bd.port_locked(held, "darwin", os.devnull))
check("... nor without /proc/locks, nor on a port that is not there",
      not bd.port_locked(held, "linux", os.path.join(tmp, "no-locks")) and
      not bd.port_locked(os.path.join(tmp, "ttyNONE"), "linux", os.devnull))
if sys.platform.startswith("linux"):
    st = os.stat(held)
    where = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    other = 1 if os.getpid() != 1 else 2

    def locks_says(*lines):
        path = os.path.join(tmp, "locks")
        with open(path, "w") as f:
            f.write("".join(line + "\n" for line in lines))
        return bd.port_locked(held, "linux", path)

    check("a FLOCK of another process on the node's device and inode is a lock",
          locks_says("1: POSIX  ADVISORY  WRITE %d 00:01:1 0 EOF" % other,
                     "2: FLOCK  ADVISORY  WRITE %d %s 0 EOF" % (other, where)))
    check("... a POSIX lock is not (neither helper takes one)",
          not locks_says("1: POSIX  ADVISORY  WRITE %d %s 0 EOF" % (other, where)))
    check("... nor a lock waited for ('->'), nor one on another inode",
          not locks_says("1: -> FLOCK  ADVISORY  WRITE %d %s 0 EOF" % (other, where),
                         "2: FLOCK  ADVISORY  WRITE %d %s1 0 EOF" % (other, where)))
    check("... nor this process's own", not locks_says("1: FLOCK  ADVISORY  WRITE %d %s 0 EOF" % (os.getpid(), where)))


# ----------------------------------------------------------------------------------------------
# The link, against a fake board
# ----------------------------------------------------------------------------------------------

MODE_OF = {"WIFI": "wifi", "802154": "802154", "BLE": "ble"}


class FakeBoard:
    """Answers the way the firmware does. MODE for another radio reboots it in place: for REBOOT_S it hears
    nothing, then it prints its boot marker and a header in the new link type. START is answered with
    "\\n<<START>> <nonce>\\n" and a header, then records. With busy=True it streams records all the time,
    like a board on a crowded channel, whether or not anyone has asked."""

    REBOOT_S = 0.53

    def __init__(self, mode="wifi", busy=False, garble_after=None, linktype=None, vanish_on_mode=False,
                 half_header=False):
        self.mode = mode
        self.out = bytearray()
        self.lock = threading.Lock()
        self.commands, self.times, self.lost = [], [], []
        self.n = 0
        self.since_start = 0
        self.busy = busy
        self.streaming = False
        self.garble_after = garble_after
        self.linktype = linktype  # answer with this one whatever the radio
        self.vanish_on_mode = vanish_on_mode
        # answer the first START with the marker and 10 bytes of the header, then nothing at all: reset in the
        # middle of its answer, the port left open and silent
        self.half_header, self.answered = half_header, False
        self.gone = False
        self.reboot_until = None
        self.in_waiting = 0

    def header(self):
        return global_hdr(self.linktype or bd.MODE_LINKTYPE[self.mode])

    def write(self, data):
        with self.lock:
            if self.gone:
                raise serial.SerialException("write failed: the port is gone")
            for line in data.decode().splitlines():
                now = time.monotonic()
                self.commands.append(line)
                self.times.append(now)
                if self.reboot_until is not None:
                    self.lost.append(line)
                    continue
                if line.startswith("MODE "):
                    if self.vanish_on_mode:
                        self.gone = True
                        break
                    mode = MODE_OF[line[5:]]
                    if mode != self.mode:
                        self.mode, self.streaming = mode, False
                        self.reboot_until = now + self.REBOOT_S
                m = re.fullmatch(r"START \d+ (\w+)", line)
                if m and self.half_header:
                    if not self.answered:
                        self.out += b"\n<<START>> %s\n" % m.group(1).encode() + self.header()[:10]
                    self.answered = True
                elif m:
                    self.out += b"\n<<START>> %s\n" % m.group(1).encode() + self.header()
                    self.streaming, self.since_start = True, 0
        return len(data)

    def read(self, size):
        time.sleep(0.002)
        with self.lock:
            if self.gone:
                raise serial.SerialException("device reports readiness to read but returned no data")
            if self.reboot_until is not None:
                if time.monotonic() < self.reboot_until:
                    return b""
                self.reboot_until = None
                self.out += b"ESP-ROM:esp32c5\r\n\n<<START>>\n" + self.header()
                self.streaming = True
            if self.busy or self.streaming:
                self.n += 1
                self.since_start += 1
                r = rec(self.n, 60)
                if self.garble_after is not None and self.since_start == self.garble_after:
                    r = struct.pack("<IIII", 0, 0, 999999, 1) + r[16:]  # incl_len > orig_len
                self.out += r
            data, self.out[:] = bytes(self.out), b""
        return data

    def close(self):
        pass

    def when(self, prefix, nth=0):
        hits = [t for c, t in zip(self.commands, self.times) if c.startswith(prefix)]
        return hits[nth] if len(hits) > nth else None


def link_with(fake, mode="wifi", channels=(1, 6, 11), port="FAKE", mac=None, name=None):
    got, statuses = [], []
    if isinstance(fake, dict):
        bd.open_serial = lambda p, baud=921600: fake[p]
    else:
        bd.open_serial = lambda p, baud=921600: fake
    link = bd.BoardLink(port, mode, list(channels), 250, on_packet=lambda *r: got.append(r),
                        on_status=lambda text, kind: statuses.append((time.monotonic(), text, kind)), mac=mac,
                        name=name)
    link.start()
    return link, got, statuses


def wait_for(cond, timeout=8.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def said(statuses, text):
    return any(text in t for _, t, _ in statuses)


def stop(link):
    link.stop()
    link.join(3)


# Nothing about the ports of the machine running this: no board is known by its MAC unless a test says so
bd.port_identity = lambda ser, port, platform=None: None
bd.find_port_by_mac = lambda mac, boards=None: None

fake = FakeBoard()
link, got, statuses = link_with(fake, name="kitchen")
check("link syncs and delivers frames", wait_for(lambda: len(got) > 20))
check("MODE comes first", fake.commands[0] == "MODE WIFI")
check("channels sent as a spec", "CHANNELS 1,6,11" in fake.commands)
check("START waits for MODE to settle: %.2f s" % (fake.when("START") - fake.when("MODE")),
      fake.when("START") - fake.when("MODE") >= bd.MODE_SETTLE_S - 0.05)
check("the first open is reported, and succeeded", link.first_attempt.is_set() and link.open_error is None)
check("status kinds: opened, then capturing", [k for _, _, k in statuses][:2] == ["opened", "capturing"] and
      link.capturing)
# Every status names the source, not the port, and capturing its radio, in the C helper's words
check("statuses start with the source's name, as the C helper's do: %s" % [t for _, t, _ in statuses][:2],
      [t for _, t, _ in statuses][:2] == ["kitchen: FAKE opened", "kitchen capturing (wifi)"])
link.set_channels(bd.all_channels("wifi"))
check("retune sends ranges", wait_for(lambda: "CHANNELS 1-177" in fake.commands))
check("channel 15 refused", raises(ValueError, link.set_channels, [15]) is not None)
stop(link)

# The board is on another radio: MODE reboots it in place, and the START after it must not be lost
fake = FakeBoard(mode="802154")
link, got, statuses = link_with(fake)
check("in-place reboot: capturing on the new radio", wait_for(lambda: link.synced and len(got) > 5))
check("in-place reboot: nothing sent to the board was lost in the reboot (%s)" % fake.lost, fake.lost == [])
check("in-place reboot: the boot marker was not taken for the answer", fake.commands.count("MODE WIFI") == 1 and
      sum(c.startswith("START") for c in fake.commands) == 1)
stop(link)

# The other two radios by the C helper's names for them, and a link without a name goes by its port
for mode, channel, radio in (("802154", 15, "zigbee"), ("ble", 37, "btle")):
    link, got, statuses = link_with(FakeBoard(mode=mode), mode=mode, channels=[channel])
    capturing = wait_for(lambda: link.capturing, 4)
    stop(link)
    check("%s: '%s' (%s)" % (mode, "FAKE capturing (%s)" % radio, [t for _, t, _ in statuses]),
          capturing and ("FAKE capturing (%s)" % radio, "capturing") in [(t, k) for _, t, k in statuses])

# The port goes away in the reboot: noticed while MODE settles, not after
fake = FakeBoard(vanish_on_mode=True)
link, got, statuses = link_with(fake)
check("a port that goes away after MODE is noticed at once",
      wait_for(lambda: said(statuses, "returned no data"), 2) and
      next(t for t, text, _ in statuses if "returned no data" in text) - fake.when("MODE") < 0.5)
check("... said as the C helper says a port it drops: '<name>: <why>, reconnecting' (%s)" %
      [t for _, t, _ in statuses],
      said(statuses, "FAKE: device reports readiness to read but returned no data, reconnecting"))
check("... and no START was written after it", not any(c.startswith("START") for c in fake.commands))
stop(link)

# A damaged record on a channel that never goes quiet: the link has to ask again by itself, and as the
# board is on our radio already, without MODE
fake = FakeBoard(busy=True, garble_after=30)
link, got, statuses = link_with(fake)
check("resyncs on a busy channel after a damaged record",
      wait_for(lambda: sum(c.startswith("START") for c in fake.commands) >= 2 and link.synced and len(got) > 60))
check("the resync skips MODE: the board is on our radio",
      fake.commands.count("MODE WIFI") == 1 and link.sync_losses >= 1 and said(statuses, "lost sync (damaged"))
check("lost sync is its own status kind", any(k == "lost" for _, _, k in statuses))
stop(link)

# A board that keeps answering in another link type is asked for the radio again. That is a board whose
# firmware lacks the radio: it is never capturing, and says so once, not "capturing" and "lost sync" in turn;
# by the source's name, as the C helper says it ("oldfw: lost sync ...")
fake = FakeBoard(linktype=283)
link, got, statuses = link_with(fake, name="oldfw")
check("wrong link type: MODE again", wait_for(lambda: fake.commands.count("MODE WIFI") >= 2, 6) and got == [])
check("... and again, each answer in the wrong link type", wait_for(lambda: link.sync_losses >= 3, 8))
stop(link)
check("... never capturing, and lost sync said once, by the source's name: %s" %
      [(text, kind) for _, text, kind in statuses],
      [(text, kind) for _, text, kind in statuses] == [
          ("oldfw: FAKE opened", "opened"), ("oldfw: lost sync (the board sends link type 283, not 127)", "lost")] and
      not link.capturing and got == [])

# A board that was capturing and goes away is capturing no longer -- which is what the Kismet side's
# watchdog goes by -- and once it is back, capturing is said again
fake = FakeBoard()
link, got, statuses = link_with(fake)
check("capturing, then the port goes away", wait_for(lambda: link.capturing and len(got) > 5))
with fake.lock:
    fake.gone = True
check("... not capturing once the error is said",
      wait_for(lambda: said(statuses, "returned no data") and not link.capturing, 3))
with fake.lock:
    fake.gone = False
back = wait_for(lambda: link.capturing and sum(k == "capturing" for _, _, k in statuses) == 2, 8)
check("... and capturing again once it is back, which is said again (%s)" % [(t, k) for _, t, k in statuses], back)
stop(link)

# A board that answers with our marker and part of a header and then nothing, its port left open (a reset in
# the middle of its answer): not capturing, so asked again, and reopened once silent for STALL_TIMEOUT_S. The
# C helper's rule, which waits for capture, not for the marker.
stall, bd.STALL_TIMEOUT_S = bd.STALL_TIMEOUT_S, 3.0
fake, opens, statuses = FakeBoard(half_header=True), [], []
bd.open_serial = lambda p, baud=921600: opens.append(time.monotonic()) or fake
link = bd.BoardLink("FAKE", "wifi", [6], 250, on_packet=lambda *r: None,
                    on_status=lambda text, kind: statuses.append((time.monotonic(), text, kind)))
link.start()
synced = wait_for(lambda: link.synced, 3)
asked = wait_for(lambda: sum(c.startswith("START") for c in fake.commands) >= 2,
                 bd.START_RETRY_S + bd.MODE_SETTLE_S + 1.5)
check("half a header, then silence: synced, not capturing, and the handshake asked again (%s)" %
      [c for c in fake.commands if c.startswith(("MODE", "START"))], synced and not link.capturing and asked)
reopened = wait_for(lambda: len(opens) >= 2, 5)
check("... and the silent port reopened, said in the C helper's words (%s)" % [t for _, t, _ in statuses],
      reopened and said(statuses, "FAKE: no answer, reconnecting"))
stop(link)
bd.STALL_TIMEOUT_S = stall

# The marker alone is not capturing yet: the header after it has to be there, with our link type. Statuses
# and records go in one list, in the order they are passed on.
events = []
link = bd.BoardLink("FAKE", "wifi", [6], 250, on_packet=lambda *r: events.append(("record", r[0])),
                    on_status=lambda text, kind: events.append((text, kind)))
scanner, framer = bd.MarkerScanner(), bd.PcapFramer(127)
link._consume(start()[:-10], scanner, framer, NONCE)
check("our marker and part of the header: synced, but not capturing yet (%s)" % events,
      link.synced and not link.capturing and events == [])
link._consume(start()[-10:] + rec(1), scanner, framer, NONCE)
check("... the rest of the header: capturing, said before the first record goes on (%s)" % events,
      link.capturing and events == [("FAKE capturing (wifi)", "capturing"), ("record", 1700000001)])
link._consume(marker(NONCE) + global_hdr(283), scanner, framer, NONCE)
statuses = [e for e in events if e[0] != "record"]
check("... a new stream in another link type: lost sync, and not capturing (%s)" % statuses,
      not link.capturing and not link.synced and statuses[-1][1] == "lost" and
      sum(kind == "capturing" for _, kind in statuses) == 1)

# The port is held by someone else
def busy_port(port, baud=921600):
    raise bd.PortBusy(bd.IN_USE % port)


bd.open_serial = busy_port
statuses = []
link = bd.BoardLink("COM32", "wifi", [6], 250, on_packet=lambda *r: None,
                    on_status=lambda text, kind: statuses.append((0, text, kind)), name="desk")
link.start()
check("a busy port: the first attempt says so",
      link.first_attempt.wait(2) and isinstance(link.open_error, bd.PortBusy) and
      "already in use by another capture" in str(link.open_error))
time.sleep(1.5)
stop(link)
# The first attempt's status claims no wait: whoever started the link decides on open_error, and the remote
# helper ends the connection on it (it said "waiting for it" there, then gave up). The attempts after it are
# the link waiting, said as the C helper says it when it reopens a port, and said once.
check("... without a word of waiting, then the link waits for it, as the C helper says it (%s)" %
      [t for _, t, _ in statuses],
      [t for _, t, _ in statuses] == ["desk: " + bd.IN_USE % "COM32",
                                      "desk: " + bd.IN_USE % "COM32" + "; waiting for it"])


# A port that cannot be opened at all: said once with pyserial's reason, which names the port, and not as a
# port dropped ("reconnecting"), as it never was open
def missing_port(port, baud=921600):
    raise serial.SerialException("could not open port '%s': FileNotFoundError(2, 'The system cannot find the "
                                 "file specified.', None, 2)" % port)


bd.open_serial = missing_port
statuses = []
link = bd.BoardLink("COM33", "wifi", [6], 250, on_packet=lambda *r: None,
                    on_status=lambda text, kind: statuses.append((0, text, kind)), name="desk")
link.start()
time.sleep(1.5)
stop(link)
check("a port that will not open: its error, once, after the source's name (%s)" % [t for _, t, _ in statuses],
      [(t, k) for _, t, k in statuses] == [("desk: could not open port 'COM33': FileNotFoundError(2, 'The system "
                                            "cannot find the file specified.', None, 2)", "error")])

# ----------------------------------------------------------------------------------------------
# Knowing the board again: by its MAC, whichever port it is on
# ----------------------------------------------------------------------------------------------

A, B, C = "AA:AA:AA:AA:AA:01", "BB:BB:BB:BB:BB:02", "CC:CC:CC:CC:CC:03"
owners = {}
bd.port_identity = lambda ser, port, platform=None: owners.get(port)
bd.find_port_by_mac = lambda mac, boards=None: next((p for p, m in owners.items() if m == mac), None)

# The first open learns the MAC
owners.update({"P3": C})
link, got, statuses = link_with({"P3": FakeBoard()}, port="P3")
check("the first open learns the board's MAC", wait_for(lambda: link.synced) and link.mac == C)
stop(link)

# The port it was given holds another board now (two boards rebooted and swapped names)
owners.clear()
owners.update({"P1": B, "P2": A})
fakes = {"P1": FakeBoard(), "P2": FakeBoard()}
link, got, statuses = link_with(fakes, port="P1", mac=A, name="src")
check("a port holding another board is not used, and ours is found by its MAC",
      wait_for(lambda: link.synced) and link.current_port == "P2" and fakes["P1"].commands == [] and
      fakes["P2"].commands[0] == "MODE WIFI")
check("... which is said, as the C helper says it",
      said(statuses, "src: P1 now holds another board, looking for %s" % A) and
      said(statuses, "src: board %s is on P2 now" % A) and said(statuses, "src: P2 opened"))
check("... and the port it was given is kept, to be tried first next time", link.port == "P1")
stop(link)

# Reopening after the port went away checks the board again
owners.clear()
owners.update({"P1": A})
fakes = {"P1": FakeBoard(), "P2": FakeBoard()}
link, got, statuses = link_with(fakes, port="P1", mac=A)
check("reopen: capturing on P1 first", wait_for(lambda: link.synced) and link.current_port == "P1")
owners.update({"P1": B, "P2": A})
fakes["P1"].gone = True
fakes["P1"] = FakeBoard()
check("reopen: P1 came back holding another board, and ours is followed to P2",
      wait_for(lambda: link.current_port == "P2" and link.synced, 8) and fakes["P1"].commands == [])
check("reopen: the configured port is still P1", link.port == "P1")
stop(link)

# The port holds another board and ours is nowhere: tried every second, said once, as the C helper says it
owners.clear()
owners.update({"P1": B})
fakes = {"P1": FakeBoard()}
link, got, statuses = link_with(fakes, port="P1", mac=A, name="src")
time.sleep(3.5)
stop(link)
check("another board on the port, ours nowhere: one status in 3.5 s, not one a second (%s)" %
      [(text, kind) for _, text, kind in statuses],
      [(text, kind) for _, text, kind in statuses] == [
          ("src: P1 now holds another board, looking for %s" % A, "info")])
check("... the first attempt failed with it, and nothing was sent to that board",
      isinstance(link.open_error, bd.OtherBoard) and str(link.open_error) == "P1 holds another board than %s" % A and
      fakes["P1"].commands == [])
# ... and when ours is on a port that is busy, that is said as well (as the C helper says it; the two take
# turns, and the Kismet side holds each to once every 10 s)
owners.update({"P2": A})
bd.open_serial = lambda p, baud=921600: busy_port(p) if p == "P2" else fakes[p]
statuses = []
link = bd.BoardLink("P1", "wifi", [6], 250, on_packet=lambda *r: None,
                    on_status=lambda text, kind: statuses.append((0, text, kind)), mac=A, name="src")
link.start()
time.sleep(1.5)
stop(link)
texts = [t for _, t, _ in statuses]
# the first attempt without a word of waiting, as above, and every one after it waiting
check("... and when ours is on a busy port, that is said after it (%s)" % texts,
      texts[:4] == ["src: P1 now holds another board, looking for %s" % A, "src: " + bd.IN_USE % "P2",
                    "src: P1 now holds another board, looking for %s" % A,
                    "src: " + bd.IN_USE % "P2" + "; waiting for it"] and
      set(texts[2:]) == set(texts[2:4]) and isinstance(link.open_error, bd.PortBusy) and fakes["P1"].commands == [])


# ----------------------------------------------------------------------------------------------
# Is a port there? (Windows: the device list, and the DOS device names of virtual COM ports)
# ----------------------------------------------------------------------------------------------

class ListedPort:
    def __init__(self, device):
        self.device = device


real_comports, real_dos = bd.list_ports.comports, bd._dos_device_exists
bd.list_ports.comports = lambda: [ListedPort("COM14")]
bd._dos_device_exists = lambda name: name == "CNCA0"
try:
    check("a listed COM port is there, however it is written",
          bd.port_exists("com14", "win32") and bd.port_exists("\\\\.\\COM14", "win32"))
    check("a virtual COM port pyserial does not list is there by its DOS device name",
          bd.port_exists("CNCA0", "win32") and bd.port_exists("\\\\.\\cnca0", "win32"))
    check("a port that is neither is not", not bd.port_exists("COM99", "win32"))
finally:
    bd.list_ports.comports, bd._dos_device_exists = real_comports, real_dos
if sys.platform == "win32":
    check("QueryDosDevice answers: NUL is a DOS device, COM987 is none",
          bd._dos_device_exists("NUL") and not bd._dos_device_exists("COM987"))
else:
    check("no DOS devices outside Windows", bd._dos_device_exists("NUL") is False)

print("ALL OK")
