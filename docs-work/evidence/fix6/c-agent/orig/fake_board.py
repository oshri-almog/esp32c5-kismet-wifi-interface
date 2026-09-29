#!/usr/bin/env python3
"""A stand-in for an ESP32-C5 sniffer board, on a pseudo-terminal. POSIX only (Linux, WSL).

For developing and testing the Kismet helpers without hardware: tests/kismet_e2e.sh (the C helper,
kismet_cap_esp32c5), tests/remote_e2e.sh (the Python remote helper) and the Docker demo image, where
docker/entrypoint.sh starts it from /opt/esp32c5/fake_board.py (tests/docker_smoke.sh). It speaks
the firmware's line protocol and streams made-up traffic that depends on the channel it is tuned
to, so hopping and both Wi-Fi bands can be seen working in Kismet:

    python3 tools/fake_board.py /tmp/esp32c5-fake            creates the port, Wi-Fi to start with
    kismet -c esp32c5:device=/tmp/esp32c5-fake

The C helper also takes the pseudo-terminal by its name (esp32c5-pts/3). Run this as the user that
Kismet, or the helper opening the port, runs as: the pseudo-terminal is its maker's (mode 0620), and
kismet_cap_esp32c5 drops every capability, root's power to open other users' files included. A
Kismet started with sudo needs this started with sudo as well.

    Wi-Fi     three access points: ESP32C5-FAKE-24 on channel 6, -5LOW on 36, -5HIGH on 149
    802.15.4  a node sending data frames on channel 15, and another on 25
    BTLE      an advertiser called ESP32C5-FAKE (the radio scans 37-39 together, so always)

At start it prints a line of boot text (ESP-ROM:esp32c5-fake), which the helpers have to skip, then
its boot marker and a PCAP header. Like the firmware it remembers its radio, and asking for another
one reboots it. As on the real board, whose USB-Serial-JTAG port stays enumerated through a software
reset, the port stays open: the board is deaf for about half a second, drops whatever it is sent
meanwhile, then prints its boot marker and a PCAP header in the new link type. With --vanish the
port goes away instead, for two seconds, and comes back as a new pseudo-terminal behind the same path.

Where it differs from the firmware (the wiki's Firmware-Protocol page has the real thing): it
remembers its radio only while it runs, so each start boots in the radio on its command line; it
reads command words in any case; it ignores TXTEST and commands it does not know, and refuses
CHANNELS 0 and AUTO; its timestamps are wall-clock time whatever START says; in 802.15.4 it starts
locked on channel 15, where the firmware's built-in list hops 11-26; and it has no MAC and no UART
log: its "[fake]" lines on standard output take the log's place.

Options for testing the helpers' stream handling:
    --garble N          every Nth record gets a header no stream can contain
    --inject N          every Nth record is a frame whose payload holds the whole restart signature,
                        "<<START>>\\n" and a PCAP header, as anyone on the air could send
    --restart-every N   every Nth record the board restarts its stream in place, as after a reset
                        that keeps the port: every other time right after a record, otherwise after
                        a record cut short
    --old-firmware      BTLE records the way older firmware sends them (esp32c5-wireshark-sniffer
                        1.2.0): no CRC flags, CRC zeroed, which the helpers have to fill in

The Nth record is counted from the last START answered, so each of these lands in a stream a helper
asked for and is reading, never in what the board sends before anyone has the port open.

Stop it with Ctrl+C. https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Development-and-Testing
describes it in full.
"""

import os
import select
import struct
import sys
import time
import tty

MODES = {"WIFI": ("wifi", 127), "802154": ("802154", 283), "ZIGBEE": ("802154", 283),
         "THREAD": ("802154", 283), "BLE": ("ble", 256), "BT": ("ble", 256),
         "BLUETOOTH": ("ble", 256)}
