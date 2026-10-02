"""The link to one ESP32-C5 sniffer board: serial port, handshake, PCAP framing, reconnects.

Nothing in here knows about Kismet. It opens the board, tells it which radio and channels to use,
and hands every captured frame to a callback. The Python remote helper (remote.py) sits on top of it.

The board speaks plain lines over its native USB port (USB-Serial-JTAG, USB ID 303a:1001):

    MODE WIFI|802154|BLE        which radio to listen with; another one than now reboots the board
    CHANNELS <spec>             "6", "1,6,11", "1-11", "1-13,36,149-165"
    DWELL <ms>                  time on each channel, 20-60000
    START <unix us> <nonce>     answer with "\\n<<START>> <nonce>\\n", a PCAP global header, then records

It answers nothing but START; the rest shows only in its UART0 log. The whole protocol, the stream's
layout for each radio and the reset lines are on the wiki page Firmware-Protocol:
https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Firmware-Protocol

The stream is read by the same rule as kismet/capture_esp32c5/capture_esp32c5.c reads it (the comment
above pcap_magic_ver there), step for step, so that both helpers make the same of the same bytes. A board
is reported capturing only once its PCAP header has the link type of the radio asked for, as there: a
board whose firmware lacks that radio answers START all the same. The port is taken the same way as well
(open_serial), so the two helpers keep out of each other's way, and on Linux whether another process holds
it can be told without opening it (port_locked), as the C helper's port_locked() tells it.
"""

import errno
import os
import re
import secrets
import stat
import struct
import sys
import threading
import time

import serial
from serial.tools import list_ports

try:  # POSIX
    import fcntl
    import termios
except ImportError:  # Windows
    fcntl = termios = None

ESPRESSIF_USB_JTAG = (0x303A, 0x1001)