LINKTYPE = {"wifi": 127, "802154": 283, "ble": 256}
START_CHANNEL = {"wifi": 6, "802154": 15, "ble": 37}
# About 100 records a second while tuned to a channel with traffic. Kismet hops 42 Wi-Fi channels
# and only 3 have an access point, so a hopping source still sees a few hundred records a minute.
RECORD_INTERVAL = 0.01
# Time on each channel of a list, as DWELL sets it on the firmware
DEFAULT_DWELL_MS = 250
# The firmware's scan list holds every channel it can tune to: 1-14, 36-64, 100-144, 149-177
MAX_SCAN_CHANNELS = 14 + 8 + 12 + 8
# From MODE to the boot marker on the real board, with the port staying open
REBOOT_S = 0.53

WIFI_APS = {6: ("ESP32C5-FAKE-24", b"\x02\xe5\xc5\x00\x00\x06"),
            36: ("ESP32C5-FAKE-5LOW", b"\x02\xe5\xc5\x00\x00\x24"),
            149: ("ESP32C5-FAKE-5HIGH", b"\x02\xe5\xc5\x00\x00\x95")}
ZIGBEE_NODES = {15: 0x1001, 25: 0x2501}

# What --inject puts on the air: the restart signature as it appears on the wire
PCAP_MAGIC_VER = struct.pack("<IHH", 0xA1B2C3D4, 2, 4)
INJECT_BSSID = b"\x02\xe5\xc5\x00\x00\x99"
INJECT_SSID = b"FAKE-INJECT<<START>>\n" + PCAP_MAGIC_VER


def channel_ok(mode, ch):
    if mode == "ble":
        return ch == 37
    if mode == "802154":
        return 11 <= ch <= 26
    return (1 <= ch <= 14 or (36 <= ch <= 64 and (ch - 36) % 4 == 0)
            or (100 <= ch <= 144 and (ch - 100) % 4 == 0) or (149 <= ch <= 177 and (ch - 149) % 4 == 0))


def parse_spec(spec, mode):
    """The firmware's rule: "6", "1,6,11", "1-11", "1-13,36,149-165". A single number has to be a
    channel of the radio; a range keeps the ones inside it. None when the spec is no good, or holds
    more channels than the scan list, which the firmware refuses rather than cut short."""
    out = []
    for part in spec.split(","):
        lo_s, dash, hi_s = part.partition("-")
        try:
            lo = int(lo_s)
            hi = int(hi_s) if dash else lo
        except ValueError:
            return None
        if not 1 <= lo <= hi <= 177 or (not dash and not channel_ok(mode, lo)):
            return None
        for ch in range(lo, hi + 1):
            if channel_ok(mode, ch) and ch not in out:
                if len(out) == MAX_SCAN_CHANNELS:
                    return None
                out.append(ch)
    return out or None


def beacon(ch, seq, ssid, bssid, extra=b""):
    freq = (2484 if ch == 14 else 2407 + 5 * ch) if ch <= 14 else 5000 + 5 * ch
    chan_flags = (0x0080 | 0x0020) if ch <= 14 else (0x0100 | 0x0040)
    radiotap = struct.pack("<BBHIBBHHbb", 0, 0, 16, (1 << 1) | (1 << 3) | (1 << 5) | (1 << 6),
                           0, 0, freq, chan_flags, -40 - (seq % 10), -95)
    body = struct.pack("<QHH", seq * 102400, 100, 0x0431)
    body += bytes([0, len(ssid)]) + ssid
    body += bytes([1, 4, 0x82, 0x84, 0x8B, 0x96])
    body += bytes([3, 1, ch])
    body += extra
    header = struct.pack("<HH", 0x0080, 0) + b"\xff" * 6 + bssid + bssid + struct.pack("<H", (seq & 0xFFF) << 4)
    return radiotap + header + body


def wifi_frame(ch, seq):
    ap = WIFI_APS.get(ch)
    if ap is None:
        return None
    ssid, bssid = ap
    return beacon(ch, seq, ssid.encode(), bssid)


def wifi_inject(ch, seq):
    # The SSID carries "<<START>>\n" and the PCAP magic; a vendor element carries a whole stream
    # start, marker with a nonce and a complete global header
    vendor = b"\x00\xe5\xc5\x01" + b"\n<<START>> 0badc0de\n" + global_header("wifi")
    return beacon(ch, seq, INJECT_SSID, INJECT_BSSID, bytes([221, len(vendor)]) + vendor)


def tap_header(ch, seq):
    tap = struct.pack("<BBH", 0, 0, 48)
    tap += struct.pack("<HHB3x", 0, 1, 0)                      # FCS type: none
    tap += struct.pack("<HHf", 1, 4, -55.0 - (seq % 5))        # RSS, dBm
    tap += struct.pack("<HHHBx", 3, 3, ch, 0)                  # channel, page 0
    tap += struct.pack("<HHB3x", 10, 1, 200)                   # LQI
    tap += struct.pack("<HHQ", 5, 8, time.time_ns())           # start of frame
    return tap


def zigbee_frame(ch, seq):
    node = ZIGBEE_NODES.get(ch)
    if node is None:
        return None
    mac = struct.pack("<BBBHHH", 0x41, 0x88, seq & 0xFF, 0x1234, 0xFFFF, node) + b"esp32c5 fake node"
    return tap_header(ch, seq) + mac


def zigbee_inject(ch, seq):
    mac = struct.pack("<BBBHHH", 0x41, 0x88, seq & 0xFF, 0x1234, 0xFFFF, 0x0999)
    return tap_header(ch, seq) + mac + b"\n<<START>>\n" + global_header("802154")


def ble_crc(pdu):
    state = 0xAAAAAA
    for cur in pdu:
        for _ in range(8):
            nxt = (state ^ cur) & 1
            cur >>= 1
            state >>= 1
            if nxt:
                state |= 1 << 23
                state ^= 0x5A6000
    return struct.pack("<I", state)[:3]


def ble_record(adva, data, seq, old_firmware):
    pdu = bytes([0x40, len(adva) + len(data)]) + adva + data
    flags = 0x0001 | 0x0002 | 0x0010
    crc = b"\0\0\0"
    if not old_firmware:
        flags |= 0x0400 | 0x0800
        crc = ble_crc(pdu)
    phdr = struct.pack("<BbbBIH", 0, -62 - (seq % 6), 0, 0, 0x8E89BED6, flags)
    return phdr + struct.pack("<I", 0x8E89BED6) + pdu + crc


def ble_frame(ch, seq, old_firmware=False):
    data = b"\x02\x01\x06" + bytes([1 + len(b"ESP32C5-FAKE"), 0x09]) + b"ESP32C5-FAKE"
    return ble_record(b"\x5a\xe5\xc5\x00\x00\xc6", data, seq, old_firmware)


def ble_inject(ch, seq, old_firmware=False):
    signature = b"<<START>>\n" + PCAP_MAGIC_VER
    data = b"\x02\x01\x06" + bytes([1 + 2 + len(signature), 0xFF, 0xE5, 0xC5]) + signature
    return ble_record(b"\x5a\xe5\xc5\x00\x00\x99", data, seq, old_firmware)


def global_header(mode):
    return struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, LINKTYPE[mode])


FRAMES = {"wifi": wifi_frame, "802154": zigbee_frame, "ble": ble_frame}
INJECTS = {"wifi": wifi_inject, "802154": zigbee_inject, "ble": ble_inject}


def log(text):
    print("[fake] " + text, flush=True)