START_MARKER = b"<<START>>"
MARKER_RE = re.compile(rb"<<START>>(?: ([0-9A-Za-z]{1,16}))?\r?\n")
MARKER_TAIL = len(b"<<START>> " + b"x" * 16 + b"\r\n") - 1  # kept between reads, a marker may be split
NONCE_BYTES = frozenset(b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

PCAP_MAGIC = 0xA1B2C3D4
PCAP_MAGIC_VER = struct.pack("<IHH", PCAP_MAGIC, 2, 4)  # d4 c3 b2 a1 02 00 04 00, how a stream starts
PCAP_GLOBAL_HDR_LEN = 24
PCAP_REC_HDR_LEN = 16
MAX_RECORD_LEN = 16384  # sanity bound used to detect a damaged stream

LINKTYPE_IEEE802_11_RADIOTAP = 127
LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR = 256
LINKTYPE_IEEE802_15_4_TAP = 283

MODE_WIFI, MODE_154, MODE_BLE = "wifi", "802154", "ble"
MODE_COMMAND = {MODE_WIFI: b"WIFI", MODE_154: b"802154", MODE_BLE: b"BLE"}
# The radios' names in the statuses, as the C helper's mode_name() gives them
RADIO_NAME = {MODE_WIFI: "wifi", MODE_154: "zigbee", MODE_BLE: "btle"}
MODE_LINKTYPE = {
    MODE_WIFI: LINKTYPE_IEEE802_11_RADIOTAP,
    MODE_154: LINKTYPE_IEEE802_15_4_TAP,
    MODE_BLE: LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR,
}

MIN_DWELL_MS, MAX_DWELL_MS = 20, 60000

# How often the handshake is repeated while the board has not answered, and how long a port that has
# not answered at all is given before it is reopened. A board answers with its marker and PCAP header
# immediately, so the second only has to outlast a reboot, not a quiet channel. Neither applies once
# the board is capturing, where silence means nothing is on the air.
START_RETRY_S = 2.0
STALL_TIMEOUT_S = 6.0

# From MODE to START. A board asked for another radio reboots, and for about half a second hears
# nothing: a START sent then is lost. Its USB port stays open through the reboot, so nothing else would
# tell the helper to wait.
MODE_SETTLE_S = 0.8

IN_USE = ("%s is already in use by another capture (an esp32c5 source or another program holds it); "
          "a board captures with one radio at a time")


# ----------------------------------------------------------------------------------------------
# Channel lists
# ----------------------------------------------------------------------------------------------

def channel_is_valid(ch, mode=MODE_WIFI):
    """The channels an ESP32 radio can tune to (same rule as the firmware).

    The radios number their channels differently and the ranges overlap, so 11 to 14 mean one thing
    on Wi-Fi and another on 802.15.4. Which radio is meant has to be said, not guessed.

    Bluetooth LE accepts only 37. Its three advertising channels are 37, 38 and 39, but the
    controller scans all of them and will not be restricted to one, so 37 stands for the set.
    """
    if mode == MODE_BLE:
        return ch == 37
    if mode == MODE_154:
        return 11 <= ch <= 26
    return (1 <= ch <= 14
            or (36 <= ch <= 64 and (ch - 36) % 4 == 0)
            or (100 <= ch <= 144 and (ch - 100) % 4 == 0)
            or (149 <= ch <= 177 and (ch - 149) % 4 == 0))


def all_channels(mode):
    return [c for c in range(1, 178) if channel_is_valid(c, mode)]


def parse_channel_spec(spec, mode=MODE_WIFI):
    """Turn "6", "1,6,11", "1-11" or "1-13,36,149-165" into an ordered list of channels.

    A single number has to be a real channel; a range keeps the real channels inside it, so "36-64"
    gives 36, 40 ... 64. Duplicates are dropped so no channel gets two turns in a lap.
    """
    what = {MODE_154: "802.15.4", MODE_BLE: "Bluetooth LE"}.get(mode, "Wi-Fi")
    allowed = {MODE_154: "11-26",
               MODE_BLE: "37 only: the controller scans all three advertising channels"}.get(
                   mode, "1-14, or 36-177 in steps of 4")
    channels = []
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            raise ValueError("empty entry in channel list %r" % spec)
        if "-" in part:
            low, _, high = part.partition("-")
            try:
                low, high = int(low), int(high)
            except ValueError:
                raise ValueError("%r is not a channel range like 1-11" % part)
            if high < low:
                raise ValueError("the range %r runs backwards" % part)
            picked = [c for c in range(low, high + 1) if channel_is_valid(c, mode)]
            if not picked:
                raise ValueError("no %s channels in the range %r" % (what, part))
        else:
            try:
                channel = int(part)
            except ValueError:
                raise ValueError("%r is not a channel number" % part)
            if not channel_is_valid(channel, mode):
                raise ValueError("%d is not a %s channel (%s)" % (channel, what, allowed))
            picked = [channel]
        for c in picked:
            if c not in channels:
                channels.append(c)
    if not channels:
        raise ValueError("empty channel list")
    return channels


def format_channel_spec(channels, mode=MODE_WIFI):
    """The shortest spec the firmware reads back as these channels: [1, 6, 11, 36, 40, 44] -> "1,6,11,36-44".

    The firmware reads a command line of limited length, and a host may hand over a long list (every
    Wi-Fi channel, say), so lists are sent as ranges. A range only stands for the channels the radio can
    tune to, which is why 36, 40, 44 is one: nothing in between is a channel. By the same rule every
    Wi-Fi channel together is "1-177". The order is sorted, because a board that hops by itself gets
    no better coverage from any other order.
    """
    wanted = sorted(set(channels))
    valid = all_channels(mode)
    parts, i = [], 0
    while i < len(wanted):
        j = i
        while (j + 1 < len(wanted) and wanted[j] in valid and wanted[j + 1] in valid
               and valid.index(wanted[j + 1]) == valid.index(wanted[j]) + 1):
            j += 1
        parts.append("%d" % wanted[i] if i == j else "%d-%d" % (wanted[i], wanted[j]))
        i = j + 1
    return ",".join(parts)


# ----------------------------------------------------------------------------------------------
# Stream parsing
# ----------------------------------------------------------------------------------------------

class MarkerScanner:
    """Finds the start marker in a byte stream that may contain boot messages or stale capture data."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data, nonce):
        """Returns the bytes following the marker line, or None. With a nonce only that marker is accepted."""
        self.buf += data
        pos = 0
        while True:
            m = MARKER_RE.search(self.buf, pos)
            if m is None:
                break
            if nonce is None or m.group(1) == nonce:
                rest = bytes(self.buf[m.end():])
                self.buf.clear()
                return rest
            pos = m.end()
        del self.buf[:max(pos, len(self.buf) - MARKER_TAIL)]
        return None


def signature_at(buf, at):
    """Does a new stream start at buf[at]: "<<START>>", optionally " " and 1 to 16 letters or digits,
    optionally "\\r", then "\\n" and the first 8 bytes of a PCAP global header?

    Returns 1 if it does, 0 if not, and -1 when the buffer ends while it still could.
    """
    n, q = len(buf), at
    for c in START_MARKER:
        if q >= n:
            return -1
        if buf[q] != c:
            return 0
        q += 1
    if q >= n:
        return -1
    if buf[q] == 0x20:
        q += 1
        count = 0
        while count < 16 and q < n and buf[q] in NONCE_BYTES:
            q += 1
            count += 1
        if q >= n:
            return -1
        if count == 0:
            return 0
    if buf[q] == 0x0D:
        q += 1
        if q >= n:
            return -1
    if buf[q] != 0x0A:
        return 0
    q += 1
    for c in PCAP_MAGIC_VER:
        if q >= n:
            return -1
        if buf[q] != c:
            return 0
        q += 1
    return 1


def find_signature(buf, start, end):
    """The first offset in [start, end) where signature_at() is not 0, or None."""
    at = start
    end = min(end, len(buf))
    while at < end:
        at = buf.find(b"<", at, end)
        if at < 0:
            return None
        if signature_at(buf, at) != 0:
            return at
        at += 1
    return None


class PcapFramer:
    """Cuts the stream into the global header and whole records and notices when it stops making sense.

    The frames in the records are copied byte for byte, and whoever transmits chooses what is in them: an
    SSID, advertising data or an 802.15.4 payload can hold "<<START>>\\n" and a PCAP header as easily as
    anything else. So nothing inside a record is ever read as part of the stream. The firmware writes
    every record whole, from one task, and restarts the stream only between records (or reboots):

      1. The global header must be one, with the expected link type. Another link type loses sync
         instead of being accepted: the board is still on the wrong radio, and the answer is to ask
         again, not to hand Kismet frames it will decode as something they are not.
      2. At each record boundary, once 16 bytes are there:
         a. bytes that start with "<<START>>" or "\\n<<START>>" begin a new stream: sync is lost and
            the marker scan goes on from the boundary. No record header starts that way: its ts_usec
            would read "ART>" or "TART", far above 999999.
         b. otherwise they are a record header, which must have ts_usec < 1000000 and
            0 < incl_len <= 16384 and incl_len <= orig_len. The record is passed on once all of it
            is there.
         c. a header that fails (b) loses sync. Only now is the last record passed on looked into: a
            board that resets while its port stays open cuts the record it was sending short, and its
            new marker then sits in what was taken for that record's payload. The search runs from the
            start of the last record passed on (kept in the buffer until the next one is; the boundary
            itself when none was since sync) to 16 bytes past the boundary; the marker scan goes on
            from the first signature_at() there, otherwise from the boundary.

    Set linktype before feeding to say which link type is expected.
    """

    def __init__(self, linktype=None):
        self.buf = bytearray()
        self.linktype = linktype
        self.records = 0
        self.need_global_hdr = True
        self.kept = 0               # the last record passed on, at the start of buf, for rule 2c
        self.right_linktype = None  # whether the last global header had the expected link type
        self.sync_lost = None       # reason, set by feed()

    def resync(self):
        """Sync was lost: the next marker is followed by a new global header. Returns the unparsed bytes."""
        rest = bytes(self.buf)
        self.buf.clear()
        self.need_global_hdr = True
        self.kept = 0
        self.sync_lost = None
        return rest

    def feed(self, data):
        """Returns the complete records as (ts_sec, ts_usec, orig_len, payload). Check sync_lost afterwards."""
        buf = self.buf
        buf += data
        out = []
        pos = self.kept
        prev = 0 if self.kept else None  # where the last record passed on starts
        lost = None
        if self.need_global_hdr:
            if len(buf) < PCAP_GLOBAL_HDR_LEN:
                return out
            magic, major, minor, _, _, _, network = struct.unpack_from("<IHHIIII", buf)
            if magic != PCAP_MAGIC or (major, minor) != (2, 4):
                lost = "bad PCAP global header"
            elif self.linktype is not None and network != self.linktype:
                self.right_linktype = False
                lost = "the board sends link type %d, not %d" % (network, self.linktype)
            else:
                if self.linktype is None:
                    self.linktype = network
                self.right_linktype = True
                pos = PCAP_GLOBAL_HDR_LEN
                self.need_global_hdr = False
        while lost is None and len(buf) - pos >= PCAP_REC_HDR_LEN:
            if buf.startswith(START_MARKER, pos) or buf.startswith(b"\n" + START_MARKER, pos):
                lost = "the board restarted the stream"
                break
            ts_sec, ts_usec, incl_len, orig_len = struct.unpack_from("<IIII", buf, pos)
            if ts_usec >= 1000000 or incl_len > orig_len or not 0 < incl_len <= MAX_RECORD_LEN:
                lost = "damaged PCAP record"
                at = find_signature(buf, pos if prev is None else prev, pos + PCAP_REC_HDR_LEN)
                if at is not None:
                    pos = at
                break
            end = pos + PCAP_REC_HDR_LEN + incl_len
            if end > len(buf):
                break
            out.append((ts_sec, ts_usec, orig_len, bytes(buf[pos + PCAP_REC_HDR_LEN:end])))
            self.records += 1
            prev, pos = pos, end
        if lost is not None:
            del buf[:pos]
            self.kept = 0
            self.sync_lost = lost
            return out
        # keep the last record passed on for rule 2c, drop what came before it
        if prev is None:
            prev = pos
        del buf[:prev]
        self.kept = pos - prev
        return out


# ----------------------------------------------------------------------------------------------
# Serial port
# ----------------------------------------------------------------------------------------------

class PortBusy(serial.SerialException):
    """Someone else holds the port: another source or helper on this board, or a serial monitor."""


class OtherBoard(OSError):
    """The port holds another board than the one looked for: tty names that swapped, or a new board."""


def port_busy_error(error, platform=None):
    """Did opening a port fail because someone holds it?

    POSIX: the flock that pyserial's exclusive=True takes, and kismet_cap_esp32c5 takes as well, is held
    (EWOULDBLOCK), or the open itself is refused because another helper has the tty in exclusive mode
    (EBUSY; see open_serial). Windows opens every COM port for one process only and answers access denied.
    """
    if (platform or sys.platform) == "win32":
        text = str(error)
        return "PermissionError(13" in text or "Access is denied" in text or "WinError 5]" in text
    return getattr(error, "errno", None) in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EBUSY)


def pseudo_terminal(fd, platform=None):
    """Is fd a pseudo-terminal, /dev/pts/N? Only Linux is asked, by the device's major number (136 to 143,
    UNIX98_PTY_SLAVE_MAJOR in linux/major.h); elsewhere the answer is no, and none is needed (open_serial)."""
    if not (platform or sys.platform).startswith("linux"):
        return False
    try:
        st = os.fstat(fd)
    except OSError:
        return False
    return stat.S_ISCHR(st.st_mode) and 136 <= os.major(st.st_rdev) <= 143


def _tty_ioctl(fd, name):
    """TIOCEXCL or TIOCNXCL on an open port, where there is such a thing; like the C helper, errors are
    left alone (a port that went away is noticed by the reads and writes)."""
    request = getattr(termios, name, None) if termios is not None else None
    if request is None or not isinstance(fd, int):
        return
    try:
        fcntl.ioctl(fd, request)
    except OSError:
        pass


def open_serial(port, baud=921600):
    """Opens the port for this helper alone, without resetting the board; PortBusy, with the "already in use"
    message, when another capture has it.

    On POSIX that is the C helper's lock: a flock on the device node, and the tty's exclusive mode
    (TIOCEXCL; on Linux not on a pseudo-terminal), which close_serial ends. On Windows a COM port opens for
    one process only anyway."""
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud  # ignored by the USB-Serial-JTAG port, used by UART bridges
    ser.timeout = 0.1
    ser.write_timeout = 1
    # pyserial asserts DTR and RTS when it opens a port. On Espressif boards those two lines drive reset and
    # boot mode, so the defaults can reboot the chip or leave it in the ROM download mode.
    if sys.platform == "win32":
        # Windows applies both at once, in the DCB, before the port comes up
        ser.dtr = False
        ser.rts = False
        try:
            ser.open()
        except serial.SerialException as e:
            if port_busy_error(e, "win32"):
                raise PortBusy(IN_USE % port)
            raise
        try:
            ser.set_buffer_size(rx_size=1 << 20)
        except Exception:
            close_serial(ser)
            raise
        return ser

    # One process per board, and one source: the same flock kismet_cap_esp32c5 takes, so the two helpers
    # keep out of each other's way. It sits on the device node, which covers /dev/serial/by-id links,
    # and pyserial takes it before it touches the port's settings.
    ser.exclusive = True
    try:
        ser.open()
    except serial.SerialException as e:
        # EBUSY: another helper has the tty in exclusive mode (below)
        if port_busy_error(e, sys.platform):
            raise PortBusy(IN_USE % port)
        raise
    # The flock is on the node's inode, though, and a container makes a /dev/ttyACM0 of its own (mknod),
    # another inode for the same tty: a helper there does not see the lock of one on the host or in
    # another container, nor they its. So the tty itself goes into exclusive mode too, as the C helper
    # does (serial_open there), which the kernel keeps with the tty whichever node it was opened
    # through: every other open of it fails with EBUSY until this helper closes it, or dies -- Linux ends
    # the mode with the tty's last close. A process with CAP_SYS_ADMIN is let in all the same: esptool or
    # this helper run with sudo. Not on a pseudo-terminal (the fake board, socat): Linux keeps one's tty,
    # and the mode with it, for as long as its other end is open, so a helper killed before it could end
    # the mode would lock the next one out; and a pseudo-terminal can only be opened through its node in
    # /dev/pts, where the flock is.
    if not pseudo_terminal(ser.fd):
        _tty_ioctl(ser.fd, "TIOCEXCL")
    # POSIX raises both lines when the device node is opened and pyserial then writes DTR before RTS,
    # so clearing them beforehand would pass through "DTR released, RTS asserted", which resets the chip.
    for line in ("rts", "dtr"):
        try:
            setattr(ser, line, False)
        except OSError as e:
            # A pseudo-terminal (the fake board, socat, ser2net) has no modem lines. pyserial ignores
            # these two errors from the same calls in its own open(), and so does this.
            if e.errno not in (errno.EINVAL, errno.ENOTTY):
                close_serial(ser)
                raise
    return ser


def close_serial(ser):
    """Close the port and release the OS handle even if close() fails.

    pyserial does several things before it releases the handle, and one of them can fail when the board
    was unplugged or reset in the middle of a transfer. The handle then stays open for as long as this
    program runs, and every attempt to reopen the port is refused with "access denied".

    On POSIX the tty's exclusive mode (open_serial) is ended first. The close ends it only when it is the
    tty's last: when someone else has the tty open too (a program that had it before this helper, which
    does not take the flock, or one with CAP_SYS_ADMIN), the mode would stay, and refuse this helper's own
    next open.
    """
    if ser is None:
        return
    if getattr(ser, "is_open", False):
        _tty_ioctl(getattr(ser, "fd", None), "TIOCNXCL")
    try:
        ser.close()
        return
    except Exception:
        pass
    try:
        if getattr(ser, "_port_handle", None) is not None:  # Windows
            import serial.win32
            serial.win32.CloseHandle(ser._port_handle)
            ser._port_handle = None
        elif getattr(ser, "fd", None) is not None:  # Linux, macOS
            os.close(ser.fd)
            ser.fd = None
    except Exception:
        pass
    ser.is_open = False


def port_locked(device, platform=None, locks="/proc/locks"):
    """Does another process hold the flock on this port -- a capture on it, from either helper (open_serial's
    lock is kismet_cap_esp32c5's), or picocom, which takes it too? port_locked() in the C helper.

    Looked up in /proc/locks by the device and inode the lock sits on, without opening the port: opening it
    raises DTR and RTS, which reset the board someone is capturing from. This process's own locks do not
    count; it holds one on every port it has open. Linux only. Elsewhere, or without /proc/locks, nothing
    is known to be locked -- on Windows only a trial open could tell, and that would move DTR and RTS. A
    board held from another container, or from the host when this runs in a container, is missed as well:
    /proc/locks shows the locks of the processes this one can see, on the node they opened. Its open still
    fails as in use, the tty being in exclusive mode (open_serial).
    """
    if not (platform or sys.platform).startswith("linux"):
        return False
    try:
        st = os.stat(device)
        with open(locks) as f:
            lines = f.read().splitlines()
    except OSError:
        return False
    # "12: FLOCK  ADVISORY  WRITE 3067 00:05:595 0 EOF": the pid, then the file system's device as the kernel
    # prints it, major and minor in hex, and the inode. A lock being waited for has "->" after the number,
    # and the one holding it a line of its own.
    want = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    me = str(os.getpid())
    for line in lines:
        fields = line.split()
        if len(fields) >= 6 and fields[1] == "FLOCK" and fields[5] == want and fields[4] != me:
            return True
    return False


# ----------------------------------------------------------------------------------------------
# Finding the boards, and knowing them again
# ----------------------------------------------------------------------------------------------

MAC_RE = re.compile(r"(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}")


def find_boards():
    """Every Espressif chip on its native USB port (USB ID 303a:1001) plugged in now, in a stable order.

    The ID is the same for every chip with a USB-Serial-JTAG port (ESP32-C3, C5, C6, H2, S3, P4 ...), so
    this cannot tell an ESP32-C5 sniffer from any other ESP32 on native USB."""
    boards = [p for p in list_ports.comports() if (p.vid, p.pid) == ESPRESSIF_USB_JTAG]
    return sorted(boards, key=lambda p: _natural_key(p.device))


def _natural_key(device):
    m = re.search(r"(\d+)$", device or "")
    return (device[:m.start()] if m else device, int(m.group(1)) if m else 0)


def board_mac(port_info):
    """The board's MAC address, which most boards report as their USB serial number, or None."""
    serial_number = (port_info.serial_number or "").strip()
    if MAC_RE.fullmatch(serial_number):
        return serial_number.replace("-", ":").upper()
    return None


def port_key(device, platform=None):
    """One spelling per port, to tell whether two names mean the same port.

    Windows: COM14, com14 and \\\\.\\COM14 are all COM14, and other names compare without case.
    Elsewhere it is the device node a path leads to, so a /dev/serial/by-id link and the ttyACM it
    points at are one port, as they are to the lock.
    """
    if (platform or sys.platform) == "win32":
        name = device.strip()
        if name.startswith("\\\\.\\"):
            name = name[4:]
        m = re.fullmatch(r"(?i)com(\d+)", name)
        return "COM%d" % int(m.group(1)) if m else name.upper()
    return os.path.realpath(device)


def port_exists(device, platform=None):
    """Is the port there right now? Windows lists the devices that are present, a board that has
    stopped answering included; elsewhere the device node exists or it does not.

    pyserial lists only the devices of the Ports and Modem setup classes. A virtual COM port from a driver
    of another class (com0com, some serial-over-network drivers) is not among them, yet it opens; it is
    known by its DOS device name, which exists exactly while a driver provides the port."""
    if (platform or sys.platform) == "win32":
        key = port_key(device, "win32")
        return any(port_key(p.device, "win32") == key for p in list_ports.comports()) or _dos_device_exists(key)
    return os.path.exists(device)


ERROR_INSUFFICIENT_BUFFER = 122


def _dos_device_exists(name):
    """Does Windows have a DOS device by this name (COM14, CNCA0)? False wherever it cannot be asked."""
    if sys.platform != "win32":
        return False
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        query = kernel32.QueryDosDeviceW
        query.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD]
        query.restype = wintypes.DWORD
        buf = ctypes.create_unicode_buffer(1024)
        if query(name, buf, len(buf)):
            return True
        # a name with more targets than fit is there all the same
        return ctypes.get_last_error() == ERROR_INSUFFICIENT_BUFFER
    except Exception:
        return False


def mac_of_port(device, boards=None, platform=None):
    """The MAC of the board on this port, however the port is written (a by-id link, com14), or None."""
    key = port_key(device, platform)
    for p in find_boards() if boards is None else boards:
        if port_key(p.device, platform) == key:
            return board_mac(p)
    return None


def find_port_by_mac(mac, boards=None):
    """The port the board with this MAC is on now, or None."""
    for p in find_boards() if boards is None else boards:
        if board_mac(p) == mac:
            return p.device
    return None


def _sysfs_board_mac(tty):
    """tty_is_board() in capture_esp32c5.c: the MAC of the Espressif USB-Serial-JTAG device on /dev/<tty>,
    or "" when it is not one or reports no MAC."""
    usb = os.path.dirname(os.path.realpath("/sys/class/tty/%s/device" % tty))  # the interface's USB device
    try:
        with open(os.path.join(usb, "idVendor")) as f:
            vid = f.read().strip().lower()
        with open(os.path.join(usb, "idProduct")) as f:
            pid = f.read().strip().lower()
    except OSError:
        return ""
    if (vid, pid) != ("303a", "1001"):
        return ""
    try:
        with open(os.path.join(usb, "serial")) as f:
            serial_number = f.read().strip()
    except OSError:
        return ""
    digits = ""
    for c in serial_number:
        if len(digits) == 12:
            break
        if c in "0123456789abcdefABCDEF":
            digits += c.upper()
        elif c not in ":-":
            break
    if len(digits) != 12:
        return ""
    return ":".join(digits[i:i + 2] for i in range(0, 12, 2))