class FakeBoard:
    def __init__(self, path, mode, garble_every=0, inject_every=0, restart_every=0,
                 vanish=False, old_firmware=False):
        self.path = path
        self.mode = mode
        self.channels = [START_CHANNEL[mode]]
        self.dwell_ms = DEFAULT_DWELL_MS
        self.master = None
        self.seq = 0
        self.sent = 0
        self.streaming = False
        self.garble_every = garble_every
        self.inject_every = inject_every
        self.restart_every = restart_every
        self.restarts = 0
        self.vanish = vanish
        self.old_firmware = old_firmware
        self.reboot_to = None      # the mode being rebooted into, while the port stays open
        self.reboot_done = 0.0
        self.line = b""

    def boot(self):
        self.master, slave = os.openpty()
        # Never block on a port nobody reads: the board drops the record instead
        os.set_blocking(self.master, False)
        tty.setraw(slave)
        name = os.ttyname(slave)
        os.close(slave)  # the helper opens it by name; the master keeps it alive
        tmp = self.path + ".tmp"
        if os.path.lexists(tmp):
            os.unlink(tmp)
        os.symlink(name, tmp)
        os.replace(tmp, self.path)
        self.channels = [START_CHANNEL[self.mode]]
        log("booted in %s mode on %s -> %s" % (self.mode, self.path, name))
        # what the firmware prints at boot: a plain marker and a header, then capture
        self.send(b"ESP-ROM:esp32c5-fake\r\n\n<<START>>\n" + self.global_header())
        self.streaming = True

    def global_header(self):
        return global_header(self.mode)

    def send(self, data):
        try:
            os.write(self.master, data)
        except OSError:
            pass  # nobody has the port open; the bytes are lost, as on the real board

    def reboot(self, mode):
        self.line = b""
        if self.vanish:
            log("MODE %s: rebooting, the port goes away" % mode)
            os.close(self.master)
            self.master = None
            self.mode = mode
            time.sleep(2)
            self.boot()
            return
        # The port stays; the board hears nothing until it is up again
        log("MODE %s: rebooting" % mode)
        self.streaming = False
        self.reboot_to = mode
        self.reboot_done = time.monotonic() + REBOOT_S

    def rebooted(self):
        self.mode = self.reboot_to
        self.reboot_to = None
        self.channels = [START_CHANNEL[self.mode]]
        self.dwell_ms = DEFAULT_DWELL_MS
        self.line = b""
        log("rebooted in %s mode, the port stayed open" % self.mode)
        self.send(b"\n<<START>>\n" + self.global_header())
        self.streaming = True

    def command(self, line):
        parts = line.split()
        if not parts:
            return
        if self.reboot_to is not None:
            log("rebooting, lost: %s" % line)
            return
        cmd, args = parts[0].upper(), parts[1:]
        if cmd == "MODE" and args and args[0].upper() in MODES:
            mode = MODES[args[0].upper()][0]
            if mode != self.mode:
                self.reboot(mode)
        elif cmd in ("CHANNEL", "CHANNELS") and args:
            picked = parse_spec(args[0], self.mode)
            if picked:
                self.channels = picked
                log("CHANNELS %s: scanning %d channel(s)" % (args[0], len(picked)))
            else:
                log("cannot use channel list '%s'" % args[0])
        elif cmd == "DWELL" and args and args[0].isdigit() and 20 <= int(args[0]) <= 60000:
            self.dwell_ms = int(args[0])
        elif cmd == "START":
            nonce = args[1].encode() if len(args) > 1 else b""
            # the firmware's answer, leading line end and all
            self.send(b"\n<<START>>" + (b" " + nonce if nonce else b"") + b"\n" + self.global_header())
            self.streaming = True
            # --garble, --inject and --restart-every count from here: a START is the one sign that
            # a helper has the port open and is reading this stream
            self.sent = 0
            log("START answered")

    def record(self):
        ch = self.channels[int(time.monotonic() * 1000 / self.dwell_ms) % len(self.channels)]
        frame = FRAMES[self.mode](ch, self.seq)
        self.seq += 1
        if frame is None:
            return  # nothing on this channel
        self.sent += 1
        # count records actually sent: with Kismet hopping most turns send nothing
        if self.inject_every and self.sent % self.inject_every == 0:
            frame = INJECTS[self.mode](ch, self.seq)
            log("injected a frame holding the restart signature")
        elif self.mode == "ble" and self.old_firmware:
            frame = ble_frame(ch, self.seq, old_firmware=True)
        now = time.time_ns() // 1000
        incl = len(frame)
        if self.garble_every and self.sent % self.garble_every == 0:
            incl = 0xFFFF  # a record header no stream can contain: the helper has to resync
        record = struct.pack("<IIII", now // 1000000, now % 1000000, incl, len(frame)) + frame
        if self.restart_every and self.sent % self.restart_every == 0:
            self.restarts += 1
            if self.restarts % 2:
                log("stream restarted in place (#%d), after a record" % self.restarts)
                self.send(record + b"\n<<START>>\n" + self.global_header())
            else:
                log("stream restarted in place (#%d), after a record cut short" % self.restarts)
                self.send(record[:len(record) // 2] + b"\n<<START>>\n" + self.global_header())
            return
        self.send(record)

    def run(self):
        self.boot()
        while True:
            ready, _, _ = select.select([self.master], [], [], RECORD_INTERVAL)
            if ready:
                try:
                    data = os.read(self.master, 4096)
                except OSError:
                    # EIO: no one has the port open. select() keeps saying so at once, so wait
                    # here rather than spin.
                    data = b""
                    time.sleep(RECORD_INTERVAL)
                for b in data:
                    if b == 0x0A:
                        self.command(self.line.decode("ascii", "replace").strip())
                        self.line = b""
                    else:
                        self.line += bytes([b])
                if self.master is None:
                    continue
            if self.reboot_to is not None and time.monotonic() >= self.reboot_done:
                self.rebooted()
            if self.streaming:
                self.record()


def main():
    import argparse
    ap = argparse.ArgumentParser(
        description="A stand-in for an ESP32-C5 sniffer board, on a pseudo-terminal (POSIX only): it "
                    "speaks the firmware's line protocol and streams made-up Wi-Fi, 802.15.4 or BTLE "
                    "traffic, for trying Kismet and the helpers without hardware. Run it as the user "
                    "that Kismet or the helper runs as (with sudo for a Kismet started with sudo): "
                    "the port belongs to whoever starts this, and kismet_cap_esp32c5 does not "
                    "override file permissions, even when root starts it.",
        epilog="Example: python3 tools/fake_board.py /tmp/esp32c5-fake, then "
               "kismet -c esp32c5:device=/tmp/esp32c5-fake,mode=wifi. N counts from the last START "
               "answered. Stop it with Ctrl+C.")
    ap.add_argument("path", help="where to put the port, a link to the new /dev/pts/N (whatever is "
                                 "there is replaced), e.g. /tmp/esp32c5-fake")
    ap.add_argument("mode", nargs="?", default="WIFI",
                    help="radio to boot with: WIFI (the default), 802154 (or ZIGBEE, THREAD) or BLE "
                         "(or BT, BLUETOOTH), in any case; any other word boots Wi-Fi")
    ap.add_argument("--garble", type=int, default=0, metavar="N",
                    help="damage every Nth record, to test resynchronisation")
    ap.add_argument("--inject", type=int, default=0, metavar="N",
                    help="make every Nth record a frame whose payload holds the restart signature")
    ap.add_argument("--restart-every", type=int, default=0, metavar="N",
                    help="restart the stream in place every Nth record, as after a reset")
    ap.add_argument("--vanish", action="store_true",
                    help="on a change of radio (MODE), close the port and come back on a new "
                         "pseudo-terminal behind the same path two seconds later")
    ap.add_argument("--old-firmware", action="store_true",
                    help="send BTLE records without CRC flags and with a zeroed CRC, as older "
                         "firmware (esp32c5-wireshark-sniffer 1.2.0) does")
    args = ap.parse_args()
    mode = MODES.get(args.mode.upper(), ("wifi",))[0]
    try:
        FakeBoard(args.path, mode, args.garble, args.inject, args.restart_every, args.vanish,
                  args.old_firmware).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