def port_identity(ser, port, platform=None):
    """The MAC of the board an open port belongs to; "" when it is not an Espressif board with a MAC,
    None when there is no way to tell.

    Linux asks sysfs about the open file descriptor rather than the name, as fd_is_board() in the C helper
    does: the descriptor holds the device number, so the answer cannot change under it the way a tty name
    can. Windows looks the port up in the device list; COM numbers follow a board's serial number there.
    """
    if (platform or sys.platform) == "win32":
        key = port_key(port, "win32")
        for p in list_ports.comports():
            if port_key(p.device, "win32") == key:
                return (board_mac(p) or "") if (p.vid, p.pid) == ESPRESSIF_USB_JTAG else ""
        return None
    fd = getattr(ser, "fd", None)
    if not isinstance(fd, int):
        return None
    try:
        st = os.fstat(fd)
    except OSError:
        return None
    if not stat.S_ISCHR(st.st_mode) or not os.path.isdir("/sys/dev/char"):
        return None
    node = "/sys/dev/char/%d:%d" % (os.major(st.st_rdev), os.minor(st.st_rdev))
    if not os.path.exists(node):
        return ""
    return _sysfs_board_mac(os.path.basename(os.path.realpath(node)))


def port_holds(ser, port, mac):
    """True when the open port is the board with this MAC, False when it is another, None when unknown."""
    found = port_identity(ser, port)
    return None if found is None else found == mac


# ----------------------------------------------------------------------------------------------
# The link
# ----------------------------------------------------------------------------------------------

class BoardLink(threading.Thread):
    """Keeps one board capturing and passes every frame to on_packet(ts_sec, ts_usec, orig_len, payload).

    Survives the board rebooting (which it does whenever it is asked for another radio), being
    unplugged and plugged back in, and a damaged stream. on_status(text, kind) says what it is doing, for
    logs and for Kismet's source status; kind is "opened", "capturing", "lost" (sync), "error" or "info".
    Each text starts with name, the source's (the port when none is given), in the C helper's words where
    it has them: "<name> capturing (<radio>)", "<name>: lost sync (<why>)", "<name>: <why>, reconnecting".
    The "capturing" status, and the capturing attribute, wait for the PCAP header after the marker to have
    the radio's link type: a board whose firmware lacks the radio answers in another one, which is lost
    sync, said once however often it is asked again. Channel and dwell changes take effect immediately while
    capturing and are repeated to the board after every reconnect.

    A board is known by its MAC, which it reports as its USB serial number: mac, or what the first open
    finds. A reopened port is checked to still hold that board, since boards that reboot together can
    come back with their tty names swapped, and a board that moved is found again by its MAC -- for that
    attempt only: the port it was given stays the one tried first.
    """

    def __init__(self, port, mode, channels, dwell_ms, on_packet, on_status=None, mac=None, name=None):
        super().__init__(daemon=True)
        if mode not in MODE_COMMAND:
            raise ValueError("unknown radio %r" % mode)
        self.name = name or port
        self.port = port
        self.current_port = port  # where it was last opened: port, or where its MAC was found
        self.mode = mode
        self.mac = mac
        self.channels = list(channels)
        self.dwell_ms = int(dwell_ms)
        self.on_packet = on_packet
        self.on_status = on_status or (lambda text, kind="info": None)
        self.linktype = MODE_LINKTYPE[mode]
        self.packets = 0
        self.sync_losses = 0
        self.synced = False     # our marker found: what follows is the stream we asked for
        self.capturing = False  # ... and its PCAP header had our link type
        # The first open, for whoever has to say whether the board could be opened at all
        self.first_attempt = threading.Event()
        self.open_error = None
        self._last_status = None
        self._ser = None
        self._lock = threading.Lock()  # one writer at a time: the capture loop and whoever retunes
        # Not self._stop: that name is threading.Thread's own method before Python 3.13, and shadowing it
        # makes join() and is_alive() raise "'Event' object is not callable" once the thread has ended.
        self._stop_event = threading.Event()

    @property
    def last_status(self):
        return self._last_status

    # --- called from other threads ---

    def set_channels(self, channels):
        channels = list(channels)
        bad = [c for c in channels if not channel_is_valid(c, self.mode)]
        if bad or not channels:
            raise ValueError("channel %s is not valid for this radio" % (bad[0] if bad else "list is empty"))
        # Under the lock, so that a handshake going out at the same time cannot send a stale list after it
        with self._lock:
            self.channels = channels
            self._write_locked(b"CHANNELS %s\n" % format_channel_spec(channels, self.mode).encode())

    def set_dwell(self, dwell_ms):
        dwell_ms = int(dwell_ms)
        if not MIN_DWELL_MS <= dwell_ms <= MAX_DWELL_MS:
            raise ValueError("dwell must be between %d and %d ms" % (MIN_DWELL_MS, MAX_DWELL_MS))
        with self._lock:
            self.dwell_ms = dwell_ms
            self._write_locked(b"DWELL %d\n" % dwell_ms)

    def stop(self):
        self._stop_event.set()

    def _write_locked(self, data):
        """Best effort: a port that is gone is noticed and reopened by the capture loop."""
        ser = self._ser
        if ser is None:
            return  # sent with the next START
        try:
            ser.write(data)
        except (serial.SerialException, OSError):
            pass

    # --- the capture loop ---

    def _send_mode(self, ser):
        # MODE goes on its own, and first: it decides the link type, and the channel numbering differs
        # between the radios. A board already listening with the radio we want ignores it; one that is not
        # reboots, and for about half a second hears nothing, so START follows MODE_SETTLE_S later.
        #
        # Write errors are deliberately not caught here. A board that has just rebooted is most often
        # found by a write failing; the caller treats it as a disconnect and reopens.
        with self._lock:
            ser.write(b"MODE %s\n" % MODE_COMMAND[self.mode])

    def _send_start(self, ser):
        nonce = secrets.token_hex(4).encode()
        with self._lock:
            cmd = b"CHANNELS %s\n" % format_channel_spec(self.channels, self.mode).encode()
            cmd += b"DWELL %d\n" % self.dwell_ms
            cmd += b"START %d %s\n" % (time.time_ns() // 1000, nonce)
            ser.write(cmd)
        return nonce

    def run(self):
        scanner, framer = MarkerScanner(), PcapFramer(self.linktype)
        # nonce: of the last START; None until one has gone out on this port, and no marker is ours then.
        # mode_sent: when MODE went out, while its START is still to follow.
        nonce, last_start, last_byte, mode_sent = None, 0.0, 0.0, None
        while not self._stop_event.is_set():
            try:
                if self._ser is None:
                    try:
                        ser = self._open()
                    except BaseException as e:
                        if not self.first_attempt.is_set():
                            self.open_error = e
                        raise
                    finally:
                        self.first_attempt.set()
                    with self._lock:
                        self._ser = ser
                    self._status("%s: %s opened" % (self.name, self.current_port), "opened")
                    nonce, last_start, mode_sent, last_byte = None, 0.0, None, time.monotonic()
                data = self._ser.read(self._ser.in_waiting or 1)
            except (serial.SerialException, OSError, ValueError) as e:
                self._disconnected(e, scanner, framer)
                continue

            # What has arrived is read before deciding whether to ask again: a new START changes the
            # nonce, and the answer to the previous one may be sitting in this very read.
            if data:
                last_byte = time.monotonic()
                if self._consume(data, scanner, framer, nonce):
                    last_start, mode_sent = 0.0, None  # only a fresh START brings a marker with our nonce

            # Until capturing, not only until our marker comes: a board that sends it and part of a header, then
            # goes quiet (a reset, or its USB gone with the handle left open), is asked again and reopened like
            # one that never answered, as in the C helper
            if self.capturing:
                continue
            now = time.monotonic()
            try:
                # Asked for whether or not bytes are arriving: a board that lost sync on a busy channel
                # keeps sending records and never goes quiet. A write is also how a port whose board has
                # rebooted gives itself away. The loop keeps reading while MODE settles, so a port that
                # goes away in the reboot is noticed at once.
                if mode_sent is not None:
                    if now - mode_sent >= MODE_SETTLE_S:
                        mode_sent = None
                        nonce = self._send_start(self._ser)
                elif now - last_start > START_RETRY_S:
                    last_start = now
                    if framer.right_linktype:
                        # the last global header from this port had our link type: the board is on our
                        # radio already, and a resync need not wait for a MODE it would ignore
                        nonce = self._send_start(self._ser)
                    else:
                        self._send_mode(self._ser)
                        mode_sent = now
                if now - last_byte > STALL_TIMEOUT_S:
                    # A board that reboots can take its USB device with it, and Windows does not always
                    # fail the reads and writes that follow -- the handle can stay open and silent. Only
                    # before capture, though: once capturing, silence is just a quiet channel.
                    raise OSError("no answer")
            except (serial.SerialException, OSError, ValueError) as e:
                self._disconnected(e, scanner, framer)

        with self._lock:
            ser, self._ser = self._ser, None
        close_serial(ser)

    def _open(self):
        """Opens the port for another round (reopen_port() in the C helper).

        The port it was given comes first, but only if it still holds this board: boards that reboot
        together can come back with their tty names swapped, and a board that is not ours must not be
        sent MODE or read from under our name. When ours is elsewhere now, its MAC finds it.

        As in the C helper, a port that holds another board is said once, as "now holds another board",
        and not again as the attempt's error: every attempt while it lasts says the same line, which
        _status() passes on once. (Ours found on a busy port is said as well, and the two then take
        turns, as they do in the C helper.)
        """
        error = None
        try:
            ser = open_serial(self.port)
        except (serial.SerialException, OSError, ValueError) as e:
            ser, error = None, e
        if ser is not None and self.mac and port_holds(ser, self.port, self.mac) is False:
            self._status("%s: %s now holds another board, looking for %s" % (self.name, self.port, self.mac),
                         "info")
            close_serial(ser)
            ser, error = None, OtherBoard("%s holds another board than %s" % (self.port, self.mac))
        where = self.port
        if ser is None and self.mac:
            other = find_port_by_mac(self.mac)
            if other is not None and port_key(other) != port_key(self.port):
                try:
                    ser = open_serial(other)
                except (serial.SerialException, OSError, ValueError) as e:
                    if isinstance(e, PortBusy) or not isinstance(error, (PortBusy, OtherBoard)):
                        error = e
                else:
                    if port_holds(ser, other, self.mac) is False:
                        close_serial(ser)
                        ser = None
                    else:
                        where = other
                        self._status("%s: board %s is on %s now" % (self.name, self.mac, other), "info")
        if ser is None:
            raise error
        if not self.mac:
            self.mac = port_identity(ser, where) or None
        self.current_port = where
        return ser

    def _consume(self, data, scanner, framer, nonce):
        """Find our marker, then pass on whole records. Returns True when sync was lost on the way."""
        lost = False
        while True:
            if not self.synced:
                if nonce is None:
                    return lost  # nothing asked on this port yet: no marker can be the answer
                data = scanner.feed(data, nonce)
                if data is None:
                    return lost
                self.synced = True
            records = framer.feed(data)
            if not self.capturing and not framer.need_global_hdr:
                # Only now, not at the marker: a board whose firmware lacks this radio answers START too,
                # with a header in another link type, and would say "capturing" and "lost sync" in turn
                self.capturing = True
                self._status("%s capturing (%s)" % (self.name, RADIO_NAME[self.mode]), "capturing")
            for record in records:
                self.packets += 1
                self.on_packet(*record)
            if not framer.sync_lost:
                return lost
            self.sync_losses += 1
            self._status("%s: lost sync (%s)" % (self.name, framer.sync_lost), "lost")
            self.synced = self.capturing = False
            lost = True
            data = framer.resync()

    def _disconnected(self, error, scanner, framer):
        with self._lock:
            ser, self._ser = self._ser, None
        if ser is not None:
            close_serial(ser)
            self.synced = self.capturing = False
            framer.resync()  # a half received record is of no use
            scanner.buf.clear()
        framer.right_linktype = None  # what comes back may have rebooted into anything
        # The first open's error is open_error, and whoever started the link may give up on it (the remote
        # helper ends that connection), so it says nothing of waiting. Later the link goes on trying, as the
        # C helper does, and says so.
        if isinstance(error, PortBusy) and error is not self.open_error:
            self._status("%s: %s; waiting for it" % (self.name, error), "error")
        elif ser is not None:
            # the C helper's drop_port(); the why is pyserial's, which has no errno to say it in the C's words
            self._status("%s: %s, reconnecting" % (self.name, error), "error")
        elif not isinstance(error, OtherBoard):  # _open() has said that one already
            # an open that failed, which names the port; the C helper tries again without a word
            self._status("%s: %s" % (self.name, error), "error")
        self._stop_event.wait(1)

    def _status(self, text, kind="info"):
        """Passes a status on when it changes, not once a second while a port stays unplugged."""
        if text != self._last_status:
            self._last_status = text
            self.on_status(text, kind)
