"""Offline tests for the Python remote helper's Kismet side (esp32c5_kismet/kismet_v3.py and remote.py): the
v3 protocol, byte for byte as capture_framework.c writes it (patched by kismet/add-to-kismet.sh, which leaves
an empty message out of a CONFIGREPORT), the UUIDs and hardware names the C helper gives, the source
definition contract, one board per source, a board another process holds (not offered, and left out of
--list), the 802.15.4 rewrap, the frequency of every packet (radiotap, TAP, BTLE), the BTLE CRC fix-up and
channel 37, channel hopping, a channel refused as the C helper refuses it, the board's statuses in the C
helper's words, opening a source, the reconnect loop, errors logged on one line each, the command line (the
login from the environment, where a login and an API key go -- the Authorization header, the KISMET cookie or
the address -- and a login Kismet takes neither way, localhost, the HTTP proxy in the environment, which is
never used for a loopback address, no_proxy read as curl reads it whatever websocket-client's version, a
missing websocket-client, stopping, exit status), a proxy's cookie
beside the key, a redirect, which is not followed, and where it points said as the C helper says it, a refused
login said by its status, a tunnel through an
HTTP proxy, and whole sessions against a fake Kismet server over TCP
and over a websocket, plain and (when openssl is there to make a certificate) with TLS, a board that never
captures and one unplugged while capturing among them.

No serial port, no Kismet needed: the boards a test sees are the ones it hands in. The packages in
requirements.txt are. Each check prints PASS or FAIL; the first FAIL exits with status 1, and a clean run
ends with ALL OK. Several cases make the helper log errors on purpose, so its log is hidden; TEST_DEBUG=1
shows it. More on the wiki page Development-and-Testing.

    python tests/test_kismet_v3.py
"""
import atexit
import base64
import contextlib
import hashlib
import io
import logging
import os
import queue
import random
import re
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import types

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import serial  # noqa: E402
from esp32c5_kismet import board as bd  # noqa: E402
from esp32c5_kismet import kismet_v3 as kv3  # noqa: E402
from esp32c5_kismet import remote  # noqa: E402

# Nothing below looks at the ports of the machine it runs on
bd.port_identity = lambda ser, port, platform=None: None
# The helper's own log only with TEST_DEBUG=1: several cases make it log errors on purpose
logging.basicConfig(level=logging.DEBUG if os.environ.get("TEST_DEBUG") else logging.CRITICAL,
                    format="%(asctime)s %(levelname)s: %(message)s")


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        sys.exit(1)


def raises(exc, fn, *args, **kw):
    try:
        fn(*args, **kw)
    except exc as e:
        return e
    return None


# ----------------------------------------------------------------------------------------------
# Frames: exact bytes, derived by hand from capture_framework.c
# ----------------------------------------------------------------------------------------------

# cf_send_pong(caph, 0x01020304): cf_prepare_packet(PONG, in_seqno, code 0), commit with final_len 0.
#   DECAFBAD  signature           A9A9  v3 sentinel       0003  version
#   00000000  length: no content, not even an empty map
#   0003      CMD_PONG            0000  code              01020304  the PING's seqno
check("PONG bytes", kv3.pong(0x01020304) == bytes.fromhex("DECAFBAD A9A9 0003 00000000 0003 0000 01020304"))

# cf_send_message(caph, "hi", MSG_INFO) with seqno 7:
#   82        mpack_build_map ... mpack_complete_map with two pairs: fixmap of 2
#   01 02     mpack_write_uint(MESSAGE_FIELD_TYPE), mpack_write_u8(2): positive fixints
#   02 a2 68 69  mpack_write_uint(MESSAGE_FIELD_STRING), mpack_write_str("hi", 2): fixstr of 2
#   7 bytes of content; header code 0
check("MESSAGE bytes", kv3.message(7, "hi") == bytes.fromhex(
    "DECAFBAD A9A9 0003 00000007 0005 0000 00000007" "82 01 02 02 a2 6869"))

# cf_send_data() for an 802.15.4 frame 41 88 heard on channel 15 at -60 dBm, ts 1700000000.000005, seqno 16:
#   82                    map of 2: signal block, packet block (no GPS block)
#   02 83                 DATAREPORT_FIELD_SIGNALBLOCK: map of 3, in the C's order channel, dbm, freq
#     07 a2 3135          SIGNAL_FIELD_CHANNEL "15"
#     01 ce ffffffc4      SIGNAL_FIELD_SIGNAL_DBM: mpack_write_u32((uint32_t) -60) = 0xFFFFFFC4, a u32
#     05 ce 002500a8      SIGNAL_FIELD_FREQ_KHZ: mpack_write_u64(2425000) takes the smallest form, a u32
#   04 85                 DATAREPORT_FIELD_PACKETBLOCK: map of 5
#     01 cc e6            PACKET_FIELD_DLT 230, which needs a u8
#     02 ce 6553f100      PACKET_FIELD_TS_S 1700000000
#     03 05               PACKET_FIELD_TS_US 5
#     04 02               PACKET_FIELD_LENGTH 2
#     06 c4 02 4188       PACKET_FIELD_CONTENT: mpack_write_bin, bin8 of 2
#   39 (0x27) bytes of content; header KDS_PACKET 0x10, code 0, seqno 0x10
DATA = bytes.fromhex(
    "DECAFBAD A9A9 0003 00000027 0010 0000 00000010"
    "82" "02 83" "07 a2 3135" "01 ce ffffffc4" "05 ce 002500a8"
    "04 85" "01 cc e6" "02 ce 6553f100" "03 05" "04 02" "06 c4 02 4188")
check("DATAREPORT bytes", kv3.datareport(16, 230, 1700000000, 5, 2, b"\x41\x88",
                                         channel="15", dbm=-60, freq_khz=2425000) == DATA)

# ----------------------------------------------------------------------------------------------
# Frames: round trips and types
# ----------------------------------------------------------------------------------------------

check("MESSAGE round trip", kv3.decode(kv3.message(9, "board capturing")) ==
      kv3.Frame(kv3.CMD_MESSAGE, 0, 9, {1: kv3.MSG_INFO, 2: "board capturing"}))
check("ERROR round trip, code 1", kv3.decode(kv3.error(0, "gone")) == kv3.Frame(kv3.CMD_ERROR, 1, 0, {1: "gone"}))
check("SHUTDOWN round trip", kv3.decode(kv3.shutdown(3, "why")) == kv3.Frame(kv3.CMD_SHUTDOWN, 0, 3, {1: "why"}))
fr = kv3.decode(kv3.newsource(2, "esp32c5-COM14:mode=wifi", "esp32c5", "E5C50001-0000-0000-0000-744DBDA1B2C3"))
check("NEWSOURCE round trip", fr.pkt_type == kv3.KDS_NEWSOURCE and
      fr.fields == {1: "esp32c5-COM14:mode=wifi", 2: "esp32c5", 3: "E5C50001-0000-0000-0000-744DBDA1B2C3"})

hop = {"channels": ["1", "6"], "rate": 5.3, "shuffle": True, "offset": 2, "skip": 4}
raw = kv3.openreport(12, True, "", 127, "v", "U", "COM14", "ESP32-C5", "6", ["1", "6"], hop=hop)
fr = kv3.decode(raw)
check("OPENREPORT round trip in the C's field order",
      fr.code == 1 and fr.seqno == 12 and list(fr.fields) == [9, 1, 2, 10, 8, 3, 7, 5, 4, 6] and
      fr.fields[4] == ["1", "6"] and fr.fields[5] == "6" and fr.fields[2] == 127 and fr.fields[1] == 12)
check("hop rate is a float32, as mpack_write_float writes it",
      b"\xca" + struct.pack(">f", 5.3) in raw and abs(fr.fields[6][1] - 5.3) < 1e-6)
check("open report says enabled with a bool", fr.fields[6][6] is True and list(fr.fields[6]) == [5, 1, 2, 4, 3, 6])
fr = kv3.decode(kv3.openreport(12, True, "", 127, "v", "U", "COM14", "ESP32-C5", "36", ["36"]))
check("an open report of a hopping source has no hop block, as the C framework's at open", 6 not in fr.fields)
fr = kv3.decode(kv3.openreport(12, True, "", 127, "v", "U", "COM14", "ESP32-C5", "36", ["36"], hopping=False))
check("channel_hop=false: a hop block without a rate, which is how Kismet hears 'not hopping'",
      fr.fields[6] == {6: False} and 1 not in fr.fields[6])
fr = kv3.decode(kv3.configreport(21, True, None, hop=hop))
check("config report says enabled with an integer 1, as cf_send_configresp does",
      type(fr.fields[3][6]) is int and fr.fields[3][6] == 1 and 4 not in fr.fields and fr.fields[1] == 21)
fr = kv3.decode(kv3.configreport(22, False, "no", channel="6"))
check("failed config report", fr.code == 0 and fr.fields == {4: "no", 1: 22, 2: "6"})
fr = kv3.decode(kv3.probereport(5, True, "", "COM14", "ESP32-C5", "6", ["6"]))
check("PROBEREPORT round trip", fr.code == 1 and fr.fields == {3: "", 1: 5, 2: {4: "COM14", 3: "ESP32-C5", 5: "6", 6: ["6"]}})
fr = kv3.decode(kv3.datareport(1, 127, 10, 20, 300, b"abc"))
check("wifi data report has no signal block", list(fr.fields) == [4] and fr.fields[4][6] == b"abc" and fr.fields[4][4] == 300)

# The negative dBm: unsigned two's complement, never a msgpack negative integer
fr = kv3.decode(kv3.datareport(1, 230, 0, 0, 2, b"xy", channel="11", dbm=-60))
raw = kv3.datareport(1, 230, 0, 0, 2, b"xy", channel="11", dbm=-60)
check("-60 dBm goes as u32 0xFFFFFFC4", fr.fields[2][1] == 0xFFFFFFC4 and b"\x01\xce\xff\xff\xff\xc4" in raw)
check("-1 dBm goes as 0xFFFFFFFF", kv3.decode(kv3.datareport(1, 230, 0, 0, 1, b"x", dbm=-1)).fields[2][1] == 0xFFFFFFFF)
check("0 dBm is left out, as the C does", 1 not in kv3.decode(kv3.datareport(1, 230, 0, 0, 1, b"x", channel="11", dbm=0)).fields[2])

# Stream cutting: the legacy TCP protocol
frames = [kv3.pong(1), kv3.message(2, "x" * 300), DATA, kv3.error(0, None)]
stream, buf, got = b"".join(frames), bytearray(), []
for i in range(len(stream)):
    buf += stream[i:i + 1]
    fr, used = kv3.take_frame(buf)
    if fr is not None:
        del buf[:used]
        got.append(fr)
check("frames cut from a byte-at-a-time stream", got == [kv3.decode(f) for f in frames] and not buf)
v2ping = struct.pack("!IHHI32sI", 0xDECAFBAD, 0xABCD, 2, 0, b"PING", 77)
check("legacy v2 PING is read as a PING", kv3.decode(v2ping) == kv3.Frame(kv3.CMD_PING, 0, 77, {}))
check("bad signature refused", raises(kv3.ProtocolError, kv3.decode, b"\x00" * 16) is not None)
check("truncated message refused", raises(kv3.ProtocolError, kv3.decode, DATA[:-1]) is not None)
check("garbage content refused", raises(kv3.ProtocolError, kv3.decode,
                                        kv3.HEADER.pack(0xDECAFBAD, 0xA9A9, 3, 2, 5, 0, 1) + b"\xc1\xc1") is not None)

# What Kismet sends (kis_datasource.cc send_configure_channel_hop_v3 / send_configure_channel_v3)
def configreq(fields):
    return kv3.decode(kv3.frame(kv3.KDS_CONFIGREQ, 9, 1, fields))


def openreq(definition, seqno=9):
    return kv3.decode(kv3.frame(kv3.KDS_OPENREQ, seqno, 1, {1: definition}))


check("config request: channel", kv3.parse_configreq(configreq({1: "6"})) == ("channel", "6"))
check("config request: a channel wins over a hop block",
      kv3.parse_configreq(configreq({1: "6", 2: {5: ["1"]}})) == ("channel", "6"))
kind, h = kv3.parse_configreq(configreq({2: {1: 5.0, 2: True, 4: 3, 5: ["1", "6", "11"]}}))
check("config request: hop block as Kismet sends it", kind == "hop" and h == kv3.HopRequest(["1", "6", "11"], 5.0, True, None, 3))
check("config request: neither", kv3.parse_configreq(configreq({})) is None)
check("config request: hop block without a list is refused",
      raises(kv3.ProtocolError, kv3.parse_configreq, configreq({2: {1: 5.0}})) is not None)

# ----------------------------------------------------------------------------------------------
# UUIDs
# ----------------------------------------------------------------------------------------------

# Published 64-bit FNV-1a vectors: "" = cbf29ce484222325, "a" = af63dc4c8601ec8c, "foobar" = 85944171f73967e8
check("FNV-1a 48: empty", remote.fnv1a48("") == "9CE484222325")
check("FNV-1a 48: a", remote.fnv1a48("a") == "DC4C8601EC8C")
check("FNV-1a 48: foobar", remote.fnv1a48("foobar") == "4171F73967E8")
check("uuid from the MAC", remote.default_uuid("wifi", "74:4D:BD:A1:B2:C3", "COM14") == "E5C50001-0000-0000-0000-744DBDA1B2C3")
check("uuid digit per mode", remote.default_uuid("zigbee", "74:4d:bd:a1:b2:c3", "x")[:9] == "E5C50002-" and
      remote.default_uuid("btle", "74:4D:BD:A1:B2:C3", "x") == "E5C50003-0000-0000-0000-744DBDA1B2C3")
check("uuid without a MAC hashes the device", remote.default_uuid("wifi", None, "foobar") == "E5C50001-0000-0000-0000-4171F73967E8")
# What make_uuid() and make_hardware() in capture_esp32c5.c print for the same boards, compiled as they are
# (see tests/c): the same board and radio is the same source to Kismet whichever helper offers it
C_UUIDS = {("wifi", "38:44:BE:BF:C9:10", "/dev/ttyACM0"): "E5C50001-0000-0000-0000-3844BEBFC910",
           ("zigbee", "38:44:BE:BF:C9:10", "/dev/ttyACM0"): "E5C50002-0000-0000-0000-3844BEBFC910",
           ("btle", "38:44:BE:BF:C9:10", "/dev/ttyACM0"): "E5C50003-0000-0000-0000-3844BEBFC910",
           ("wifi", None, "/dev/ttyACM0"): "E5C50001-0000-0000-0000-931F359CC900",
           ("zigbee", None, "/tmp/esp32c5-fake"): "E5C50002-0000-0000-0000-FE426C0080DD",
           ("btle", None, "/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:C9:10-if00"):
               "E5C50003-0000-0000-0000-D218E6676F22",
           ("wifi", None, "COM14"): "E5C50001-0000-0000-0000-22E7F16626CB"}
check("uuids as the C helper makes them", all(remote.default_uuid(*k) == v for k, v in C_UUIDS.items()))
check("hardware as the C helper names it", remote.hardware_name("38:44:BE:BF:C9:10") ==
      "Espressif USB-Serial-JTAG (38:44:BE:BF:C9:10)" and remote.hardware_name(None) == "ESP32-C5")


# ----------------------------------------------------------------------------------------------
# Definitions
# ----------------------------------------------------------------------------------------------

class Port:
    def __init__(self, device, serial_number=None):
        self.device, self.serial_number = device, serial_number
        self.vid, self.pid = bd.ESPRESSIF_USB_JTAG


ONE = [Port("COM14", "74:4D:BD:A1:B2:C3")]
TWO = ONE + [Port("COM15", "74:4D:BD:A1:B2:C4")]
FOUR = [Port("COM%d" % n, "74:4D:BD:A1:B2:%02X" % n) for n in (13, 14, 15, 16)]


def parse(definition, boards=ONE, platform="win32", **kw):
    return remote.parse_definition(definition, boards, platform, **kw)


s = parse("esp32c5:device=COM14,mode=wifi")
check("explicit device", s.device == "COM14" and s.mode == "wifi" and s.dlt == 127 and
      s.uuid == "E5C50001-0000-0000-0000-744DBDA1B2C3" and s.hardware == "Espressif USB-Serial-JTAG (74:4D:BD:A1:B2:C3)")
check("wifi channels", s.channels == [str(c) for c in bd.all_channels("wifi")] and s.channels[:2] == ["1", "2"]
      and "14" in s.channels and "36" in s.channels and "177" in s.channels and "15" not in s.channels
      and "38" not in s.channels and s.initial_channel == 6 and s.hopping)
check("default mode is wifi", parse("esp32c5").mode == "wifi")
for alias in ("zigbee", "802154", "802.15.4", "thread", "ZigBee"):
    s = parse("esp32c5:mode=%s" % alias)
    check("mode %s is zigbee" % alias, s.mode == "zigbee" and s.board_mode == bd.MODE_154 and s.dlt == 230 and
          s.channels == [str(c) for c in range(11, 27)] and s.initial_channel == 15 and s.uuid[:9] == "E5C50002-")
for alias in ("btle", "ble", "bluetooth"):
    s = parse("esp32c5:mode=%s" % alias)
    check("mode %s is btle" % alias, s.mode == "btle" and s.dlt == 256 and s.channels == ["37"] and s.initial_channel == 37)
check("unknown mode", type(raises(remote.DefinitionError, parse, "esp32c5:mode=lora")) is remote.DefinitionError)
check("interface must start with esp32c5",
      type(raises(remote.DefinitionError, parse, "wlan0:device=COM14")) is remote.DefinitionError)
check("dwell out of range", raises(remote.DefinitionError, parse, "esp32c5:dwell=5") is not None)
check("dwell passes through", parse("esp32c5:dwell=100").dwell_ms == 100)
s = parse('esp32c5:name="lab, bench 2",MODE=btle,uuid=AAAAAAAA-0000-0000-0000-000000000001')
check("quoted value with a comma, case-insensitive key, uuid=", s.mode == "btle" and
      s.uuid == "AAAAAAAA-0000-0000-0000-000000000001" and s.name == "lab, bench 2")
check("quoted value is kept whole", remote.split_definition('esp32c5:name="a,b",mode=wifi')[1] == {"name": "a,b", "mode": "wifi"})

check("missing device, one board", parse("esp32c5:mode=wifi").device == "COM14")
e = raises(remote.BoardNotFound, parse, "esp32c5:mode=wifi", [])
check("missing device, no board: %s" % e, e is not None and "no Espressif USB-Serial-JTAG device (USB ID 303a:1001)" in str(e)
      and "ESP32-C5 board" not in str(e))
e = raises(remote.BoardNotFound, parse, "esp32c5:mode=wifi", TWO)
check("missing device, two boards: %s" % e, e is not None and "COM14, COM15" in str(e) and
      "2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found" in str(e) and "every ESP32 on native USB" in str(e))

s = parse("esp32c5-COM15:mode=zigbee", TWO)
check("interface names the port", s.device == "COM15" and s.uuid == "E5C50002-0000-0000-0000-744DBDA1B2C4")
s = parse("esp32c5-com7", TWO)
check("COM name is normalised to upper case; no MAC, so a hashed uuid",
      s.device == "COM7" and s.mac is None and s.uuid.endswith(remote.fnv1a48("COM7")) and s.hardware == "ESP32-C5")
check("explicit device= wins over the interface name", parse("esp32c5-COM14:device=COM15", TWO).device == "COM15")
check("a name that is not a port falls back to the only board", parse("esp32c5-kitchen").device == "COM14")
check("tty names mean nothing on Windows", parse("esp32c5-ttyACM0").device == "COM14")
check("COM names mean nothing on Linux", parse("esp32c5-COM3", [Port("/dev/ttyACM1")], "linux").device == "/dev/ttyACM1")
check("ttyACM0 on Linux", remote.device_from_interface("esp32c5-ttyACM0", "linux") == "/dev/ttyACM0")
check("ttyUSB0 on Linux", remote.device_from_interface("esp32c5-ttyUSB0", "linux") == "/dev/ttyUSB0")
check("cu.usbmodem1101 on macOS", remote.device_from_interface("esp32c5-cu.usbmodem1101", "darwin") == "/dev/cu.usbmodem1101")
check("plain esp32c5 names no port", remote.device_from_interface("esp32c5", "linux") is None)

# The radio in the name, as kismet_cap_esp32c5 reads it (tests/c/test_parser.c test_definitions)
for definition, platform, mode, device in (
        ("esp32c5-COM32", "win32", "wifi", "COM32"),
        ("esp32c5zigbee-COM32", "win32", "zigbee", "COM32"),
        ("esp32c5btle-COM32", "win32", "btle", "COM32"),
        ("esp32c5zigbee-com32:mode=wifi", "win32", "wifi", "COM32"),
        ("esp32c5-ttyACM0", "linux", "wifi", "/dev/ttyACM0"),
        ("esp32c5zigbee-ttyACM0", "linux", "zigbee", "/dev/ttyACM0"),
        ("esp32c5btle-ttyACM0", "linux", "btle", "/dev/ttyACM0"),
        ("esp32c5-ttyACM0:mode=btle", "linux", "btle", "/dev/ttyACM0"),
        ("esp32c5ble-ttyUSB1", "linux", "btle", "/dev/ttyUSB1"),
        ("esp32c5thread-ttyACM2", "linux", "zigbee", "/dev/ttyACM2"),
        ("esp32c5802154-ttyACM2", "linux", "zigbee", "/dev/ttyACM2"),
        ("esp32c5Bluetooth-cu.usbmodem1101", "darwin", "btle", "/dev/cu.usbmodem1101"),
        ("esp32c5-kitchen:device=/dev/ttyACM3", "linux", "wifi", "/dev/ttyACM3"),
        ("esp32c5btle:device=/dev/ttyACM3", "linux", "btle", "/dev/ttyACM3"),
        ("esp32c5kitchen", "win32", "wifi", "COM14"),
        ("esp32c5zigbee", "win32", "zigbee", "COM14")):
    s = parse(definition, ONE, platform)
    check("%s is %s on %s" % (definition, mode, device), s.mode == mode and s.device == device)
check("mode= that names no radio is refused, name or not",
      raises(remote.DefinitionError, parse, "esp32c5zigbee-COM32:mode=lte") is not None)
# Only the names serial ports have count, as written, whether or not they are there (serial_name() in the C
# helper; tests/c/test_parser.c test_definitions). Whatever else /dev holds is never a port.
for definition, device in (("esp32c5-cuaU0", "/dev/cuaU0"), ("esp32c5zigbee-dtyU0", "/dev/dtyU0"),
                           ("esp32c5-pts/7", "/dev/pts/7"), ("esp32c5-pts/77", "/dev/pts/77"),
                           ("esp32c5btle-tty.usbmodem1101", "/dev/tty.usbmodem1101")):
    check("%s is the port %s, there or not" % (definition, device),
          remote.device_from_interface(definition, "linux") == device)
for definition in ("esp32c5zigbee-null", "esp32c5-null", "esp32c5-serial1", "esp32c5-watchdog", "esp32c5-kmsg",
                   "esp32c5-random", "esp32c5-pts/../watchdog", "esp32c5-tty/../null", "esp32c5-ttyACM0/../../x"):
    check("%s names no port, whatever /dev holds by that name" % definition,
          remote.device_from_interface(definition, "linux") is None)
check("... so esp32c5zigbee-null is the only board, never /dev/null",
      parse("esp32c5zigbee-null", [Port("/dev/ttyACM0", "38:44:BE:BF:C9:10")], "linux").device == "/dev/ttyACM0")
e = raises(remote.BoardNotFound, parse, "esp32c5zigbee-pts/77", [Port("/dev/ttyACM0", "38:44:BE:BF:C9:10")], "linux",
           exists=lambda d: False)
check("a named pseudo-terminal that is not there is waited for, not swapped for the only board: %s" % e,
      e is not None and "/dev/pts/77" in str(e))
check("--list line on Windows", remote.short_definition("COM14", "wifi", "win32") == "esp32c5-COM14")
check("--list lines for the other radios", remote.short_definition("COM14", "zigbee", "win32") == "esp32c5zigbee-COM14"
      and remote.short_definition("COM14", "btle", "win32") == "esp32c5btle-COM14")
check("--list line on Linux", remote.short_definition("/dev/ttyACM0", "zigbee", "linux") == "esp32c5zigbee-ttyACM0")
check("--list line for an odd port", remote.short_definition("/dev/serial/by-id/usb-Espressif-if00", "btle", "linux") ==
      "esp32c5:device=/dev/serial/by-id/usb-Espressif-if00,mode=btle")
for mode in ("wifi", "zigbee", "btle"):
    s = parse(remote.short_definition("COM15", mode, "win32"), TWO)
    check("the --list line for %s opens that radio on that port" % mode, s.mode == mode and s.device == "COM15")
def list_out(platform="win32"):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = remote.list_boards(platform)
    return code, out.getvalue()


bd.find_boards = lambda: TWO
code, out = list_out()
check("--list prints the three names of each board", "--source esp32c5zigbee-COM15" in out and
      "--source esp32c5btle-COM14" in out and ":mode=" not in out and "Left out" not in out and code == 0)
# A board whose port another process holds is left out, all three of its names, as the C helper's --list
# leaves it out (on Linux, where /proc/locks tells; board.port_locked says no elsewhere)
real_port_locked = bd.port_locked
asked = []
bd.port_locked = lambda device, platform=None: asked.append((device, platform)) or device == "COM15"
try:
    code, out = list_out()
    check("--list leaves out a board in use, all three names, and says so (%s)" % out.splitlines()[-2:],
          "esp32c5-COM14" in out and "COM15" not in out.replace("in use by another capture: COM15", "") and
          "Left out, in use by another capture: COM15" in out and code == 0 and ("COM14", "win32") in asked)
    bd.port_locked = lambda device, platform=None: True
    code, out = list_out()
    check("--list with every board in use lists none, exit status 1 (%s)" % out.strip(),
          "--source" not in out and "Left out, in use by another capture: COM14, COM15" in out and code == 1)
finally:
    bd.port_locked = real_port_locked
check("the real check knows nothing on Windows: it would have to open the port",
      not bd.port_locked("COM14", "win32"))
bd.find_boards = lambda: []
code, out = list_out()
check("--list with nothing plugged in", "No Espressif USB-Serial-JTAG device (USB ID 303a:1001) found" in out and
      code == 1)

# channel=: where to start, and with channel_hop=false where to stay; checked before any port is
s = parse("esp32c5-COM14:channel=36,channel_hop=false")
check("channel=36 starts on 36, channel_hop=false", s.initial_channel == 36 and not s.hopping)
check("channel_hop as Kismet reads it: false and f, in any case",
      not parse("esp32c5-COM14:channel_hop=F").hopping and parse("esp32c5-COM14:channel_hop=no").hopping)
check("zigbee channel=25", parse("esp32c5zigbee-COM14:channel=25").initial_channel == 25)
check("btle channel=38 stays on 37", parse("esp32c5btle-COM14:channel=38").initial_channel == 37)
check("channel=0177 is 177, as strtoul reads it", parse("esp32c5-COM14:channel=0177").initial_channel == 177)
for bad in ("esp32c5-COM14:channel=15", "esp32c5-COM14:channel=abc", "esp32c5-COM14:channel=+6",
            "esp32c5-COM14:channel=6.0", "esp32c5-COM14:channel=-6", "esp32c5-COM14:channel=181",
            "esp32c5zigbee-COM14:channel=27", "esp32c5btle-COM14:channel=6", "esp32c5btle-COM14:channel=40"):
    e = raises(remote.DefinitionError, parse, bad)
    check("%s refused: %s" % (bad, e), type(e) is remote.DefinitionError and "not a channel the board can tune to" in str(e))
e = raises(remote.DefinitionError, parse, "esp32c5-COM99:channel=15", ONE, "win32", exists=lambda d: False)
check("channel= is checked before the port is looked for", type(e) is remote.DefinitionError and "channel=15" in str(e))

# The definition Kismet sends back in OPENREQ is its own rewrite: keys sorted, quotes gone
check("an unquoted list continues its option, as Kismet sends it back",
      remote.split_definition("esp32c5-ttyACM1:channels=11,15,20,25,mode=zigbee") ==
      ("esp32c5-ttyACM1", {"channels": "11,15,20,25", "mode": "zigbee"}))
check("the quoted and the rewritten form read the same",
      remote.split_definition('esp32c5-COM14:mode=zigbee,channels="11,15,20,25",name="lab, bench 2"') ==
      remote.split_definition("esp32c5-COM14:channels=11,15,20,25,mode=zigbee,name=lab, bench 2"))
check("quotes anywhere in a value are dropped, as string_to_opts does",
      remote.split_definition('esp32c5:name=a"b,c"d')[1] == {"name": "ab,cd"})
check("an unterminated quote runs to the end, as in Kismet", remote.split_definition('esp32c5:name="a,b')[1] == {"name": "a,b"})
check("a trailing comma is nothing", remote.split_definition("esp32c5:mode=btle,")[1] == {"mode": "btle"})
check("the first of a repeated key wins", remote.split_definition("esp32c5:mode=wifi,MODE=zigbee")[1] == {"mode": "wifi"})
check("... and what continues the repeat is not added anywhere",
      remote.split_definition("esp32c5:mode=wifi,mode=zigbee,x,dwell=100")[1] == {"mode": "wifi", "dwell": "100"})
check("same_definition sees through the rewrite",
      remote.same_definition('esp32c5:device=COM16,mode=zigbee,channels="11,15"',
                             "esp32c5:channels=11,15,device=COM16,mode=zigbee") and
      not remote.same_definition("esp32c5:mode=zigbee", "esp32c5:mode=wifi") and
      not remote.same_definition("esp32c5-COM14", "esp32c5-COM15") and
      not remote.same_definition("esp32c5-COM14:channel=6", "esp32c5-COM14:channel=11"))
# An unquoted list: Kismet reads channels=1,6,11,mode=zigbee as channels=1 and an option "6,11,mode" (util.cc
# string_to_opts), and its rewrite, keys sorted, is 6,11,mode=zigbee,channels=1. cf_find_flag() passes over
# the 6 and the 11, and so does the helper.
REWRITE = "esp32c5-COM14:6,11,mode=zigbee,channels=1"
check("pieces without a value before the first option are passed over, as cf_find_flag does",
      remote.split_definition(REWRITE) == ("esp32c5-COM14", {"mode": "zigbee", "channels": "1"}) and
      remote.split_definition("esp32c5:foo")[1] == {})
s = parse(REWRITE)
check("Kismet's rewrite of an unquoted list is 802.15.4 on COM14", s.mode == "zigbee" and s.device == "COM14" and
      s.uuid == "E5C50002-0000-0000-0000-744DBDA1B2C3")
check("... and the same source as the definition it came from, which only Kismet's channels= tells apart",
      remote.same_definition(REWRITE, "esp32c5-COM14:channels=1,6,11,mode=zigbee"))
s = parse("esp32c5:channels=11,15,device=COM16,mode=zigbee", FOUR)
check("the rewrite of a device= definition on a four-board setup keeps its device and radio",
      s.device == "COM16" and s.mode == "zigbee" and s.uuid == "E5C50002-0000-0000-0000-744DBDA1B210")
s = parse("esp32c5-COM14:channels=1,6,11")
check("the rewrite of a quoted channel list is no error", s.device == "COM14" and s.mode == "wifi")

# One spelling per port, and a board known by its MAC however its port is written
s = parse("esp32c5:device=\\\\.\\COM14")
check("\\\\.\\COM14 is COM14, with the board's MAC", s.device == "COM14" and s.mac == "74:4D:BD:A1:B2:C3" and
      s.uuid == "E5C50001-0000-0000-0000-744DBDA1B2C3")
s = parse("esp32c5:device=com14,mode=btle")
check("device=com14 is COM14, with the board's MAC", s.device == "COM14" and s.uuid == "E5C50003-0000-0000-0000-744DBDA1B2C3")
real_realpath = os.path.realpath
BY_ID = "/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:C9:10-if00"
os.path.realpath = lambda p, *a, **kw: "/dev/ttyACM3" if p == BY_ID else p
try:
    s = parse("esp32c5:device=%s,mode=zigbee" % BY_ID, [Port("/dev/ttyACM3", "38:44:BE:BF:C9:10")], "linux")
    check("a /dev/serial/by-id link gets the board's MAC, as board_mac() in the C helper finds it",
          s.device == BY_ID and s.mac == "38:44:BE:BF:C9:10" and s.uuid == "E5C50002-0000-0000-0000-3844BEBFC910"
          and s.hardware == "Espressif USB-Serial-JTAG (38:44:BE:BF:C9:10)" and s.key == "/dev/ttyACM3")
    s = parse("esp32c5:device=%s,mode=btle" % BY_ID, [], "linux")
    check("... and without its board, the C helper's hashed uuid of the path as given",
          s.uuid == C_UUIDS[("btle", None, BY_ID)])
finally:
    os.path.realpath = real_realpath
tmp = tempfile.mkdtemp()
atexit.register(shutil.rmtree, tmp, True)  # with whatever the checks below leave in it
try:
    os.symlink(os.path.join(tmp, "ttyACM3"), os.path.join(tmp, "by-id-link"))
    s = parse("esp32c5:device=%s" % os.path.join(tmp, "by-id-link"), [Port(os.path.join(tmp, "ttyACM3"), "38:44:BE:BF:C9:10")],
              "linux")
    check("... and through a real symbolic link", s.mac == "38:44:BE:BF:C9:10")
except (OSError, NotImplementedError):
    print("SKIP a real symbolic link (no permission to make one here)")

# A port that is named but not there is waited for, never offered under a made-up identity
e = raises(remote.BoardNotFound, parse, "esp32c5-COM30", ONE, "win32", exists=lambda d: False)
check("a named port that is not there: BoardNotFound (%s)" % e, e is not None and "COM30" in str(e))
check("... unless uuid= says who it is", parse("esp32c5-COM30:uuid=AAAAAAAA-0000-0000-0000-000000000001", ONE, "win32",
                                               exists=lambda d: False).device == "COM30")
asked = []
parse("esp32c5:device=\\\\.\\com30", ONE, "win32", exists=lambda d: asked.append(d) or True)
check("the port is looked for in the spelling it is opened by", asked == ["COM30"])
check("a board list handed in means no port of this machine is looked at", parse("esp32c5-COM30", ONE).device == "COM30")

# ----------------------------------------------------------------------------------------------
# One board, one source
# ----------------------------------------------------------------------------------------------

def refused(definitions, boards=ONE, platform="win32", exists=None):
    return raises(remote.DefinitionError, remote.check_sources, definitions, boards, platform, exists)


e = refused(["esp32c5-COM32:mode=wifi", "esp32c5:device=com32,mode=zigbee"], [Port("COM32", "38:44:BE:BF:C9:10")])
check("com32 and COM32 are one port: %s" % e, e is not None and "both want COM32" in str(e))
check("so are \\\\.\\COM32 and COM32",
      refused(["esp32c5-COM32:mode=wifi", "esp32c5:device=\\\\.\\COM32,mode=zigbee"], []) is not None)
check("... also when the board is not there", refused(["esp32c5-COM32", "esp32c5zigbee-com32"], [],
                                                      exists=lambda d: False) is not None)
check("the same board by name and as the only one", refused(["esp32c5-COM14", "esp32c5:mode=zigbee"]) is not None)
for boards in ([], ONE, TWO):
    e = refused(["esp32c5:mode=wifi", "esp32c5zigbee"], boards)
    check("two definitions that name no port are refused with %d boards: %s" % (len(boards), e),
          e is not None and "name no port" in str(e))
check("different ports are fine", refused(["esp32c5-COM14", "esp32c5zigbee-COM15"], TWO) is None)
check("a wrong definition is refused as it is", "mode=lte" in str(refused(["esp32c5:mode=lte"])))
check("two pseudo-terminals are two named ports, there or not",
      refused(["esp32c5-pts/77", "esp32c5zigbee-pts/78"], [], "linux") is None)
check("... and two that name no port are still refused",
      "name no port" in str(refused(["esp32c5-null", "esp32c5zigbee-serial1"], [], "linux")))


class Captured(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.said = []

    def emit(self, record):
        self.said.append(record.getMessage())


@contextlib.contextmanager
def helper_log(level=logging.WARNING):
    """What the helper logs at this level and above, kept from the console."""
    logger, h = logging.getLogger("esp32c5_kismet.remote"), Captured()
    saved = logger.level, logger.propagate
    logger.addHandler(h)
    logger.setLevel(level)
    logger.propagate = False
    try:
        yield h.said
    finally:
        logger.removeHandler(h)
        logger.setLevel(saved[0])
        logger.propagate = saved[1]


# Where the user hears of a definition Kismet will read otherwise than meant
for bad in ("esp32c5:foo", "esp32c5-COM14:zigbee,channel=20", "esp32c5-COM14:,mode=zigbee"):
    e = refused([bad])
    check("%s: a piece with no value before the first option is refused at startup: %s" % (bad, e),
          e is not None and "has no value" in str(e))
with helper_log() as said:
    e = refused(["esp32c5-COM14:channels=1,6,11,mode=zigbee"])
check("an unquoted list is taken, as the C helper takes it, with a warning: %s" % said,
      e is None and len(said) == 1 and "channels= is not in double quotes" in said[0] and 'channels="1,6,11"' in said[0])
with helper_log() as said:
    e = refused(['esp32c5-COM14:channels="1,6,11",mode=zigbee'])
check("a quoted one without", e is None and said == [])
# A board that is not there yet is a warning at startup, which says once that the helper goes on looking
with helper_log() as said:
    e = refused(["esp32c5-COM30", "esp32c5zigbee"], [], exists=lambda d: False)
check("a missing board at startup: warned, saying once that it is waited for (%s)" % said,
      e is None and said == ["esp32c5-COM30: COM30 is not there; is the board plugged in? (waiting for it)",
                             "esp32c5zigbee: no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the "
                             "board in, or give device= in the source definition (will keep looking)"])
os.path.realpath = lambda p, *a, **kw: "/dev/ttyACM3" if p == BY_ID else p
try:
    check("a by-id link and its ttyACM are one port",
          refused(["esp32c5-ttyACM3", "esp32c5:device=%s,mode=btle" % BY_ID], [Port("/dev/ttyACM3", "38:44:BE:BF:C9:10")],
                  "linux") is not None)
finally:
    os.path.realpath = real_realpath

# A claim holds for the whole run: whoever resolves to a claimed port later is refused
boards_now = [ONE]


def parse_now(definition, **kw):
    return remote.parse_definition(definition, boards_now[0], "win32", exists=lambda d: True, **kw)


claims = remote.PortClaims()
rs_a = remote.RemoteSource("esp32c5-COM14:mode=wifi", None, parse_now, claims)
rs_b = remote.RemoteSource("esp32c5:mode=zigbee", None, parse_now, claims)
check("the first source takes COM14", rs_a.resolve().device == "COM14")
e = raises(remote.PortTaken, rs_b.resolve)
check("a later one that resolves to it is refused: %s" % e, e is not None and "esp32c5-COM14:mode=wifi" in str(e))
check("... and stays refused (the claim is not given up)", raises(remote.PortTaken, rs_b.resolve) is not None and
      rs_a.resolve().device == "COM14")

# A definition that names no port keeps to its board, by its MAC
claims = remote.PortClaims()
rs = remote.RemoteSource("esp32c5:mode=zigbee", None, parse_now, claims)
first = rs.resolve()
boards_now[0] = [Port("COM13", "74:4D:BD:A1:B2:0D"), Port("COM16", "74:4D:BD:A1:B2:C3")]
again = rs.resolve()
check("a port-less source follows its board to COM16 though two are plugged in now",
      first.device == "COM14" and again.device == "COM16" and again.uuid == first.uuid)
check("... and lets COM14 go", claims.claim(bd.port_key("COM14", "win32"), "another") == "another")
boards_now[0] = [Port("COM13", "74:4D:BD:A1:B2:0D")]
e = raises(remote.BoardNotFound, rs.resolve)
check("... and waits for it, not for 'one board', when it is gone: %s" % e, e is not None and "74:4D:BD:A1:B2:C3" in str(e))

# A named port whose board cannot be identified for a moment keeps its identity
boards_now[0] = ONE
rs = remote.RemoteSource("esp32c5-COM14", None, parse_now, remote.PortClaims())
first = rs.resolve()
boards_now[0] = []
again = rs.resolve()
check("a named port keeps the identity it had while its board is not listed",
      again.uuid == first.uuid and again.hardware == first.hardware and again.mac == "74:4D:BD:A1:B2:C3")
boards_now[0] = [Port("COM14", "74:4D:BD:A1:B2:FF")]
check("... but another board on it is another source", rs.resolve().uuid == "E5C50001-0000-0000-0000-744DBDA1B2FF")
boards_now[0] = ONE

# ----------------------------------------------------------------------------------------------
# 802.15.4 TAP rewrap
# ----------------------------------------------------------------------------------------------


def tap_header(channel=20, rss=-61.0, lqi=200, sof_ns=123456789000):
    # tap154_hdr_t (firmware/main/esp32c5_sniffer.c line 149) as fill_tap154() fills it
    return struct.pack("<BBH" "HHB3x" "HHf" "HHHBx" "HHB3x" "HHQ",
                       0, 0, 48,
                       0, 1, 0,          # FCS type: none
                       1, 4, rss,        # RSS, dBm
                       3, 3, channel, 0,  # channel assignment: channel, page 0
                       10, 1, lqi,       # LQI
                       5, 8, sof_ns)     # start of frame timestamp


MAC = bytes.fromhex("4188 01 3412 ffff 0000 09 12 0102")
check("the firmware's TAP header is 48 bytes", len(tap_header()) == 48)
check("rewrap the firmware's header", remote.rewrap_tap(tap_header() + MAC) == (MAC, 20, -61.0, 48))
short = struct.pack("<BBHHHfHHHBx", 0, 0, 20, 1, 4, -70.5, 3, 3, 11, 0)
check("rewrap reads the header's own length", remote.rewrap_tap(short + MAC) == (MAC, 11, -70.5, 20))
check("no RSS TLV is not an error", remote.rewrap_tap(struct.pack("<BBHHHHBx", 0, 0, 12, 3, 3, 26, 0) + MAC) == (MAC, 26, None, 12))
bad = []
bad.append(tap_header()[:40])                     # truncated inside the header
bad.append(tap_header())                          # a header and no frame
bad.append(b"\x01" + tap_header()[1:] + MAC)      # version 1
b = bytearray(tap_header() + MAC); struct.pack_into("<H", b, 2, 46); bad.append(bytes(b))   # length not whole words
b = bytearray(tap_header() + MAC); struct.pack_into("<H", b, 22, 40); bad.append(bytes(b))  # channel TLV runs past the header
b = bytearray(tap_header() + MAC); struct.pack_into("<H", b, 14, 2); bad.append(bytes(b))   # RSS TLV of the wrong size
bad.append(tap_header(channel=5) + MAC)           # not a 2.4 GHz channel
bad.append(tap_header(rss=float("nan")) + MAC)    # no real RSS
bad.append(short[:12] + b"\x00" * 8 + MAC)        # no channel TLV at all
bad.append(b"\x00\x00")
for i, rec in enumerate(bad):
    check("malformed TAP header %d is dropped" % i, remote.rewrap_tap(rec) is None)
random.seed(3)
for _ in range(20000):
    rec = bytes(random.getrandbits(8) for _ in range(random.randint(0, 80)))
    got = remote.rewrap_tap(rec)
    if got is not None and not (11 <= got[1] <= 26 and got[0] == rec[got[3]:] and got[0]):
        check("random garbage", False)
check("random garbage never crashes and never yields nonsense", True)
check("frequency of channel 11 and 26", remote.zigbee_freq_khz(11) == 2405000 and remote.zigbee_freq_khz(26) == 2480000)
check("RSS rounds half away from zero, like C", remote.c_round(-60.5) == -61 and remote.c_round(-60.4) == -60 and
      remote.c_round(2.5) == 3)

# ----------------------------------------------------------------------------------------------
# Wi-Fi: the frequency in the radiotap header
# ----------------------------------------------------------------------------------------------


def radiotap(freq, flags=0x00A0, tsft=False, rate=False, ext=0):
    """A radiotap header with a Channel field: the firmware's (Flags, Channel, antenna signal and noise), or
    one with TSFT, Rate or ext more presence words in front of it, each but the last with bit 31 set."""
    present = (1 << 1) | (1 << 3) | (1 << 5) | (1 << 6) | (1 if tsft else 0) | (4 if rate else 0)
    words = struct.pack("<I", present | (1 << 31 if ext else 0))
    words += b"".join(struct.pack("<I", 1 << 31 if k < ext - 1 else 0) for k in range(ext))
    body = bytearray()
    pos = 4 + len(words)
    if tsft:
        body += bytes(-pos % 8) + struct.pack("<Q", 123456789)
    body += b"\x00"  # flags
    if rate:
        body += b"\x02"
    body += bytes((pos + len(body)) % 2) + struct.pack("<HH", freq, flags) + struct.pack("<bb", -60, -95)
    return struct.pack("<BBH", 0, 0, 4 + len(words) + len(body)) + words + bytes(body)


FRAME = bytes.fromhex("80000000ffffffffffff02e5c500000602e5c500000600") + bytes(30)
FW_RADIOTAP = radiotap(2437)
check("the firmware's radiotap header is 16 bytes, and its frequency is read",
      len(FW_RADIOTAP) == 16 and FW_RADIOTAP[4:8] == bytes.fromhex("6a000000") and
      remote.radiotap_freq_khz(FW_RADIOTAP + FRAME) == 2437000)
check("5 GHz and channel 14", remote.radiotap_freq_khz(radiotap(5180, 0x0140) + FRAME) == 5180000 and
      remote.radiotap_freq_khz(radiotap(2484) + FRAME) == 2484000)
check("fields in front of Channel are stepped over, aligned: TSFT, Rate, one and three more presence words",
      all(remote.radiotap_freq_khz(radiotap(5745, 0x0140, **kw) + FRAME) == 5745000
          for kw in ({"tsft": True}, {"rate": True}, {"ext": 1}, {"tsft": True, "rate": True, "ext": 1},
                     {"ext": 3}, {"tsft": True, "ext": 2})))
check("no Channel field, no frequency", remote.radiotap_freq_khz(bytes.fromhex("0000080000000000") + FRAME) == 0 and
      remote.radiotap_freq_khz(bytes.fromhex("000009000200000000") + FRAME) == 0)
bad = [FW_RADIOTAP[:12], b"\x01" + FW_RADIOTAP[1:] + FRAME, FW_RADIOTAP[:2] + b"\x0c\x00" + FW_RADIOTAP[4:12],
       FW_RADIOTAP[:2] + b"\x40\x00" + FW_RADIOTAP[4:], b"", bytes.fromhex("00000c000800008000000080") + FRAME]
check("a header that does not hold together has no frequency, and nothing is read past it",
      [remote.radiotap_freq_khz(r) for r in bad] == [0] * len(bad))
random.seed(4)
for _ in range(20000):
    r = bytes(random.getrandbits(8) for _ in range(random.randint(0, 40)))
    if not 0 <= remote.radiotap_freq_khz(r) <= 0xFFFF * 1000:
        check("random radiotap garbage", False)
check("random garbage never crashes", True)

# ----------------------------------------------------------------------------------------------
# Bluetooth LE from older firmware: the CRC and the flags Kismet needs (tests/c/test_parser.c test_btle)
# ----------------------------------------------------------------------------------------------

# ADV_IND from a random address, flags and the short name "ESP". Its CRC, f1 c0 26, is the one Wireshark's
# btle dissector accepts for this PDU.
ADV_PDU = bytes.fromhex("40 0e 11 22 33 44 55 c6 02 01 06 04 09 45 53 50")
ADV_CRC = bytes.fromhex("f1c026")


def btle_record(flags, crc):
    return b"\x00\xc4\x00\x00" + struct.pack("<IHI", 0x8E89BED6, flags, 0x8E89BED6) + ADV_PDU + crc


NOW, OLD, BAD = btle_record(0x0C13, ADV_CRC), btle_record(0x0013, b"\0\0\0"), btle_record(0x0413, b"\x01\x02\x03")
check("BTLE advertising CRC matches the known one", struct.pack("<I", remote.btle_adv_crc(ADV_PDU))[:3] == ADV_CRC)
check("a record with CRC flags goes unchanged", remote.fix_btle(NOW) == (NOW, False))
check("older firmware's record gets the CRC and flags this firmware sends", remote.fix_btle(OLD) == (NOW, True))
check("a record checked and failed is left alone", remote.fix_btle(BAD) == (BAD, False))
check("a record too short to be one is dropped", remote.fix_btle(b"0123456789abcdef") is None and
      remote.fix_btle(NOW[:18]) is None and remote.fix_btle(NOW[:19]) is not None)
check("a record too long for the fix is dropped", remote.fix_btle(OLD[:24] + bytes(300)) is None)

# ----------------------------------------------------------------------------------------------
# Hopping, without a clock
# ----------------------------------------------------------------------------------------------

TEN = [str(c) for c in range(10)]
h = remote.Hopper(TEN, 5.0, True, 4, 0, None)
seq = [h.next_channel() for _ in range(20)]
check("shuffle with skip 4: every channel once in four laps", seq[:10] == list("0481592637") and seq[10:] == seq[:10])
h = remote.Hopper(TEN, 5.0, True, 4, 5, None)
check("offset: the walk starts where Kismet says", [h.next_channel() for _ in range(5)] == list("59159"))
h = remote.Hopper(TEN, 5.0, False, 1, 0, None)
check("no shuffle, skip 1: plain laps", [h.next_channel() for _ in range(12)] == list("012345678901"))
h = remote.Hopper(TEN, 5.0, False, 4, 0, None)
check("no shuffle, skip 4: each lap starts one further on, as the C does",
      [h.next_channel() for _ in range(19)] == list("0123456789123456789"))
h = remote.Hopper(["1", "6", "11"], 5.0, True, 4, 0, None)
check("skip longer than the list falls back to 1", h.skip == 1 and [h.next_channel() for _ in range(4)] == ["1", "6", "11", "1"])
check("interval is 1/rate", remote.Hopper(TEN, 5.0, False, 1, 0, None).interval() == 0.2 and
      remote.Hopper(TEN, 0.5, False, 1, 0, None).interval() == 2.0)
check("interval never below 50 ms", remote.Hopper(TEN, 1000.0, False, 1, 0, None).interval() == 0.05)

waits, tuned = [], []
h = remote.Hopper(["11", "15", "20"], 10.0, False, 1, 1, tuned.append, lambda s: waits.append(s) or len(waits) > 4)
h.run()
check("sleeps first, then tunes", waits == [0.1] * 5 and tuned == ["15", "20", "11", "15"])
waits = []
remote.Hopper(["11"], 0.0, False, 1, 0, tuned.append, lambda s: waits.append(s)).run()
check("rate 0 does not hop", waits == [])


class FakeTransport:
    def __init__(self):
        self.sent = []
        self.closed = False

    def send(self, data):
        self.sent.append(kv3.decode(data))

    def recv(self):
        while not self.closed:
            time.sleep(0.02)
        raise ConnectionError("closed")

    def close(self):
        self.closed = True


class FakeLink:
    synced = capturing = True
    last_status = None

    def __init__(self):
        self.tuned = []

    def set_channels(self, channels):
        self.tuned.append(list(channels))

    def stop(self):
        pass

    def join(self, timeout=None):
        pass


def connection(definition, boards=ONE, **kw):
    conn = remote.Connection(parse(definition, boards), FakeTransport(), "win32", **kw)
    conn.link, conn.hop_wait = FakeLink(), lambda seconds: True  # the hopper starts, and stops at once
    conn.channel = str(conn.source.initial_channel)  # as open() leaves it
    return conn


conn = connection("esp32c5-COM14:mode=zigbee")
conn.dispatch(configreq({2: {1: 5.0, 2: True, 4: 3, 5: ["11", "15", "20", "25", "26", "99"]}}))
hopper = conn.hopper
rep = conn.transport.sent[0]
check("hop config starts a hopper with Kismet's list, rate, shuffle and offset, and the C's skip",
      hopper is not None and hopper.channels == ["11", "15", "20", "25", "26"] and hopper.rate == 5.0 and
      hopper.shuffle and hopper.offset == 3 and hopper.skip == 4)
check("hop config report", rep.pkt_type == kv3.KDS_CONFIGREPORT and rep.code == 1 and rep.fields[1] == 9 and
      rep.fields[3] == {5: ["11", "15", "20", "25", "26"], 1: 5.0, 2: True, 4: 3, 3: 4, 6: 1})
check("an untunable channel is dropped and reported", conn.transport.sent[1].pkt_type == kv3.CMD_MESSAGE and
      "99" in conn.transport.sent[1].fields[2])
conn.dispatch(configreq({1: "20"}))
rep = conn.transport.sent[-1]
check("a single channel cancels hopping", hopper.cancelled.is_set() and conn.hopper is None)
check("and tunes the board to it", conn.link.tuned == [[20]] and rep.code == 1 and rep.fields == {1: 9, 2: "20"})
conn.dispatch(configreq({2: {5: ["11", "12"]}}))
check("hop fields Kismet leaves out keep their last values",
      conn.hopper.rate == 5.0 and conn.hopper.shuffle and conn.hopper.offset == 3)
hopper = conn.hopper
sent = len(conn.transport.sent)
conn.dispatch(configreq({1: "27"}))
msg, rep = conn.transport.sent[sent:]
# The C helper's refuse_channel: the capture goes on where it was, and the answer is a success with that channel
# and the reason, which also goes to Kismet as an error message, before the answer. A failed answer would have
# Kismet put the source in error and close it, and the source would come back hopping, its channel lost.
check("a channel the radio lacks is refused as the C helper refuses it: an error message first (%s)" % (msg.fields,),
      msg.pkt_type == kv3.CMD_MESSAGE and
      msg.fields == {1: kv3.MSG_ERROR, 2: "esp32c5-COM14 cannot tune to channel 27 in zigbee mode"})
check("... then a success with the channel the board stays on, and the reason (%s)" % (rep.fields,),
      rep.pkt_type == kv3.KDS_CONFIGREPORT and rep.code == 1 and
      rep.fields == {4: "esp32c5-COM14 cannot tune to channel 27 in zigbee mode", 1: 9, 2: "20"})
check("... the hopping is cancelled, as any channel set cancels it, nothing is tuned, and the source goes on",
      hopper.cancelled.is_set() and conn.hopper is None and conn.link.tuned == [[20]] and not conn.closed.is_set()
      and conn.channel == "20")
# The same answer's bytes, by hand from cf_send_configresp: the message, the seqno, then the channel, as the
# framework is not hopping any more; header code 1
rep_bytes = kv3.configreport(9, True, "b cannot tune to channel 40 in btle mode", channel="37")
check("the refusal's CONFIGREPORT bytes are cf_send_configresp's",
      rep_bytes == bytes.fromhex("DECAFBAD A9A9 0003 00000032 0012 0001 00000009" "83" "04 d9 28") +
      b"b cannot tune to channel 40 in btle mode" + bytes.fromhex("01 09" "02 a2 3337"))
# A set that is taken leaves the callback's message buffer empty, and the framework as add-to-kismet.sh patches
# it leaves an empty message out: the seqno and the channel alone
conn.dispatch(configreq({1: "15"}))
check("an accepted set's CONFIGREPORT bytes are the patched cf_send_configresp's, with no message",
      conn.transport.sent[-1].fields == {1: 9, 2: "15"} and kv3.configreport(9, True, None, channel="15") ==
      bytes.fromhex("DECAFBAD A9A9 0003 00000007 0012 0001 00000009" "82" "01 09" "02 a2 3135"))

# A channel that is no number at all: said as the C helper's chantranslate_callback says it, and answered like a
# refusal, without a reason (nothing was tried)
conn = connection("esp32c5-COM14")
sent = len(conn.transport.sent)
conn.dispatch(configreq({1: "abc"}))
msg, rep = conn.transport.sent[sent:]
check("a channel that is no number: an info message, and the channel it is on (%s, %s)" % (msg.fields, rep.fields),
      msg.fields == {1: kv3.MSG_INFO, 2: "unable to parse channel 'abc'; esp32c5 channels are plain numbers"} and
      rep.code == 1 and rep.fields == {1: 9, 2: "6"} and conn.link.tuned == [] and not conn.closed.is_set())
# Read as the C helper reads it (sscanf "%u"): Kismet's 6HT40 is 6, and reported as Kismet sent it, as the
# framework reports a set; a minus wraps round, as in C, to a channel no radio has
conn.dispatch(configreq({1: "6HT40"}))
check("6HT40 tunes 6, and is reported as 6HT40", conn.link.tuned == [[6]] and
      conn.transport.sent[-1].fields == {1: 9, 2: "6HT40"} and conn.channel == "6HT40")
conn.dispatch(configreq({1: "-1"}))
check("-1 is refused as 4294967295 (%s)" % conn.transport.sent[-1].fields,
      conn.transport.sent[-1].fields == {4: "esp32c5-COM14 cannot tune to channel 4294967295 in wifi mode", 1: 9,
                                          2: "6HT40"} and conn.link.tuned == [[6]])
check("channel_number reads what sscanf %u reads",
      [remote.channel_number(t) for t in ("6", " 6", "+6", "06", "6HT40", "149-", "abc", "", " ", "-1", "4294967296")]
      == [6, 6, 6, 6, 6, 149, None, None, None, 4294967295, 0])

# A source that hops and is then set to a channel it lacks stays on the channel the hopping left it on, and says
# that one, by its number: the C helper's chancontrol_callback keeps the channel of every hop for the framework's
# answers. The hops end on 11, not on 6, where the source starts, so that the answer tells the two apart.
conn = connection("esp32c5-COM14")
laps = iter([False, False, True])
conn.hop_wait = lambda seconds: next(laps)  # two hops, then the hopper stops
conn.dispatch(configreq({2: {1: 5.0, 2: False, 4: 0, 5: ["1", "11HT40-", "6"]}}))
conn.hopper.join(2)
conn.dispatch(configreq({1: "15"}))
check("hopped to 1 and 11 (11HT40-), then refused 15: the answer is 11, where the board is (%s, %s)" %
      (conn.link.tuned, conn.transport.sent[-1].fields),
      conn.link.tuned == [[1], [11]] and conn.transport.sent[-1].code == 1 and
      conn.transport.sent[-1].fields == {4: "esp32c5-COM14 cannot tune to channel 15 in wifi mode", 1: 9, 2: "11"}
      and conn.hopper is None and not conn.closed.is_set())

conn = connection("esp32c5-COM14:mode=btle")
conn.dispatch(configreq({1: "38"}))
check("btle accepts an advertising channel and has nothing to tune", conn.transport.sent[-1].code == 1 and
      conn.link.tuned == [])
check("... and reports 37, which the board goes on scanning with 38 and 39 (%s)" % conn.transport.sent[-1].fields,
      conn.transport.sent[-1].fields == {1: 9, 2: "37"} and conn.channel == "37")
conn.dispatch(configreq({1: "39"}))
check("... 39 as well", conn.transport.sent[-1].code == 1 and conn.transport.sent[-1].fields[2] == "37")
conn.dispatch(configreq({2: {1: 5.0, 5: ["37", "38", "39"]}}))
check("btle accepts a hop list too, each channel of it 37, as the C helper reports it (%s)" %
      conn.transport.sent[-1].fields[3][5],
      conn.transport.sent[-1].code == 1 and conn.link.tuned == [] and conn.transport.sent[-1].fields[3][5] == ["37"] * 3)
conn.dispatch(kv3.decode(kv3.frame(kv3.KDS_LISTREQ, 44, 1)))
check("unknown requests get the C's answer", conn.transport.sent[-1].pkt_type == kv3.KDS_PROBEREPORT and
      conn.transport.sent[-1].code == 0 and conn.transport.sent[-1].fields == {3: "Unsupported request", 1: 44})
conn.dispatch(kv3.decode(kv3.frame(kv3.CMD_PING, 0xABCDEF, 1)))
check("PING gets a PONG with its seqno", conn.transport.sent[-1] == kv3.Frame(kv3.CMD_PONG, 0, 0xABCDEF, {}))
for channel in ("6", "40"):
    sent = len(conn.transport.sent)
    conn.dispatch(configreq({1: channel}))
    msg, rep = conn.transport.sent[sent:]
    text = "esp32c5-COM14 cannot tune to channel %s in btle mode" % channel
    check("btle refuses %s as the C helper does: an error message, then success with 37 and the reason, the "
          "source going on (%s, %s)" % (channel, msg.fields, rep.fields),
          msg.fields == {1: kv3.MSG_ERROR, 2: text} and rep.code == 1 and rep.fields == {4: text, 1: 9, 2: "37"} and
          conn.channel == "37" and conn.link.tuned == [] and not conn.closed.is_set())

# BTLE packets from older firmware, and records no BTLE record can be
conn = connection("esp32c5-COM14:mode=btle")
for payload in (NOW, OLD, OLD, BAD, b"0123456789abcdef"):
    conn._on_packet(1700000000, 5, len(payload), payload)
data = [f for f in conn.transport.sent if f.pkt_type == kv3.KDS_PACKET]
notes = [f.fields[2] for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE]
check("BTLE: records pass, fixed where older firmware left them without CRC flags",
      [f.fields[4][6] for f in data] == [NOW, NOW, NOW, BAD] and all(f.fields[4][1] == 256 for f in data))
check("BTLE: each with 2402 MHz in its signal block, channel 37's, where the firmware puts every packet",
      all(f.fields[2] == {5: 2402000} for f in data))
check("BTLE: the fix-up is said once", sum("does not mark BTLE packets as CRC checked" in n for n in notes) == 1)
check("BTLE: the short record is dropped and counted", conn.dropped_btle == 1 and
      any("1 BTLE records of impossible length dropped" in n for n in notes))
check("BTLE: both said as statuses, info messages in the C helper's words (%s)" % notes,
      [f.fields for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE and "BTLE records" in f.fields[2]] ==
      [{1: kv3.MSG_INFO, 2: "esp32c5-COM14: 1 BTLE records of impossible length dropped"}] and
      all(f.fields[1] == kv3.MSG_INFO for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE))

# Wi-Fi: the frequency from the record's radiotap header, and no signal block when it has none
conn = connection("esp32c5-COM14")
for payload in (FW_RADIOTAP + FRAME, radiotap(5745, 0x0140, tsft=True) + FRAME, bytes.fromhex("0000080000000000") + FRAME):
    conn._on_packet(1700000000, 5, len(payload), payload)
data = [f for f in conn.transport.sent if f.pkt_type == kv3.KDS_PACKET]
check("Wi-Fi: the radiotap frequency goes in the signal block, the record unchanged (%s)" %
      [f.fields.get(2) for f in data],
      [f.fields.get(2) for f in data] == [{5: 2437000}, {5: 5745000}, None] and
      data[0].fields[4][6] == FW_RADIOTAP + FRAME and all(f.fields[4][1] == 127 for f in data))
# 802.15.4 as before: the channel, the signal and the frequency from the TAP header
conn = connection("esp32c5zigbee-COM14")
conn._on_packet(1700000000, 5, len(tap_header() + MAC), tap_header() + MAC)
data = [f for f in conn.transport.sent if f.pkt_type == kv3.KDS_PACKET]
check("802.15.4: channel 20, -61 dBm and 2450 MHz from the TAP header",
      len(data) == 1 and data[0].fields[2] == {7: "20", 1: (-61) & 0xFFFFFFFF, 5: 2450000})
conn._on_packet(1700000000, 5, 64, b"\x00\x00\x30\x00" + b"\xee" * 60)
check("802.15.4: a malformed TAP header is dropped, said as the C helper says it, an info message (%s)" %
      conn.transport.sent[-1].fields,
      conn.malformed == 1 and conn.transport.sent[-1].fields ==
      {1: kv3.MSG_INFO, 2: "esp32c5zigbee-COM14: 1 802.15.4 frames with a malformed TAP header dropped"})

# ----------------------------------------------------------------------------------------------
# Opening: Kismet's rewrite of the definition, a port that cannot be opened, channel=
# ----------------------------------------------------------------------------------------------


class FakeBoard:
    """Answers START the way the firmware does and then streams the given payloads in a loop."""

    def __init__(self, linktype, payloads, answer=True):
        self.linktype, self.payloads, self.answer = linktype, payloads, answer
        self.out, self.lock, self.commands, self.n, self.started = bytearray(), threading.Lock(), [], 0, False
        self.in_waiting = 0
        self.gone = False  # unplugged: every read and write fails

    def write(self, data):
        with self.lock:
            if self.gone:
                raise serial.SerialException("write failed: the port is gone")
            for line in data.decode().splitlines():
                self.commands.append(line)
                m = re.fullmatch(r"START \d+ (\w+)", line)
                if m and self.answer:
                    self.out += b"\n<<START>> %s\n" % m.group(1).encode()
                    self.out += struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, self.linktype)
                    self.started = True
        return len(data)

    def read(self, size):
        time.sleep(0.01)
        with self.lock:
            if self.gone:
                raise serial.SerialException("device reports readiness to read but returned no data")
            if self.started:
                p = self.payloads[self.n % len(self.payloads)]
                self.n += 1
                self.out += struct.pack("<IIII", 1700000000 + self.n, self.n, len(p), len(p)) + p
            data, self.out[:] = bytes(self.out), b""
        return data

    def close(self):
        pass

    def channels_since(self, start):
        with self.lock:
            return [c for c in self.commands[start:] if c.startswith("CHANNELS")]


RADIOTAP = [FW_RADIOTAP + FRAME]


def never(definition):
    raise AssertionError("resolved again: %s" % definition)


# Kismet sends back its rewrite of the definition; it is the same source, not a new resolution
bd.open_serial = lambda port, baud=921600: FakeBoard(bd.LINKTYPE_IEEE802_15_4_TAP, [b"x"])
conn = remote.Connection(parse('esp32c5:device=COM16,mode=zigbee,channels="11,15"', FOUR), FakeTransport(), "win32",
                         resolve=never)
conn.dispatch(openreq("esp32c5:channels=11,15,device=COM16,mode=zigbee"))
rep = conn.transport.sent[-1]
check("OPENREQ with Kismet's rewrite: the source as it was announced (DLT, uuid, the device= of four boards)",
      rep.pkt_type == kv3.KDS_OPENREPORT and rep.code == 1 and rep.fields[2] == 230 and rep.fields[3] == "COM16" and
      rep.fields[8] == "E5C50002-0000-0000-0000-744DBDA1B210" and conn.link.port == "COM16" and 6 not in rep.fields)
conn._stop_board()
# ... and of an unquoted list, whose rewrite starts with pieces that have no value: the same source, opened
conn = remote.Connection(parse("esp32c5-COM14:channels=1,6,11,mode=zigbee"), FakeTransport(), "win32", resolve=never)
conn.dispatch(openreq(REWRITE))
rep = conn.transport.sent[-1]
check("OPENREQ with Kismet's rewrite of an unquoted list: 802.15.4 as announced, not an error (%s)" % rep.fields.get(9),
      rep.pkt_type == kv3.KDS_OPENREPORT and rep.code == 1 and rep.fields[2] == 230 and
      rep.fields[8] == "E5C50002-0000-0000-0000-744DBDA1B2C3" and conn.link.port == "COM14" and
      conn.link.mode == bd.MODE_154)
conn._stop_board()
# ... and when it has to be resolved afresh, it is resolved as what it says
conn = remote.Connection(parse("esp32c5-COM14"), FakeTransport(), "win32", resolve=lambda d: parse(d))
conn.dispatch(openreq(REWRITE))
rep = conn.transport.sent[-1]
check("a rewrite resolved afresh reads the same", rep.code == 1 and rep.fields[2] == 230 and conn.source.mode == "zigbee")
conn._stop_board()

# channel= and channel_hop=false in the open report
bd.open_serial = lambda port, baud=921600: FakeBoard(bd.LINKTYPE_IEEE802_11_RADIOTAP, RADIOTAP)
conn = remote.Connection(parse("esp32c5-COM14:channel=36,channel_hop=false"), FakeTransport(), "win32", resolve=never)
conn.dispatch(openreq("esp32c5-COM14:channel=36,channel_hop=false"))
rep = conn.transport.sent[-1]
check("channel=36: the board starts on it and Kismet is told",
      rep.code == 1 and rep.fields[5] == "36" and conn.link.channels == [36] and conn.channel == "36")
check("channel_hop=false: the report says the source does not hop", rep.fields[6] == {6: False})
conn._stop_board()
bd.open_serial = lambda port, baud=921600: FakeBoard(bd.LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR, [NOW])
conn = remote.Connection(parse("esp32c5btle-COM14:channel=38"), FakeTransport(), "win32", resolve=never)
conn.dispatch(openreq("esp32c5btle-COM14:channel=38"))
rep = conn.transport.sent[-1]
check("btle channel=38: open, and reported as 37, the channel the board labels everything with",
      rep.code == 1 and rep.fields[2] == 256 and rep.fields[5] == "37" and rep.fields[4] == ["37"] and
      conn.link.channels == [37])
conn._stop_board()
conn = remote.Connection(parse("esp32c5-COM14"), FakeTransport(), "win32", resolve=lambda d: parse(d))
conn.dispatch(openreq("esp32c5-COM14:channel=15"))
rep = conn.transport.sent[-1]
check("an OPENREQ with a channel the radio lacks fails with the reason: %s" % rep.fields.get(9),
      rep.code == 0 and "channel=15 is not a channel the board can tune to in wifi mode" in rep.fields[9] and
      conn.closed.is_set() and conn.link is None)


# A port that cannot be opened fails the open, with the reason, as the C helper's open callback does
def cannot_open(port, baud=921600):
    raise serial.SerialException("could not open port '%s': FileNotFoundError(2, 'The system cannot find the file "
                                 "specified.', None, 2)" % port)


bd.open_serial = cannot_open
conn = remote.Connection(parse("esp32c5-COM14"), FakeTransport(), "win32", resolve=never)
t0 = time.monotonic()
conn.dispatch(openreq("esp32c5-COM14"))
rep = conn.transport.sent[-1]
check("a port that will not open fails the OPENREPORT with the OS error: %s" % rep.fields.get(9),
      rep.pkt_type == kv3.KDS_OPENREPORT and rep.code == 0 and "could not open port 'COM14'" in rep.fields[9] and
      conn.closed.is_set() and conn.link is None and time.monotonic() - t0 < remote.FIRST_OPEN_WAIT_S)
# The connection ends with a reason that names the port once, as pyserial's error does already
check("... and the connection ends with that error as its reason: %s" % conn.reason,
      conn.reason == rep.fields[9] and conn.reason.startswith("could not open port 'COM14': FileNotFoundError"))
bd.open_serial = lambda port, baud=921600: (_ for _ in ()).throw(bd.PortBusy(bd.IN_USE % port))
conn = remote.Connection(parse("esp32c5-COM14"), FakeTransport(), "win32", resolve=never)
conn.dispatch(openreq("esp32c5-COM14"))
rep = conn.transport.sent[-1]
check("a port in use fails the OPENREPORT: %s" % rep.fields.get(9),
      rep.code == 0 and rep.fields[9].startswith("COM14 is already in use by another capture"))
# The board's status says nothing of waiting: the connection ends on it, and the source is offered again
# 5 s later. The reason is the error, which names the port, not "could not open COM14 is already ..."
told = [f.fields[2] for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE]
check("... the status claims no wait, as the connection ends on it with the error as its reason (%s; %s)" %
      (told, conn.reason),
      told == ["%s: %s" % (conn.source.name, bd.IN_USE % "COM14")] and conn.reason == bd.IN_USE % "COM14" and
      conn.closed.is_set())
bd.open_serial = lambda port, baud=921600: (_ for _ in ()).throw(OSError(5, "Input/output error"))
conn = remote.Connection(parse("esp32c5-COM14"), FakeTransport(), "win32", resolve=never)
conn.dispatch(openreq("esp32c5-COM14"))
rep = conn.transport.sent[-1]
check("an error that does not name the port: the OPENREPORT names it, and the reason says it was the open "
      "(%s; %s)" % (rep.fields.get(9), conn.reason),
      rep.code == 0 and rep.fields[9] == "COM14: [Errno 5] Input/output error" and
      conn.reason == "could not open COM14: [Errno 5] Input/output error")

# The reason a board that is not capturing is given up includes what it last said. Synced (our marker found)
# is not capturing: a board whose firmware lacks the radio answers in another link type, and is given up too.
clock = [1000.0]
conn = connection("esp32c5-COM14:name=desk", clock=lambda: clock[0])
conn.link.capturing, conn.link.last_status = False, "desk: could not open port 'COM14': OSError(22, 'error 31')"
conn._watchdog()
clock[0] += remote.SYNC_TIMEOUT_S + 1
conn.last_ping = clock[0]
conn._watchdog()
err = [f for f in conn.transport.sent if f.pkt_type == kv3.CMD_ERROR]
check("the sync timeout is said in the C helper's words, with what the board last said: %s" %
      (err[0].fields[1] if err else None),
      err and err[0].fields[1] == "desk: no capture from the board on COM14 for 15 seconds (last: desk: could not "
      "open port 'COM14': OSError(22, 'error 31')); is it flashed with the esp32c5 sniffer firmware, and is nothing "
      "else holding the port?")
# Kismet silent for longer than capture_framework.c waits for a PING: the connection ends, said in its words
clock = [1000.0]
conn = connection("esp32c5-COM14", clock=lambda: clock[0])
clock[0] += remote.PING_TIMEOUT_S
conn._watchdog()
alive = not conn.closed.is_set()
clock[0] += 1
conn._watchdog()
check("no PING from Kismet for over 15 s ends the connection: %s" % conn.reason,
      alive and conn.closed.is_set() and conn.reason == "no PING from Kismet for 15 seconds")

# Board status goes to Kismet without flooding it
clock = [0.0]
conn = connection("esp32c5-COM14", clock=lambda: clock[0])
for t, text, kind in ((0, "s: COM30 opened", "opened"), (1, "s: Write timeout, reconnecting", "error"),
                      (2, "s: COM30 opened", "opened"), (3, "s: Write timeout, reconnecting", "error"),
                      (4, "s: COM30 opened", "opened"), (5, "s: Write timeout, reconnecting", "error"),
                      (6, "s: error 31, reconnecting", "error"), (7, "s: COM30 opened", "opened"),
                      (12, "s: Write timeout, reconnecting", "error"), (13, "s capturing (wifi)", "capturing"),
                      (14, "s: lost sync (damaged PCAP record)", "lost"), (15, "s capturing (wifi)", "capturing"),
                      (16, "s: board AA is on COM31 now", "info")):
    clock[0] = t
    conn._on_status(text, kind)
told = [f.fields[2] for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE]
check("status: opened once, an error at most every 10 s with a count, every change of state: %s" % told,
      told == ["s: COM30 opened", "s: Write timeout, reconnecting", "s: error 31, reconnecting",
               "s: Write timeout, reconnecting (2 more times in the last 11 s)", "s capturing (wifi)",
               "s: lost sync (damaged PCAP record)", "s capturing (wifi)", "s: board AA is on COM31 now"])
clock = [0.0]
conn = connection("esp32c5-COM14", clock=lambda: clock[0])
for t in range(12):
    clock[0] = t
    conn._on_status("s: COM30 now holds another board, looking for AA", "info")
    conn._on_status("s: board AA is on COM31 now", "info")
told = [f.fields[2] for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE]
check("status: a notice is held to once every 10 s as well: %s" % told,
      told == ["s: COM30 now holds another board, looking for AA", "s: board AA is on COM31 now",
               "s: COM30 now holds another board, looking for AA (9 more times in the last 10 s)",
               "s: board AA is on COM31 now (9 more times in the last 10 s)"])


# A port that holds another board while ours is nowhere to be found: the link tries it every second, and
# Kismet hears of it once, as from the C helper (whose status() drops a repeat)
class QuietPort:
    in_waiting = 0

    def read(self, size):
        time.sleep(0.01)
        return b""

    def write(self, data):
        return len(data)

    def close(self):
        pass


saved = bd.open_serial, bd.port_identity, bd.find_port_by_mac
bd.open_serial = lambda port, baud=921600: QuietPort()
bd.port_identity = lambda ser, port, platform=None: "BB:BB:BB:BB:BB:02"
bd.find_port_by_mac = lambda mac, boards=None: None
try:
    conn = remote.Connection(parse("esp32c5-COM14"), FakeTransport(), "win32")
    link = bd.BoardLink("COM14", bd.MODE_WIFI, [6], 250, lambda *r: None, conn._on_status, mac="AA:AA:AA:AA:AA:01",
                        name="esp32c5-COM14")
    link.start()
    time.sleep(3.5)
    link.stop()
    link.join(3)
finally:
    bd.open_serial, bd.port_identity, bd.find_port_by_mac = saved
told = [f.fields[2] for f in conn.transport.sent if f.pkt_type == kv3.CMD_MESSAGE]
check("another board on the port, ours nowhere, for 3.5 s: said to Kismet once (%s)" % told,
      told == ["esp32c5-COM14: COM14 now holds another board, looking for AA:AA:AA:AA:AA:01"] and
      isinstance(link.open_error, bd.OtherBoard) and str(link.open_error) == "COM14 holds another board than "
      "AA:AA:AA:AA:AA:01" and link.last_status == told[0])

# ----------------------------------------------------------------------------------------------
# Transports and the reconnect loop: nothing that goes wrong in one connection ends a source
# ----------------------------------------------------------------------------------------------


class ResetWs:
    """websocket-client before 1.9.1 on a connection the peer has reset: abort() raises ENOTCONN."""

    def __init__(self, abort_error):
        self.abort_error, self.shut = abort_error, False

    def abort(self):
        raise self.abort_error

    def shutdown(self):
        self.shut = True


for error in (OSError(107, "Transport endpoint is not connected"), AttributeError("'NoneType' object has no attribute")):
    t = remote.WsTransport.__new__(remote.WsTransport)
    t.ws = ResetWs(error)
    check("WsTransport.close() survives %s and still shuts the socket" % type(error).__name__,
          raises(Exception, t.close) is None and t.ws.shut)


class BrokenClose(FakeTransport):
    def close(self):
        FakeTransport.close(self)
        raise OSError(107, "Transport endpoint is not connected")


conn = remote.Connection(parse("esp32c5-COM14"), BrokenClose(), "win32")
conn.close("done")
check("a transport that fails to close does not fail the connection", conn.run() == "done")

# An exception's text in a log line is one line: what follows a line break would go out on a line of its own,
# with no time and no level
check("one_line: line breaks and the white space around them are one space",
      remote.one_line("Handshake status 401 -+-+- {'a': 'b'} -+-+- <html>\n<body>x</body>\r\n</html>\n") ==
      "Handshake status 401 -+-+- {'a': 'b'} -+-+- <html> <body>x</body> </html>" and
      remote.one_line("no break  here") == "no break  here")
import websocket  # noqa: E402

# A refused handshake as websocket-client raises it: before 1.9 without status_message, the reason only in
# its text, which holds Kismet's headers and page as well
bad = websocket.WebSocketBadStatusException("Handshake status 401 Unauthorized -+-+- {'server': 'Kismet'} -+-+- "
                                            "b'<html>401</html>\\n'", 401, "Unauthorized", {"server": "Kismet"},
                                            b"<html>401</html>\n")
bad.status_message = "Unauthorized"  # as 1.9 keeps it
check("a refused handshake is said by its status and reason: %s" % remote.refused_status(bad),
      remote.refused_status(bad) == "401 Unauthorized")
del bad.status_message
check("... the standard reason when websocket-client keeps none (1.7, 1.8)",
      remote.refused_status(bad) == "401 Unauthorized")
bad.status_message = "Proxy Error\n"
bad.status_code = 502
check("... and a reason of its own, one line", remote.refused_status(bad) == "502 Proxy Error")


# Whatever a connect or a connection ends with goes to the log as one line
def refuse_in_lines():
    raise ConnectionError("refused:\nline two\r\n")


def run_with_reason(self):
    return "Kismet closed it:\n  for this reason\n"


real_run = remote.Connection.run
remote.Connection.run = run_with_reason
with helper_log(logging.INFO) as said:
    for connect, text in ((refuse_in_lines, "refused:"), (FakeTransport, "connection ended:")):
        rs = remote.RemoteSource("esp32c5-COM14", connect, parse_now, remote.PortClaims())
        rs.start()
        end = time.monotonic() + 3
        while time.monotonic() < end and not any(text in m for m in said):
            time.sleep(0.02)
        rs.stop()
        rs.join(5)
remote.Connection.run = real_run
said = [m for m in said if "refused:" in m or "connection ended:" in m]
check("a connect error and the reason a connection ended are logged on one line each (%s)" % said,
      "esp32c5-COM14: refused: line two" in said and
      "esp32c5-COM14: connection ended: Kismet closed it: for this reason" in said and
      not any("\n" in m or "\r" in m for m in said))
# Kismet's own MESSAGE and ERROR texts, which the helper logs as they come, likewise
conn = connection("esp32c5-COM14")
with helper_log(logging.INFO) as said:
    conn.dispatch(kv3.decode(kv3.message(3, "a\nb\r\n")))
    conn.dispatch(kv3.decode(kv3.error(0, "x\n  y")))
check("Kismet's MESSAGE and ERROR are logged on one line each (%s)" % said, said == ["Kismet: a b", "Kismet: x y"])

remote.RECONNECT_BACKOFF_S = 0.2
real_run = remote.Connection.run
runs = []


def run_that_fails(self):
    runs.append(self)
    raise RuntimeError("something nobody expected")


remote.Connection.run = run_that_fails
rs = remote.RemoteSource("esp32c5-COM14", FakeTransport, parse_now, remote.PortClaims())
rs.start()
end = time.monotonic() + 5
while time.monotonic() < end and len(runs) < 3:
    time.sleep(0.02)
check("an exception in a connection does not end its source: %d connections, the thread alive" % len(runs),
      len(runs) >= 3 and rs.is_alive())
remote.Connection.run = real_run
rs.stop()
rs.join(5)
check("... and it stops when asked", not rs.is_alive())

connects = []
claims = remote.PortClaims()
claims.claim(bd.port_key("COM14", "win32"), types.SimpleNamespace(definition="esp32c5-COM14:mode=zigbee"))
rs = remote.RemoteSource("esp32c5:mode=wifi", lambda: connects.append(1) or FakeTransport(), parse_now, claims)
rs.start()
time.sleep(0.6)
check("a source whose port another has is never offered to Kismet", connects == [] and rs.is_alive())
rs.stop()
rs.join(5)

# A port another process holds (on Linux, board.port_locked from /proc/locks) is not offered either, until
# it is free; meanwhile the other sources of the helper go on
check("a source asks board.port_locked by default", remote.RemoteSource("esp32c5", None).in_use is bd.port_locked)
held, connects, transports = {"COM14"}, [], {}


def connect_as(name):
    def connect():
        connects.append(name)
        transports.setdefault(name, []).append(FakeTransport())
        return transports[name][-1]
    return connect


boards_now[0] = TWO
claims = remote.PortClaims()
with helper_log(logging.DEBUG) as said:
    busy = remote.RemoteSource("esp32c5-COM14:name=busy", connect_as("busy"), parse_now, claims,
                               in_use=lambda device: device in held)
    free = remote.RemoteSource("esp32c5zigbee-COM15:name=free", connect_as("free"), parse_now, claims,
                               in_use=lambda device: device in held)
    busy.start()
    free.start()
    time.sleep(1.0)
    before = list(connects)
    held.clear()
    end = time.monotonic() + 3
    while time.monotonic() < end and not (transports.get("busy") and transports["busy"][0].sent):
        time.sleep(0.02)
    offered = "busy" in connects
    busy.stop()
    free.stop()
    busy.join(5)
    free.join(5)
boards_now[0] = ONE
warned = [m for m in said if "already in use" in m]
check("a port another process holds: not offered to Kismet, while the other source is (%s)" % before,
      before == ["free"])
check("... said once, in the C helper's words: the name, the port, and that it looks again (%s)" % warned,
      warned == ["busy: COM14 is already in use by another capture; not offering it to Kismet until it is free "
                 "(looked at again every %g seconds)" % remote.RECONNECT_BACKOFF_S] and
      sum("still in use" in m for m in said) >= 2)
check("... and offered once it is free, as the source it is",
      offered and transports["busy"][0].sent[0].pkt_type == kv3.KDS_NEWSOURCE and
      transports["busy"][0].sent[0].fields[3] == "E5C50001-0000-0000-0000-744DBDA1B2C3")
# Held, free, and held again: the warning goes once for each time it is held, not once for the helper's life
looks = [True, True, False, True, True, False]
rs = remote.RemoteSource("esp32c5-COM14:name=spells", None, in_use=lambda device: looks[0])
with helper_log(logging.DEBUG) as said:
    answers = []
    while looks:
        answers.append(rs.available(types.SimpleNamespace(device="COM14", name="spells")))
        looks.pop(0)
check("... held twice: warned twice, once each time, and looked at again in between (%s)" % answers,
      answers == [False, False, True, False, False, True] and
      sum("already in use" in m for m in said) == 2 and sum("still in use" in m for m in said) == 2)

# ----------------------------------------------------------------------------------------------
# The command line: login from the environment, localhost, the websocket module, stopping
# ----------------------------------------------------------------------------------------------


def cli(**kw):
    ns = dict(tcp=False, user=None, password=None, apikey=None)
    ns.update(kw)
    return types.SimpleNamespace(**ns)


a = cli()
check("KISMET_CAP_APIKEY is taken first", remote.login_from_env(a, {"KISMET_CAP_APIKEY": "k3y", "KISMET_CAP_USER": "u",
                                                                   "KISMET_CAP_PASSWORD": "p"}) == "KISMET_CAP_APIKEY"
      and a.apikey == "k3y" and a.user is None)
a = cli()
check("then KISMET_CAP_USER and KISMET_CAP_PASSWORD",
      remote.login_from_env(a, {"KISMET_CAP_USER": "u", "KISMET_CAP_PASSWORD": "p", "KISMET_CAP_APIKEY": ""}) and
      (a.user, a.password, a.apikey) == ("u", "p", None))
a = cli()
check("a user without a password is not enough", remote.login_from_env(a, {"KISMET_CAP_USER": "u"}) is None and a.user is None)
a = cli(apikey="given")
check("a login on the command line wins", remote.login_from_env(a, {"KISMET_CAP_APIKEY": "k3y"}) is None and a.apikey == "given")
a = cli(tcp=True)
check("legacy TCP takes no login", remote.login_from_env(a, {"KISMET_CAP_APIKEY": "k3y"}) is None and a.apikey is None)
# Half a login on the command line: the environment completes it, as kismet_cap_esp32c5's login_from_env does
a = cli(user="u")
check("--user alone takes KISMET_CAP_PASSWORD, and never the API key",
      remote.login_from_env(a, {"KISMET_CAP_PASSWORD": "p", "KISMET_CAP_APIKEY": "k3y", "KISMET_CAP_USER": "other"})
      == "KISMET_CAP_PASSWORD" and (a.user, a.password, a.apikey) == ("u", "p", None))
a = cli(password="p")
check("--password alone takes KISMET_CAP_USER",
      remote.login_from_env(a, {"KISMET_CAP_USER": "u", "KISMET_CAP_APIKEY": "k3y"}) == "KISMET_CAP_USER" and
      (a.user, a.password, a.apikey) == ("u", "p", None))
a = cli(user="u")
check("--user alone with KISMET_CAP_PASSWORD empty takes nothing",
      remote.login_from_env(a, {"KISMET_CAP_PASSWORD": "", "KISMET_CAP_APIKEY": "k3y"}) is None and
      (a.password, a.apikey) == (None, None))
a = cli(user="u", apikey="given")
check("--user with --apikey takes nothing", remote.login_from_env(a, {"KISMET_CAP_PASSWORD": "p"}) is None and
      a.password is None)
a = cli(user="u", password="p")
check("a whole login takes nothing", remote.login_from_env(a, {"KISMET_CAP_PASSWORD": "q", "KISMET_CAP_APIKEY": "k3y"})
      is None and (a.user, a.password, a.apikey) == ("u", "p", None))

check("localhost is 127.0.0.1 first", remote.connect_order("localhost") == ["127.0.0.1", "::1"] and
      remote.connect_order("LocalHost")[0] == "127.0.0.1")
check("other names and IPv6 addresses as they are", remote.connect_order("::1") == ["::1"] and
      remote.connect_order("kismet.lan") == ["kismet.lan"] and remote.connect_order("192.168.1.20") == ["192.168.1.20"])
tried = []


def refuse(host):
    tried.append(host)
    raise ConnectionRefusedError(111, "Connection refused")


check("a refused address falls through to the next",
      remote._first_that_connects([lambda: refuse("v4"), lambda: tried.append("v6") or "ok"]) == "ok" and
      tried == ["v4", "v6"])
tried = []
e = raises(ConnectionError, remote._first_that_connects,
           [lambda: (_ for _ in ()).throw(ConnectionError("Kismet refused the websocket: 401")),
            lambda: tried.append("v6")])
check("a refused login does not", e is not None and tried == [])
e = raises(ConnectionRefusedError, remote._first_that_connects, [lambda: refuse("v4"), lambda: refuse("v6")])
check("when every address refuses, the first error is the one said", e is not None and tried[-2:] == ["v4", "v6"])

# localhost is dialled at its addresses, but Kismet is still asked for by the name: the Host header, and with
# TLS the name its certificate is checked against
opened, auths, cookies, proxies = [], [], [], []


def ws_refusing_v4(url, sslopt=None, host=None, origin=None, authorization=None, cookie=None, proxy=None):
    opened.append((url, sslopt, host, origin))
    auths.append(authorization)
    cookies.append(cookie)
    proxies.append(proxy)
    if "127.0.0.1" in url:
        raise ConnectionRefusedError(111, "Connection refused")
    return "transport"


def kismet_auth_token(cookie_header):
    """The auth token Kismet takes from a Cookie header (kis_net_beast_httpd.cc at cfe4270): the whole header
    through decode_uri(value, true) -- %XX to its byte, '+' to a space -- then decode_cookies(), which splits it
    at ';' and each cookie at its first '=', passing over the spaces in front of a name; the KISMET cookie."""
    decoded = re.sub(r"%([0-9A-Fa-f]{2})|\+", lambda m: chr(int(m.group(1), 16)) if m.group(1) else " ",
                     cookie_header)
    decoded = decoded.encode("latin-1").decode("utf-8")
    found, pos = {}, 0
    while pos < len(decoded):
        if decoded[pos] == " ":
            pos += 1
            continue
        eq = decoded.find("=", pos)
        if eq < 0:
            break
        end = decoded.find(";", eq)
        end = len(decoded) if end < 0 else end
        found[decoded[pos:eq]] = decoded[eq + 1:end]
        pos = end + 1
    return found.get("KISMET")


def ws_args(**kw):
    ns = dict(tcp=False, user=None, password=None, apikey="k", ssl=False, ssl_certificate=None,
              endpoint=remote.WS_ENDPOINT)
    ns.update(kw)
    return types.SimpleNamespace(**ns)


real_ws_transport = remote.WsTransport
remote.WsTransport = ws_refusing_v4
try:
    remote.make_connector(ws_args(ssl=True, ssl_certificate="ca.pem"), "localhost", 2501)()
    check("wss to localhost: 127.0.0.1, then ::1, each checked as localhost with the Host of the name: %s" % opened,
          [u.split("/datasource")[0] for u, _, _, _ in opened] == ["wss://127.0.0.1:2501", "wss://[::1]:2501"] and
          all(o[1:] == ({"ca_certs": "ca.pem", "server_hostname": "localhost"}, "localhost:2501", "https://localhost:2501")
              for o in opened))
    opened = []
    remote.make_connector(ws_args(ssl=True), "LocalHost", 443)()
    check("... without a CA file too (the system's), and the port left out for 443 as websocket-client does",
          opened[0][1:] == ({"server_hostname": "LocalHost"}, "LocalHost", "https://LocalHost"))
    opened = []
    remote.make_connector(ws_args(), "localhost", 2501)()
    check("ws to localhost: the Host of the name, nothing for TLS",
          opened[0][1:] == (None, "localhost:2501", "http://localhost:2501"))
    for name, url in (("kismet.lan", "wss://kismet.lan:2501"), ("::1", "wss://[::1]:2501"),
                      ("192.168.1.20", "wss://192.168.1.20:2501")):
        opened = []
        remote.make_connector(ws_args(ssl=True, ssl_certificate="ca.pem"), name, 2501)()
        check("%s is dialled as it is, and websocket-client names it itself" % name,
              opened[0][0].startswith(url + "/") and opened[0][1:] == ({"ca_certs": "ca.pem"}, None, None))
    # The login: a user and password in a Basic Authorization header, as they are ('&', '%41', a space, not
    # ASCII), and an API key in the KISMET cookie, neither in the address, which proxies log. Only a user name
    # with ':', which Basic cannot carry, goes in the address.
    for kw, query, login, cookie in (({}, "", None, "KISMET=k"),
                                     ({"user": "kis&met", "password": "p&ss %41 wörd", "apikey": None}, "",
                                      "kis&met:p&ss %41 wörd", None),
                                     ({"user": "co:lon", "password": "p w&", "apikey": None},
                                      "?user=co%3Alon&password=p%20w%26", None, None)):
        opened, auths, cookies = [], [], []
        remote.make_connector(ws_args(**kw), "kismet.lan", 2501)()
        sent = auths[0] and auths[0].startswith("Basic ") and base64.b64decode(auths[0][6:]).decode("utf-8")
        check("the login %s: address %s, Authorization %s, Cookie %s" % (kw or "(API key)", opened[0][0], auths[0],
                                                                         cookies[0]),
              opened[0][0] == "ws://kismet.lan:2501" + remote.WS_ENDPOINT + query and
              (auths[0] is None if login is None else sent == login) and cookies[0] == cookie)
    # The key percent-encoded, so that Kismet's decoding of the whole header gives it back as it is: '+' is
    # not a space, '%41' not an A. (A ';' could not pass: Kismet decodes before it splits. Its keys are hex.)
    for key in ("4F1A0B9C2D", "k3y/+=", "a+b %41=c", "wörd", "x%zz%"):
        opened, cookies = [], []
        remote.make_connector(ws_args(apikey=key), "kismet.lan", 2501)()
        check("API key %r: cookie %s, which Kismet reads back as the key" % (key, cookies[0]),
              kismet_auth_token(cookies[0]) == key and "?" not in opened[0][0])
    opened, cookies = [], []
    remote.make_connector(ws_args(), "localhost", 2501)()
    check("... to localhost too, both addresses with the cookie and no key in the address (%s)" % opened,
          [u for u, _, _, _ in opened] == ["ws://127.0.0.1:2501" + remote.WS_ENDPOINT,
                                            "ws://[::1]:2501" + remote.WS_ENDPOINT] and cookies == ["KISMET=k"] * 2)
    # The HTTP proxy in the environment, the one websocket-client would take, for a host that is not loopback
    # and that no_proxy does not cover. websocket-client is told which way, not left to work it out (it reads
    # no_proxy otherwise than curl, and each version otherwise): given a proxy, "*" among the hosts it is not
    # for sends every host direct, and "@" none.
    THROUGH, DIRECT = ["@"], {"http_proxy_host": "unused", "http_proxy_port": 1, "http_no_proxy": ["*"]}
    env = {"http_proxy": "http://us%40er:p%3Ass@proxy.lan:3128", "https_proxy": "http://tls-proxy.lan",
           "no_proxy": "kismet.lan, .corp,10.0.0.0/8"}
    proxies = []
    with helper_log(logging.INFO) as said:
        remote.make_connector(ws_args(), "192.168.1.20", 2501, env)()
    check("ws: the proxy in http_proxy, its login decoded, and no host it is not for (%s)" % proxies,
          proxies == [{"http_proxy_host": "proxy.lan", "http_proxy_port": 3128, "http_proxy_auth": ("us@er", "p:ss"),
                       "http_no_proxy": THROUGH}])
    check("... and said, without the proxy's login (%s)" % said,
          said == ["the websocket to 192.168.1.20 goes through the HTTP proxy in http_proxy (proxy.lan:3128)"])
    proxies = []
    remote.make_connector(ws_args(ssl=True), "192.168.1.20", 2501, env)()
    check("wss: the proxy in https_proxy, on port 80 when it names none, as websocket-client takes it (%s)" % proxies,
          proxies[0]["http_proxy_host"] == "tls-proxy.lan" and proxies[0]["http_proxy_port"] == 80 and
          proxies[0]["http_proxy_auth"] is None)
    for env, what, expected in (
            ({"HTTP_PROXY": "http://up.lan:8080", "NO_PROXY": "other.lan"}, "in capitals",
             {"http_proxy_host": "up.lan", "http_proxy_port": 8080, "http_proxy_auth": None, "http_no_proxy": THROUGH}),
            ({"HTTP_PROXY": "http://up.lan:8080", "NO_PROXY": "KISMET.lan"}, "in capitals, NO_PROXY covering the host",
             DIRECT),
            ({"http_proxy": "http://[fd00::1]:3128"}, "at an IPv6 address, no_proxy not set",
             {"http_proxy_host": "fd00::1", "http_proxy_port": 3128, "http_proxy_auth": None,
              "http_no_proxy": THROUGH}),
            ({"http_proxy": "", "HTTP_PROXY": "http://up.lan:8080"}, "an empty http_proxy over HTTP_PROXY", {}),
            ({"http_proxy": "proxy.lan:3128"}, "without http:// (websocket-client finds no host in it)", DIRECT),
            ({"https_proxy": "http://tls-proxy.lan"}, "only for wss", {}),
            ({}, "none", {})):
        proxies = []
        with helper_log(logging.INFO) as said:
            remote.make_connector(ws_args(), "kismet.lan", 2501, env)()
        check("a proxy %s: %s, %s" % (what, proxies[0], said),
              proxies == [expected] and bool(said) == (expected.get("http_no_proxy") == THROUGH))
    proxies = []
    with helper_log(logging.INFO) as said:
        remote.make_connector(ws_args(), "localhost", 2501, {"http_proxy": "http://proxy.lan:3128"})()
        raises(OSError, remote.make_connector(ws_args(), "127.0.0.1", 2501, {"http_proxy": "http://proxy.lan:3128"}))
    check("--connect localhost or 127.0.0.1: direct, at every address, and nothing is said of the proxy (%s)" % said,
          said == [] and proxies == [DIRECT] * 3)
    for no_proxy in ("192.168.1.20", "192.168.0.0/16", "*"):
        proxies = []
        with helper_log(logging.INFO) as said:
            remote.make_connector(ws_args(), "192.168.1.20", 2501,
                                  {"http_proxy": "http://proxy.lan:3128", "no_proxy": no_proxy})()
        check("no_proxy=%s: direct, and nothing is said of the proxy (%s)" % (no_proxy, said),
              said == [] and proxies == [DIRECT])
    # A proxy that cannot be read, refused when it would be used, without the value, which may hold a password
    for value in ("http://us:s3cret@proxy.lan:31x8", "http://us:s3cret@proxy.lan:65536",
                  "http://us:s3cret@[fd00::1:3128"):
        e = raises(ValueError, remote.make_connector, ws_args(), "kismet.lan", 2501, {"http_proxy": value})
        check("a proxy that cannot be read (%s): refused, its password not in the message (%s)" %
              (value.split("@")[1], e),
              e is not None and str(e) == "the proxy in http_proxy is not http://HOST:PORT with a port up to 65535")
        proxies = []
        unused = [raises(ValueError, lambda: remote.make_connector(ws_args(), "::1", 2501, {"http_proxy": value})()),
                  raises(ValueError, lambda: remote.make_connector(ws_args(), "kismet.lan", 2501,
                                                                   {"http_proxy": value, "no_proxy": "kismet.lan"})())]
        check("... but not when the websocket would not go through it: --connect ::1, or a host no_proxy covers (%s)" %
              unused, unused == [None, None] and proxies == [DIRECT, DIRECT])
    check("--tcp takes no proxy", remote.make_connector(ws_args(tcp=True), "kismet.lan", 3501,
                                                        {"http_proxy": "http://proxy.lan:31x8"}) is not None)
finally:
    remote.WsTransport = real_ws_transport

# no_proxy, read much as curl reads it: in any case, a dot in front or behind making no difference, a name
# covering the names under it and no other, an address in a network (IPv6 as well), entries apart at commas or
# white space, "*" for every host
for host, no_proxy, covered in (
        ("kismet.lan", "KISMET.LAN", True), ("kismet.lan", "Kismet.Lan.", True), ("kismet.lan.", "kismet.lan", True),
        ("Kismet.LAN", "kismet.lan", True), ("k.kismet.lan", "kismet.lan", True), ("k.kismet.lan", ".kismet.lan", True),
        ("kismet.lan", ".kismet.lan", True), ("kismet.lan", "lan", True), ("badkismet.lan", "kismet.lan", False),
        ("badexample.com", ".example.com", False), ("kismet.lan", "a.lan kismet.lan", True),
        ("kismet.lan", "a.lan , kismet.lan", True), ("kismet.lan", "a.lan,,.", False), ("kismet.lan", "", False),
        ("x.y", "*", True), ("x.y", "a.lan,*", True), ("10.1.2.3", "10.0.0.0/8", True), ("10.1.2.3", "10.1.2.3", True),
        ("11.1.2.3", "10.0.0.0/8", False), ("10.1.2.3", "2.3", False), ("10.1.2.3", "kismet.lan", False),
        ("kismet.lan", "10.0.0.0/8", False), ("fd00::5", "FD00::/8", True), ("fd00::5", "fd00:0:0::5", True),
        ("fd00::5", "10.0.0.0/8", False), ("192.168.1.20", "kismet.lan,192.168.1.0/24", True)):
    check("no_proxy=%r %s %s" % (no_proxy, "covers" if covered else "does not cover", host),
          remote.no_proxy_covers(host, no_proxy) == covered)

# What websocket-client (the one these tests run with) makes of the options: the helper's way, every time.
# Left to itself, 1.9 sends 127.0.0.1 through the proxy unless no_proxy names it, 1.7 and 1.8 when no_proxy is
# set without it, and each reads no_proxy its own way: 1.9 KISMET.LAN only as written, and .example.com
# covering badexample.com; 1.7 and 1.8 a name only as itself, and no IPv6 network.
from websocket import _url as ws_url  # noqa: E402


def ws_route(host, env):
    opts = remote.proxy_options(False, host, env)
    return ws_url.get_proxy_info(host, False, opts.get("http_proxy_host"), opts.get("http_proxy_port", 0),
                                 opts.get("http_proxy_auth"), opts.get("http_no_proxy"))[0] or "direct"


LOOPBACK = ["127.0.0.1", "127.8.9.10", "::1", "0:0:0:0:0:0:0:1", "localhost"]
for no_proxy, direct, proxied in ((None, LOOPBACK, ["192.168.1.20", "kismet.lan"]),
                                  ("kismet.lan,.corp", LOOPBACK + ["kismet.lan", "k.corp"], ["192.168.1.20"]),
                                  ("KISMET.LAN", ["kismet.lan"], ["other.lan"]),
                                  ("lan", ["kismet.lan"], ["kismet.corp"]),
                                  ("example.com", ["kismet.example.com"], ["badexample.com"]),
                                  (".example.com", ["kismet.example.com"], ["badexample.com"]),
                                  ("10.0.0.0/8,fd00::/8", ["10.1.2.3", "fd00::5"], ["11.1.2.3", "fe00::5"])):
    env = {"http_proxy": "http://proxy.lan:3128"}
    if no_proxy is not None:
        env["no_proxy"] = no_proxy
    got = {h: ws_route(h, env) for h in direct + proxied}
    check("websocket-client %s, no_proxy %s: direct to %s, through the proxy to %s (%s)" %
          (websocket.__version__, no_proxy or "not set", direct, proxied, got),
          got == dict([(h, "direct") for h in direct] + [(h, "proxy.lan") for h in proxied]) and
          all((remote.proxy_route(False, h, env) is None) == (h in direct) for h in got))


def main_exit(argv, **kw):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        try:
            return remote.main(argv, **kw), err.getvalue()
        except SystemExit as e:
            return e.code, err.getvalue()


saved = sys.modules.get("websocket")
sys.modules["websocket"] = None  # import websocket raises ImportError
code, err = main_exit(["--connect", "127.0.0.1:2501", "--apikey", "k", "--source", "esp32c5-COM14"])
if saved is None:
    del sys.modules["websocket"]
else:
    sys.modules["websocket"] = saved
check("no websocket-client: a clear error and a non-zero exit (%s)" % code,
      code == 2 and "needs websocket-client" in err and "--tcp" in err)
code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5:mode=wifi", "--source",
                       "esp32c5btle"])
check("two sources without a port are refused at startup (%s)" % code, code == 2 and "name no port" in err)
code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5:mode=wifi,channel=15"])
check("a channel the radio lacks is refused at startup (%s)" % code, code == 2 and "channel=15" in err)


class DummySource(threading.Thread):
    """Stands in for RemoteSource in main(): runs until stopped, or ends at once."""
    made = []

    def __init__(self, definition, connect, lives=True):
        super().__init__(daemon=True)
        self.definition, self.connect, self.lives = definition, connect, lives
        self.stopped = threading.Event()
        DummySource.made.append(self)

    def run(self):
        if self.lives:
            self.stopped.wait()

    def stop(self):
        self.stopped.set()


real_remote_source = remote.RemoteSource
bd.find_boards = lambda: ONE
bd.port_exists = lambda device, platform=None: True
remote.RemoteSource = lambda d, c: DummySource(d, c, lives=False)
with helper_log() as said:
    code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5-COM14"])
check("every source thread gone without a stop request: exit status 1, an internal error (%s, %s)" % (code, said),
      code == 1 and any("internal error" in m for m in said))
# The exit statuses --help gives are the ones main() returns: a source never ends by itself (RemoteSource.run
# catches everything), so 1 is --list without a board to list, or an internal error
check("--help does not promise an exit status for sources that end by themselves",
      "ended by itself" not in remote.HELP_EPILOG and "1  --list listed no board" in remote.HELP_EPILOG and
      "internal error" in remote.HELP_EPILOG)
with contextlib.redirect_stdout(io.StringIO()):
    code_one, _ = main_exit(["--list"])
    bd.find_boards = lambda: []
    code_none, _ = main_exit(["--list"])
    bd.find_boards = lambda: ONE
check("--list: exit status 0 with a board to list, 1 without (%s, %s)" % (code_one, code_none),
      code_one == 0 and code_none == 1)

signals = [signal.SIGINT, signal.SIGTERM] + ([signal.SIGBREAK] if hasattr(signal, "SIGBREAK") else [])
# Compared with what was there before, not with Python's defaults: a Python started with SIGINT ignored (a
# background job of a non-interactive shell, nohup) never had default_int_handler
handlers_before = {sig: signal.getsignal(sig) for sig in signals}
stops = []
real_install_stop_handlers = remote.install_stop_handlers
remote.install_stop_handlers = lambda stop: stops.append(stop) or real_install_stop_handlers(stop)
for sig in signals:
    DummySource.made = []
    remote.RemoteSource = DummySource
    threading.Timer(0.5, signal.raise_signal, (sig,)).start()
    t0 = time.monotonic()
    code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5-COM14"])
    check("%s stops the helper cleanly: exit 0, sources stopped (%s)" % (signal.Signals(sig).name, code),
          code == 0 and DummySource.made and all(s.stopped.is_set() for s in DummySource.made) and
          time.monotonic() - t0 < 3)
remote.install_stop_handlers = real_install_stop_handlers
check("the signal handlers are given back afterwards",
      all(signal.getsignal(sig) is handlers_before[sig] for sig in signals))


# A stop signal's handler runs in the main thread between two steps of whatever it is doing, which is mostly
# main()'s stop.wait(). It must not wait on anything wait() holds: with a threading.Event, set() waits for
# ever on the lock the end of wait() holds, and the helper never stops (it hung so here, now and then, with
# one signal after another). So the handler main() installs runs after every step in C of the wait of what
# main() waits on, in a thread of its own, which is free to hang.
def handler_inside_wait(stop, handler):
    sys.setprofile(lambda frame, event, arg: event == "c_return" and handler(signal.SIGTERM, None))
    try:
        stop.wait(0.3)
    finally:
        sys.setprofile(None)


stop = type(stops[0])()
previous = remote.install_stop_handlers(stop)
on_signal = signal.getsignal(signal.SIGTERM)
for sig, handler in previous.items():
    signal.signal(sig, handler)
t = threading.Thread(target=handler_inside_wait, args=(stop, on_signal), daemon=True)
t.start()
t.join(3)
check("a stop signal whose handler runs in the middle of main()'s wait stops it (%s)" % type(stop).__name__,
      not t.is_alive() and stop.is_set())


# A stop signal again while main() stops, as Ctrl+C pressed twice: the first one decided the exit status, 0,
# and the second must change nothing. When main() gave the handlers from before it back before the sources
# had stopped, a second Ctrl+C raised KeyboardInterrupt in a join (a traceback, and on Windows exit status
# 0xC000013A), and a second Ctrl+Break or SIGTERM ended the helper at once with that signal's own status.
class SlowToStop(DummySource):
    """Ends 0.6 s after it is stopped, and has a second Ctrl+C come 0.2 s into that."""
    seen = []

    def run(self):
        self.stopped.wait()
        time.sleep(0.6)

    def stop(self):
        SlowToStop.seen.append({sig: signal.getsignal(sig) for sig in signals})
        threading.Timer(0.2, signal.raise_signal, (signal.SIGINT,)).start()
        super().stop()


DummySource.made = []
remote.RemoteSource = SlowToStop
threading.Timer(0.5, signal.raise_signal, (signal.SIGINT,)).start()
t0 = time.monotonic()
try:
    code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5-COM14"])
except KeyboardInterrupt:
    code = "KeyboardInterrupt"
took = time.monotonic() - t0
check("Ctrl+C again while the sources stop changes nothing: exit 0, no KeyboardInterrupt, no slower (%s, %.2f s)"
      % (code, took), code == 0 and took < 2.5 and SlowToStop.made[0].stopped.is_set())
check("... as every stop signal is ignored from the stop on (%s)" % SlowToStop.seen,
      len(SlowToStop.seen) == 1 and all(h == signal.SIG_IGN for h in SlowToStop.seen[0].values()))
check("... and has its handler back once the sources have stopped",
      all(signal.getsignal(sig) is handlers_before[sig] for sig in signals))
# python -m: the process ends with main(), and Python sets a signal that has a handler back to its default
# action as it shuts down, so there they stay ignored
remote.RemoteSource = DummySource
threading.Timer(0.3, signal.raise_signal, (signal.SIGTERM,)).start()
code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5-COM14"], exiting=True)
left = {sig: signal.getsignal(sig) for sig in signals}
for sig, handler in handlers_before.items():
    signal.signal(sig, handler)
check("main(exiting=True), as python -m runs it, leaves the stop signals ignored for Python's shutdown (%s, %s)"
      % (code, left), code == 0 and all(h == signal.SIG_IGN for h in left.values()) and
      all(signal.getsignal(sig) is handlers_before[sig] for sig in signals))

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def helper_stopped_twice(stop_signals):
    """Runs python -m esp32c5_kismet.remote with one source, which connects to a server that takes the
    connection and never answers the websocket's handshake, so that the source cannot stop before the join's
    limit (5 s). Sends the helper stop_signals[0] while it connects, and each of the others 0.3 s apart once
    it has logged "stopping". Returns its exit status, its log, and the seconds from the first signal to its
    exit, or what went wrong."""
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(20)
    env = {k: v for k, v in os.environ.items()
           if not k.upper().startswith(("KISMET_CAP_", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"))}
    # uuid= makes a port that is not there a source all the same, offered to Kismet without being looked for
    device = "COM250" if sys.platform == "win32" else "/dev/esp32c5-test-absent"
    p = subprocess.Popen([sys.executable, "-m", "esp32c5_kismet.remote", "--connect",
                          "127.0.0.1:%d" % server.getsockname()[1], "--apikey", "k", "--source",
                          "esp32c5:device=%s,uuid=AAAAAAAA-0000-0000-0000-0000000000AB" % device],
                         cwd=REPO, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, text=True, errors="replace",
                         creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
    said, stopping = [], threading.Event()

    def read():
        for line in p.stderr:
            said.append(line.rstrip())
            if said[-1].endswith("INFO: stopping"):
                stopping.set()

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    conn = None
    try:
        conn, _ = server.accept()
        t0 = time.monotonic()
        os.kill(p.pid, stop_signals[0])
        stopping.wait(5)
        for sig in stop_signals[1:]:
            time.sleep(0.3)
            try:
                os.kill(p.pid, sig)
            except OSError:
                pass  # it has exited already
        p.wait(15)
        took = time.monotonic() - t0
    except (OSError, subprocess.TimeoutExpired) as e:
        took = "%s: %s" % (type(e).__name__, e)
    finally:
        if p.poll() is None:
            p.kill()
        p.wait()
        reader.join(3)
        if conn is not None:
            conn.close()
        server.close()
    return p.returncode, said, took


def on_a_console():
    """Windows: is this process on a console, which a child it starts shares? Without one, the child would
    get a console window of its own, which no event from here can reach."""
    import ctypes
    return ctypes.windll.kernel32.GetConsoleProcessList((ctypes.c_uint32 * 1)(), 1) != 0


if sys.platform == "win32":
    # Ctrl+Break: Ctrl+C cannot be sent to one process group, only to the whole console, this test as well
    sent, stop_signals = "Ctrl+Break twice", [signal.CTRL_BREAK_EVENT] * 2
else:
    sent, stop_signals = "SIGINT, SIGINT and SIGTERM", [signal.SIGINT, signal.SIGINT, signal.SIGTERM]
if sys.platform == "win32" and not on_a_console():
    print("SKIP the helper stopped with %s (no console to send a console event in)" % sent)
else:
    code, said, took = helper_stopped_twice(stop_signals)
    check("python -m esp32c5_kismet.remote sent %s, all but the first while it stops: exit 0, no traceback, "
          "within the join's limit (%s, %s s, %s)" % (sent, code, took if isinstance(took, str) else "%.2f" % took,
                                                      said[-3:]),
          code == 0 and not isinstance(took, str) and took < 7 and "INFO: stopping" in "\n".join(said) and
          not any("Traceback" in line for line in said))

made = []
real_make_connector = remote.make_connector
remote.make_connector = lambda args, host, port: made.append((args, host, port)) or (lambda: None)
remote.RemoteSource = lambda d, c: DummySource(d, c, lives=False)
os.environ["KISMET_CAP_APIKEY"] = "fr0m-env"
try:
    code, err = main_exit(["--connect", "localhost:2501", "--source", "esp32c5-COM14"])
finally:
    del os.environ["KISMET_CAP_APIKEY"]
check("main takes the login from KISMET_CAP_APIKEY (%s)" % err.strip()[-80:],
      made and made[0][0].apikey == "fr0m-env" and made[0][0].user is None)
made = []
os.environ["KISMET_CAP_PASSWORD"] = "s3cret"
try:
    code, err = main_exit(["--connect", "127.0.0.1:2501", "--user", "kismet", "--source", "esp32c5-COM14"])
finally:
    del os.environ["KISMET_CAP_PASSWORD"]
check("main completes --user with KISMET_CAP_PASSWORD, as kismet_cap_esp32c5 does (%s)" % err.strip()[-80:],
      made and (made[0][0].user, made[0][0].password, made[0][0].apikey) == ("kismet", "s3cret", None))
made = []
code, err = main_exit(["--connect", "127.0.0.1:2501", "--user", "kismet", "--source", "esp32c5-COM14"])
check("... and without it asks for both (%s)" % code,
      code == 2 and "give both --user and --password" in err and "KISMET_CAP_PASSWORD" in err and made == [])
# A login Kismet takes neither way: a user name with ':', which goes in the address as Basic cannot carry it,
# and an '&' anywhere in the login, at which Kismet cuts a login in the address after decoding it. Warned
# once, never with the login itself in the text. '&' alone passes in the Authorization header, ':' alone in
# the address.
for argv, env, warn in ((["--user", "kis&met", "--password", "pw"], {}, False),
                        (["--user", "kismet", "--password", "s3&cret"], {}, False),
                        (["--user", "co:lon", "--password", "s3 c%41ret"], {}, False),
                        (["--user", "co:lon", "--password", "s3&cret"], {}, True),
                        (["--user", "co:l&on", "--password", "pw"], {}, True),
                        ([], {"KISMET_CAP_USER": "co:lon", "KISMET_CAP_PASSWORD": "s3&cret"}, True),
                        (["--user", "co:lon"], {"KISMET_CAP_PASSWORD": "s3&cret"}, True),
                        (["--apikey", "k3y"], {"KISMET_CAP_USER": "co:lon", "KISMET_CAP_PASSWORD": "s3&cret"}, False),
                        (["--tcp", "--user", "co:lon", "--password", "s3&cret"], {}, False)):
    os.environ.update(env)
    try:
        with helper_log() as said:
            code, err = main_exit(["--connect", "127.0.0.1:2501"] + argv + ["--source", "esp32c5-COM14"])
    finally:
        for k in env:
            del os.environ[k]
    warned = [m for m in said if "cannot log in either way" in m]
    check("a login with ':' or '&' (%s): %s" % (" and ".join(filter(None, (" ".join(argv), ", ".join(env)))),
                                               warned[0] if warned else "no warning"),
          code == 1 and (warned == [] if not warn else
                         len(warned) == 1 and warned[0].startswith("the Kismet user name holds ':' and the login '&'")
                         and "instead of the login" in warned[0] and
                         not any(s in warned[0] for s in ("s3&c", "co:l", "l&on"))))
remote.make_connector = real_make_connector
# A proxy the helper would use and cannot read: refused at startup, as a mistake in what the helper was given,
# rather than failing every connection. Where it would not be used, it stops nothing.
saved_proxy = os.environ.get("http_proxy")
for value in ("http://us:s3cret@proxy.lan:31x8", "http://us:s3cret@[fd00::1:3128"):
    os.environ["http_proxy"] = value
    try:
        code, err = main_exit(["--connect", "kismet.lan:2501", "--apikey", "k", "--source", "esp32c5-COM14"])
        DummySource.made = []
        with helper_log():
            code_lo, _ = main_exit(["--connect", "127.0.0.1:2501", "--apikey", "k", "--source", "esp32c5-COM14"])
    finally:
        if saved_proxy is None:
            del os.environ["http_proxy"]
        else:
            os.environ["http_proxy"] = saved_proxy
    check("a proxy that cannot be read (%s): exit 2 at startup, the password not shown (%s)" %
          (value.split("@")[1], err.strip()[-75:]),
          code == 2 and "error: the proxy in http_proxy is not http://HOST:PORT with a port up to 65535" in err and
          "s3cret" not in err)
    check("... and --connect 127.0.0.1, which never goes through it, starts its source (%s)" % code_lo,
          code_lo == 1 and len(DummySource.made) == 1)
# An unquoted list starts the helper, with the warning
remote.RemoteSource = lambda d, c: DummySource(d, c, lives=False)
with helper_log() as said:
    code, err = main_exit(["--connect", "127.0.0.1:2501", "--tcp", "--source", "esp32c5-COM14:channels=1,6,11,mode=zigbee"])
check("an unquoted list starts the helper, with the warning (%s)" % code,
      code == 1 and any('write channels="1,6,11"' in m for m in said))
remote.RemoteSource = real_remote_source

# ----------------------------------------------------------------------------------------------
# Whole sessions: a fake board, and a fake Kismet over TCP and over a websocket
# ----------------------------------------------------------------------------------------------


class FakeKismet:
    """The server side of v3, enough to drive a session: listens, accepts, speaks TCP frames or a websocket."""

    def __init__(self, websocket, tls=None, set_cookie=None):
        self.websocket, self.tls = websocket, tls  # tls: an ssl.SSLContext, for wss
        self.set_cookie = set_cookie  # a Set-Cookie for the websocket's answer, as a proxy in front may add
        self.lsock = socket.socket()
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(4)
        self.port = self.lsock.getsockname()[1]

    def accept(self, timeout=10):
        self.lsock.settimeout(timeout)
        sock, _ = self.lsock.accept()
        if self.tls is not None:
            sock.settimeout(timeout)
            sock = self.tls.wrap_socket(sock, server_side=True)
        return FakeSession(sock, self.websocket, self.set_cookie)


class FakeSession:
    def __init__(self, sock, websocket, set_cookie=None):
        self.sock, self.websocket = sock, websocket
        self.buf, self.seqno, self.frames, self.inbox = bytearray(), 0, [], queue.Queue()
        self.sock.settimeout(10)
        self.request_line, self.headers, self.header_lines = None, {}, []
        if websocket:
            self._handshake(set_cookie)
        threading.Thread(target=self._reader, daemon=True).start()

    def _handshake(self, set_cookie):
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.sock.recv(4096)
        head, _, rest = bytes(self.buf).partition(b"\r\n\r\n")
        self.buf = bytearray(rest)
        lines = head.decode().split("\r\n")
        self.request_line, self.header_lines = lines[0], lines[1:]
        self.headers = {k.strip().lower(): v.strip() for k, v in (line.split(":", 1) for line in lines[1:])}
        key = self.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
        # like Kismet's beast server: no Sec-WebSocket-Protocol in the answer
        self.sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Accept: %s\r\n%s\r\n"
                           % (accept, "Set-Cookie: %s\r\n" % set_cookie if set_cookie else "")).encode())

    def _more(self):
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError("the helper closed the connection")
        self.buf += data

    def _exact(self, n):
        while len(self.buf) < n:
            self._more()
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def _next_frame(self):
        if not self.websocket:
            while True:
                fr, used = kv3.take_frame(self.buf)
                if fr is not None:
                    del self.buf[:used]
                    return fr
                self._more()
        while True:  # client frames are masked
            b0, b1 = self._exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._exact(8))[0]
            mask = self._exact(4) if b1 & 0x80 else b"\0\0\0\0"
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(self._exact(n)))
            if b0 & 0x0F == 8:
                raise ConnectionError("the helper closed the websocket")
            if b0 & 0x0F == 2:
                return kv3.decode(data)

    def _reader(self):
        try:
            while True:
                fr = self._next_frame()
                self.frames.append(fr)
                self.inbox.put(fr)
        except (OSError, kv3.ProtocolError):
            self.inbox.put(None)

    def send(self, pkt_type, fields=None):
        # Kismet writes code 1 into everything it sends (the send_packet_v3 callers in kis_datasource.cc)
        self.seqno += 1
        data = kv3.frame(pkt_type, self.seqno, 1, fields)
        if self.websocket:
            n = len(data)
            data = bytes([0x82]) + (bytes([n]) if n < 126 else b"\x7e" + struct.pack("!H", n)) + data
        self.sock.sendall(data)
        return self.seqno

    def expect(self, pkt_type, timeout=10, match=lambda fr: True):
        end = time.monotonic() + timeout
        while True:
            fr = self.inbox.get(timeout=max(0.01, end - time.monotonic()))
            if fr is None:
                raise ConnectionError("closed while waiting for %s" % kv3.PACKET_NAMES[pkt_type])
            if fr.pkt_type == pkt_type and match(fr):
                return fr

    def closed(self, timeout=10):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                if self.inbox.get(timeout=0.1) is None:
                    return True
            except queue.Empty:
                pass
        return False

    def close(self):
        self.sock.close()


def wait_for(cond, timeout=8.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def websocket_version():
    """The websocket-client the sessions run with: the one on the PYTHONPATH, which may be an older one"""
    import websocket
    return websocket.__version__


bd.find_boards = lambda: ONE
bd.port_exists = lambda device, platform=None: True
remote.RECONNECT_BACKOFF_S = 0.2

# --- 802.15.4 over the legacy TCP protocol ---

GOOD = tap_header(20, -61.0) + MAC
GOOD2 = tap_header(25, -80.5) + MAC[:5]
BROKEN = b"\x00\x00\x30\x00" + b"\xee" * 60
fake = FakeBoard(bd.LINKTYPE_IEEE802_15_4_TAP, [GOOD, BROKEN, GOOD2])
bd.open_serial = lambda port, baud=921600: fake
server = FakeKismet(websocket=False)
DEF = "esp32c5-COM14:mode=zigbee,name=bench"
rs = remote.RemoteSource(DEF, lambda: remote.TcpTransport("127.0.0.1", server.port), claims=remote.PortClaims())
rs.start()
sess = server.accept()
ns = sess.expect(kv3.KDS_NEWSOURCE)
check("TCP: NEWSOURCE announces the source", ns.fields == {1: DEF, 2: "esp32c5", 3: "E5C50002-0000-0000-0000-744DBDA1B2C3"})
seq = sess.send(kv3.KDS_OPENREQ, {1: DEF})
rep = sess.expect(kv3.KDS_OPENREPORT)
check("TCP: OPENREPORT", rep.code == 1 and rep.seqno == seq and rep.fields[1] == seq and rep.fields[2] == 230 and
      rep.fields[8] == "E5C50002-0000-0000-0000-744DBDA1B2C3" and rep.fields[3] == "COM14" and
      rep.fields[7] == "Espressif USB-Serial-JTAG (74:4D:BD:A1:B2:C3)" and rep.fields[5] == "15" and
      rep.fields[4] == [str(c) for c in range(11, 27)] and rep.fields[10] == remote.HELPER_VERSION)
d1 = sess.expect(kv3.KDS_PACKET)
d2 = sess.expect(kv3.KDS_PACKET)
check("TCP: board opened on 802.15.4, channel 15 first", fake.commands[:2] == ["MODE 802154", "CHANNELS 15"])
check("TCP: TAP rewrapped to DLT 230 with a signal block",
      d1.fields[4][1] == 230 and d1.fields[4][6] == MAC and d1.fields[4][4] == len(MAC) and
      d1.fields[2] == {7: "20", 1: 0xFFFFFFC3, 5: 2450000})
check("TCP: each record keeps its own timestamp", d1.fields[4][2] + 2 == d2.fields[4][2] and d2.fields[4][3] == d1.fields[4][3] + 2)
check("TCP: the malformed record in between was dropped and counted",
      d2.fields[4][6] == MAC[:5] and d2.fields[2] == {7: "25", 1: (-81) & 0xFFFFFFFF, 5: 2475000} and
      rs.connection.malformed >= 1)
check("TCP: board status goes to Kismet as info messages, by the source's name, in the C helper's words",
      wait_for(lambda: any(f.pkt_type == kv3.CMD_MESSAGE and f.fields == {1: kv3.MSG_INFO, 2: "bench capturing (zigbee)"}
                           for f in sess.frames)) and
      any(f.pkt_type == kv3.CMD_MESSAGE and f.fields == {1: kv3.MSG_INFO, 2: "bench: COM14 opened"} for f in sess.frames))
ping = sess.send(kv3.CMD_PING)
check("TCP: PONG", sess.expect(kv3.CMD_PONG) == kv3.Frame(kv3.CMD_PONG, 0, ping, {}))

start = len(fake.commands)
seq = sess.send(kv3.KDS_CONFIGREQ, {2: {1: 20.0, 2: True, 4: 0, 5: ["11", "15", "20", "25", "26"]}})
rep = sess.expect(kv3.KDS_CONFIGREPORT)
check("TCP: hop config accepted", rep.code == 1 and rep.fields[1] == seq and rep.fields[3][5] == ["11", "15", "20", "25", "26"])
check("TCP: the helper hops the board itself, in the C's shuffled order, every 50 ms",
      wait_for(lambda: len(fake.channels_since(start)) >= 6) and
      fake.channels_since(start)[:6] == ["CHANNELS %s" % c for c in ("11", "26", "15", "20", "25", "11")])
seq = sess.send(kv3.KDS_CONFIGREQ, {1: "11"})
rep = sess.expect(kv3.KDS_CONFIGREPORT)
after = len(fake.commands)
time.sleep(0.3)
check("TCP: a single channel stops the hopping", rep.code == 1 and rep.fields == {1: seq, 2: "11"} and
      fake.commands[after - 1] == "CHANNELS 11" and fake.channels_since(after) == [])
# A channel the radio lacks, as the C helper refuses it: the board stays on 11 and goes on capturing, over the
# same connection, and Kismet hears why as an error message, before the answer
seq = sess.send(kv3.KDS_CONFIGREQ, {1: "27"})
rep = sess.expect(kv3.KDS_CONFIGREPORT)
refusal = [i for i, f in enumerate(sess.frames) if f.pkt_type == kv3.CMD_MESSAGE and
           f.fields == {1: kv3.MSG_ERROR, 2: "bench cannot tune to channel 27 in zigbee mode"}]
check("TCP: channel 27 refused: the error message, then success with channel 11 and the reason (%s)" % rep.fields,
      rep.code == 1 and rep.fields == {4: "bench cannot tune to channel 27 in zigbee mode", 1: seq, 2: "11"} and
      len(refusal) == 1 and refusal[0] < sess.frames.index(rep))
packets = sum(f.pkt_type == kv3.KDS_PACKET for f in sess.frames)
check("TCP: ... and the capture goes on, on 11, on the same connection",
      wait_for(lambda: sum(f.pkt_type == kv3.KDS_PACKET for f in sess.frames) > packets + 5, 5) and
      fake.channels_since(after) == [] and rs.connections == 1 and not rs.connection.closed.is_set())
sess.close()
sess = server.accept()
check("TCP: after Kismet goes away the helper offers the source again, with the same uuid",
      sess.expect(kv3.KDS_NEWSOURCE).fields == ns.fields and rs.connections == 2)
rs.stop()
sess.close()
rs.join(5)
check("TCP: stops cleanly", not rs.is_alive())

# --- Wi-Fi over the websocket, with an API key that needs escaping, and localhost ---

fake = FakeBoard(bd.LINKTYPE_IEEE802_11_RADIOTAP, RADIOTAP)
server = FakeKismet(websocket=True)
args = types.SimpleNamespace(tcp=False, user=None, password=None, apikey="k3y/+=", ssl=False, ssl_certificate=None,
                             endpoint=remote.WS_ENDPOINT)
DEF = "esp32c5-COM14"
rs = remote.RemoteSource(DEF, remote.make_connector(args, "localhost", server.port), claims=remote.PortClaims())
rs.start()
sess = server.accept()
check("WS: the endpoint, and no API key in the address, which proxies log (%s)" % sess.request_line,
      sess.request_line == "GET /datasource/remote/remotesource.ws HTTP/1.1")
check("WS: the API key in the KISMET cookie, which websocket-client %s sends as given (%s), and Kismet reads back "
      "as the key" % (websocket_version(), sess.headers.get("cookie")),
      sess.headers.get("cookie") == "KISMET=k3y%2F%2B%3D" and kismet_auth_token(sess.headers["cookie"]) == "k3y/+="
      and "authorization" not in sess.headers)
check("WS: localhost was dialled at 127.0.0.1, and Kismet asked for by the name: Host %s, Origin %s" %
      (sess.headers.get("host"), sess.headers.get("origin")),
      sess.sock.getpeername()[0] == "127.0.0.1" and sess.headers.get("host") == "localhost:%d" % server.port and
      sess.headers.get("origin") == "http://localhost:%d" % server.port)
check("WS: asks for the kismet-remote subprotocol", sess.headers.get("sec-websocket-protocol") == "kismet-remote")
ns = sess.expect(kv3.KDS_NEWSOURCE)
check("WS: NEWSOURCE", ns.fields == {1: DEF, 2: "esp32c5", 3: "E5C50001-0000-0000-0000-744DBDA1B2C3"})
seq = sess.send(kv3.KDS_OPENREQ, {1: DEF})
rep = sess.expect(kv3.KDS_OPENREPORT)
check("WS: OPENREPORT for wifi", rep.code == 1 and rep.fields[2] == 127 and rep.fields[5] == "6" and
      rep.fields[4] == [str(c) for c in bd.all_channels("wifi")])
d = sess.expect(kv3.KDS_PACKET)
check("WS: radiotap passes through unchanged as DLT 127, its frequency in the signal block",
      d.fields[2] == {5: 2437000} and d.fields[4][1] == 127 and d.fields[4][6] == RADIOTAP[0] and
      d.fields[4][4] == len(RADIOTAP[0]))
check("WS: board opened on Wi-Fi, channel 6 first", fake.commands[:2] == ["MODE WIFI", "CHANNELS 6"])
ping = sess.send(kv3.CMD_PING)
check("WS: PONG", sess.expect(kv3.CMD_PONG).seqno == ping)
seq = sess.send(kv3.KDS_CONFIGREQ, {1: "149"})
check("WS: single channel", sess.expect(kv3.KDS_CONFIGREPORT).fields == {1: seq, 2: "149"} and
      wait_for(lambda: "CHANNELS 149" in fake.commands))
rs.stop()
check("WS: Ctrl+C closes the connection", sess.closed())
rs.join(5)
check("WS: stops cleanly", not rs.is_alive())

# --- a login over the websocket: in the Authorization header, '&' and all, and not in the address ---

server = FakeKismet(websocket=True)
served = queue.Queue()
threading.Thread(target=lambda: served.put(server.accept()), daemon=True).start()
transport = remote.make_connector(ws_args(user="kis&met", password="p&ss %41", apikey=None), "127.0.0.1",
                                  server.port)()
sess = served.get(timeout=10)
check("WS: a login goes in a Basic Authorization header, as it is, and not in the address (%s)" % sess.request_line,
      sess.request_line == "GET /datasource/remote/remotesource.ws HTTP/1.1" and
      sess.headers.get("authorization") == "Basic " + base64.b64encode(b"kis&met:p&ss %41").decode())
transport.close()
sess.close()

# --- a cookie that a proxy in front of Kismet sets goes in the one Cookie header a request may have, before the
# key: of two Cookie headers, the proxy or Kismet would read only one ---

import websocket  # noqa: E402  -- its cookie jar is emptied afterwards, for the cases after this one

server = FakeKismet(websocket=True, set_cookie="lb=a1; Domain=127.0.0.1; Path=/")
served = queue.Queue()
threading.Thread(target=lambda: [served.put(server.accept()) for _ in range(2)], daemon=True).start()
connect = remote.make_connector(ws_args(apikey="k3y"), "127.0.0.1", server.port)
try:
    first = connect()
    served.get(timeout=10).close()
    first.close()
    second = connect()
    sess = served.get(timeout=10)
    second.close()
    sess.close()
finally:
    websocket._handshake.CookieJar.jar.clear()
cookies = [line for line in sess.header_lines if line.lower().startswith("cookie:")]
check("WS: the proxy's cookie and the key in one Cookie header, the key last (%s)" % cookies,
      cookies == ["Cookie: lb=a1; KISMET=k3y"] and kismet_auth_token(cookies[0][len("Cookie: "):]) == "k3y")

# --- a redirect is not followed: Kismet never answers the websocket with one, and the login or the key would
# go along to wherever it points ---


def serve_http_once(answer):
    """One HTTP request answered with answer, or with what answer(request) makes of the request's bytes when it
    is a function, in a thread; returns the port and a queue that gets the request."""
    lsock = socket.socket()
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(1)
    got = queue.Queue()

    def serve():
        try:
            lsock.settimeout(10)
            sock, _ = lsock.accept()
            sock.settimeout(10)
            head = b""
            while b"\r\n\r\n" not in head:
                data = sock.recv(4096)
                if not data:
                    break
                head += data
            got.put(head.decode("latin-1"))
            sock.sendall(answer(head) if callable(answer) else answer)
            sock.close()
        except OSError:
            pass
        finally:
            lsock.close()

    threading.Thread(target=serve, daemon=True).start()
    return lsock.getsockname()[1], got


for kw, secret in (({"apikey": "S3CRET-KEY"}, "Cookie: KISMET=S3CRET-KEY"),
                   ({"user": "kis", "password": "s3cret", "apikey": None},
                    "Authorization: Basic " + base64.b64encode(b"kis:s3cret").decode())):
    # where the redirect points, which must hear nothing, and a proxy that answers the websocket with it
    target, target_got = serve_http_once(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
    where = "ws://127.0.0.1:%d/login" % target
    proxy, proxy_got = serve_http_once(("HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\n\r\n"
                                        % where).encode())
    e = raises(ConnectionError, remote.make_connector(ws_args(**kw), "127.0.0.1", proxy))
    asked = proxy_got.get(timeout=10)
    check("WS: a redirect to another address is not followed, %s and all (%s)" % (secret.split(":")[0], e),
          e is not None and secret in asked and target_got.empty() and
          str(e) == "the websocket was answered with a redirect (HTTP 302 to %s), which the helper does not follow: "
          "Kismet never redirects it, and the login would go along to wherever it points; check --connect, "
          "--endpoint and --ssl" % where)

# --- where a redirect points is said byte for byte as the C helper says it (add-to-kismet.sh): up to its query
# or fragment, which can hold the login, and with each byte that is not printable ASCII, the space included,
# percent-encoded, since a terminal could take one for part of a control sequence ---


def redirect_message(status, shown):
    return ("the websocket was answered with a redirect (HTTP %d%s), which the helper does not follow: Kismet never "
            "redirects it, and the login would go along to wherever it points; check --connect, --endpoint and "
            "--ssl" % (status, " to " + shown if shown is not None else ""))


def redirect_said(status, location, **kw):
    """What the helper says of a websocket answered with status (bytes, "302 Found") and a Location of those
    bytes, or none for None, or what location(request) makes of the request's bytes; and the request."""
    def answer(request):
        where = location(request) if callable(location) else location
        return (b"HTTP/1.1 %s\r\n%sContent-Length: 0\r\n\r\n"
                % (status, b"Location: %s\r\n" % where if where is not None else b""))
    port, got = serve_http_once(answer)
    e = raises(ConnectionError, remote.make_connector(ws_args(**kw), "127.0.0.1", port))
    return (str(e) if e is not None else None), got.get(timeout=10)


# A server that sends every request elsewhere (nginx: return 301 https://$host$request_uri) gives the request's
# own query back, and a user name with ':' puts the login in that query
said, asked = redirect_said(b"301 Moved Permanently",
                            lambda request: b"https://127.0.0.2:1" + request.split(b"\r\n")[0].split(b" ")[1],
                            user="kis:colon", password="redirect-pass", apikey=None)
check("WS redirect: the request's own query echoed, login and all, said only up to it (%s)" % said,
      said == redirect_message(301, "https://127.0.0.2:1/datasource/remote/remotesource.ws?...") and
      "?user=kis%3Acolon&password=redirect-pass " in asked and "redirect-pass" not in said and "colon" not in said)
for name, status, location, shown in (
        ("a fragment", 302, b"https://127.0.0.2:1/elsewhere#top", "https://127.0.0.2:1/elsewhere#..."),
        ("a fragment before a query", 302, b"/elsewhere#a?user=kis", "/elsewhere#..."),
        ("nothing but a query", 307, b"?user=kis", "?..."),
        ("control bytes: ESC [2J, and U+009B (CSI) in UTF-8", 302, b"http://127.0.0.2:1/\x1b[2J\xc2\x9bx",
         "http://127.0.0.2:1/%1B[2J%C2%9Bx"),
        ("a space", 302, b"/two words", "/two%20words"),
        ("a tab and DEL", 302, b"/a\tb\x7f", "/a%09b%7F"),
        ("non-ASCII", 308, u"/café/€".encode("utf-8"), "/caf%C3%A9/%E2%82%AC"),
        ("a '%' already there, which stays as it is", 302, b"/a%20b", "/a%20b"),
        ("a relative Location", 301, b"/elsewhere", "/elsewhere"),
        ("no Location", 302, None, None),
        ("an empty Location", 303, b"", None)):
    reason = {301: b"Moved Permanently", 302: b"Found", 303: b"See Other", 307: b"Temporary Redirect",
              308: b"Permanent Redirect"}[status]
    said, _ = redirect_said(b"%d %s" % (status, reason), location)
    check("WS redirect: %s (%r)" % (name, said), said == redirect_message(status, shown))

# --- a refused login: one line, the status and the hint, never Kismet's headers and page ---

# Kismet's answer at cfe427074, as websocket-client 1.9.2 put it into its exception's text, newline and all
KISMET_401 = (b"HTTP/1.1 401 Unauthorized\r\nServer: Kismet\r\nContent-Type: text/html\r\nContent-Length: 165\r\n\r\n"
              b"<html><head><title>401 Permission denied</title></head><body><h1>401 Permission denied</h1><br><p>"
              b"This resource requires a login or session token.</p></body></html>\n")
HINT = (" (check the login -- --user/--password or KISMET_CAP_USER/KISMET_CAP_PASSWORD -- or the API key -- --apikey "
        "or KISMET_CAP_APIKEY; the key needs the datasource role)")
port, got = serve_http_once(KISMET_401)
e = raises(ConnectionError, remote.make_connector(ws_args(apikey="wrong"), "127.0.0.1", port))
got.get(timeout=10)
check("WS: a 401 is said as its status, with the hint, on one line (%s)" % e,
      e is not None and str(e) == "Kismet refused the websocket: 401 Unauthorized" + HINT)
port, got = serve_http_once(b"HTTP/1.1 404 Not Found\r\nContent-Length: 10\r\n\r\nNot found\n")
e = raises(ConnectionError, remote.make_connector(ws_args(), "127.0.0.1", port))
got.get(timeout=10)
check("WS: another refusal is its status alone (%s)" % e, e is not None and str(e) == "Kismet refused the websocket: "
      "404 Not Found")
port, got = serve_http_once(KISMET_401)
with helper_log() as said:
    rs = remote.RemoteSource("esp32c5-COM14", remote.make_connector(ws_args(apikey="wrong"), "127.0.0.1", port),
                             claims=remote.PortClaims())
    rs.start()
    got.get(timeout=10)
    wait_for(lambda: said)
    rs.stop()
    rs.join(5)
check("... and logged so: %s" % said[:1],
      said[:1] == ["esp32c5-COM14: Kismet refused the websocket: 401 Unauthorized" + HINT])

# --- an HTTP proxy from the environment: used for another host, and never for a loopback address ---


class ConnectProxy:
    """An HTTP proxy as websocket-client uses one: CONNECT host:port, then a tunnel, which leads to target
    whatever host it names. It keeps the request lines."""

    def __init__(self, target):
        self.target, self.requests = target, []
        self.lsock = socket.socket()
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(4)
        self.port = self.lsock.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                client, _ = self.lsock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def _serve(self, client):
        head = b""
        while b"\r\n\r\n" not in head:
            data = client.recv(4096)
            if not data:
                return client.close()
            head += data
        self.requests.append(head.split(b"\r\n")[0].decode())
        upstream = socket.create_connection(("127.0.0.1", self.target))
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        for a, b in ((client, upstream), (upstream, client)):
            threading.Thread(target=self._pipe, args=(a, b), daemon=True).start()

    @staticmethod
    def _pipe(a, b):
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def close(self):
        self.lsock.close()


# kismet.test stands for a Kismet elsewhere: this machine's resolver gives 127.0.0.1 for it, where the fake is;
# through the proxy the name goes to the proxy unresolved
real_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, *a, **kw: real_getaddrinfo("127.0.0.1" if host == "kismet.test" else host, *a, **kw)
server = FakeKismet(websocket=True)
proxy = ConnectProxy(server.port)
try:
    # KISMET.TEST and test went through the proxy as websocket-client read them (1.9, and 1.7 and 1.8); a proxy
    # that cannot be read stops no connection that does not use it
    for host, env, through in (
            ("kismet.test", {"http_proxy": "http://127.0.0.1:%d" % proxy.port}, True),
            ("kismet.test", {"http_proxy": "http://127.0.0.1:%d" % proxy.port, "no_proxy": ".test"}, False),
            ("kismet.test", {"http_proxy": "http://127.0.0.1:%d" % proxy.port, "no_proxy": "KISMET.TEST"}, False),
            ("kismet.test", {"http_proxy": "http://127.0.0.1:%d" % proxy.port, "no_proxy": "test"}, False),
            ("127.0.0.1", {"http_proxy": "http://127.0.0.1:%d" % proxy.port}, False),
            ("127.0.0.1", {"http_proxy": "http://127.0.0.1:%d" % proxy.port, "no_proxy": "kismet.lan"}, False),
            ("localhost", {"http_proxy": "http://127.0.0.1:%d" % proxy.port, "no_proxy": "localhost"}, False),
            ("127.0.0.1", {"http_proxy": "http://127.0.0.1:31x8"}, False)):
        served = queue.Queue()
        threading.Thread(target=lambda: served.put(server.accept()), daemon=True).start()
        before = len(proxy.requests)
        with helper_log(logging.INFO) as said:
            transport = remote.make_connector(ws_args(apikey="k3y"), host, server.port, env)()
        sess = served.get(timeout=10)
        asked = proxy.requests[before:]
        check("WS, %s, http_proxy %s and no_proxy %s: %s (%s)" % (
                  host, env["http_proxy"].rpartition(":")[2], env.get("no_proxy", "not set"),
                  "through the proxy" if through else "direct", asked),
              asked == (["CONNECT kismet.test:%d HTTP/1.1" % server.port] if through else []) and
              sess.headers.get("cookie") == "KISMET=k3y" and
              sess.headers.get("host") == "%s:%d" % (host, server.port) and
              said == (["the websocket to kismet.test goes through the HTTP proxy in http_proxy (127.0.0.1:%d)" %
                        proxy.port] if through else []))
        transport.close()
        sess.close()
finally:
    socket.getaddrinfo = real_getaddrinfo
    proxy.close()

# --- wss to localhost, with a certificate made out to the name localhost, as a local Kismet's would be ---


def localhost_certificate(where):
    """A self-signed certificate for DNS:localhost alone, and its key, made with openssl; None without it."""
    tool = shutil.which("openssl")
    if tool is None:
        return None
    cert, key, conf = (os.path.join(where, name) for name in ("cert.pem", "key.pem", "req.cnf"))
    with open(conf, "w") as f:
        f.write("[req]\ndistinguished_name = dn\n[dn]\n")  # so that no system openssl.cnf is needed
    r = subprocess.run([tool, "req", "-x509", "-config", conf, "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                        "-out", cert, "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return (cert, key) if r.returncode == 0 and os.path.exists(cert) else None


cert_dir = tempfile.mkdtemp()
atexit.register(shutil.rmtree, cert_dir, True)
pair = localhost_certificate(cert_dir)
if pair is None:
    print("SKIP wss to localhost with a certificate for localhost (no openssl to make one)")
else:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(*pair)
    server = FakeKismet(websocket=True, tls=ctx)
    served = queue.Queue()

    def serve_one():
        try:
            served.put(server.accept())
        except Exception as e:  # the helper refused the certificate
            served.put(e)

    threading.Thread(target=serve_one, daemon=True).start()
    args = ws_args(ssl=True, ssl_certificate=pair[0])
    try:
        transport = remote.make_connector(args, "localhost", server.port)()
    except Exception as e:
        transport = e
    sess = served.get(timeout=10)
    check("WSS: --connect localhost checks Kismet's certificate against localhost, not 127.0.0.1 (%s)" % transport,
          isinstance(transport, remote.WsTransport) and isinstance(sess, FakeSession) and
          sess.sock.getpeername()[0] == "127.0.0.1" and sess.headers.get("host") == "localhost:%d" % server.port)
    if isinstance(transport, remote.WsTransport):
        transport.close()
    if isinstance(sess, FakeSession):
        sess.close()
    threading.Thread(target=serve_one, daemon=True).start()
    e = raises(OSError, remote.make_connector(args, "127.0.0.1", server.port))
    served.get(timeout=10)
    check("... and the check is still made: the same certificate is no good for 127.0.0.1 (%s)" % e,
          isinstance(e, ssl.SSLCertVerificationError))

# --- A board that never syncs: ERROR, SHUTDOWN, close, and offer the source again ---

remote.SYNC_TIMEOUT_S = 1.0
fake = FakeBoard(bd.LINKTYPE_IEEE802_11_RADIOTAP, RADIOTAP, answer=False)
server = FakeKismet(websocket=False)
DEF = "esp32c5-COM14:mode=wifi"
rs = remote.RemoteSource(DEF, lambda: remote.TcpTransport("127.0.0.1", server.port), claims=remote.PortClaims())
rs.start()
sess = server.accept()
sess.expect(kv3.KDS_NEWSOURCE)
sess.send(kv3.KDS_OPENREQ, {1: DEF})
check("silent board: opened", sess.expect(kv3.KDS_OPENREPORT).code == 1)
err = sess.expect(kv3.CMD_ERROR, timeout=5)
check("silent board: ERROR as cf_send_error sends it, in the C helper's words, with what the board last said (%s)" %
      err.fields[1],
      err.code == 1 and err.seqno == 0 and err.fields[1] == "esp32c5-COM14: no capture from the board on COM14 for 1 "
      "seconds (last: esp32c5-COM14: COM14 opened); is it flashed with the esp32c5 sniffer firmware, and is nothing "
      "else holding the port?")
check("silent board: SHUTDOWN with the reason, which Kismet acts on",
      sess.expect(kv3.CMD_SHUTDOWN).fields == {1: err.fields[1]})
check("silent board: the connection is closed", sess.closed())
sess.close()
sess = server.accept()
check("silent board: the source is offered again", sess.expect(kv3.KDS_NEWSOURCE).fields[1] == DEF)
rs.stop()
sess.close()
rs.join(5)
check("silent board: stops cleanly", not rs.is_alive())

# --- A board that was capturing and is unplugged: given up the same way, as it is not capturing any more ---

fake = FakeBoard(bd.LINKTYPE_IEEE802_11_RADIOTAP, RADIOTAP)
server = FakeKismet(websocket=False)
rs = remote.RemoteSource(DEF, lambda: remote.TcpTransport("127.0.0.1", server.port), claims=remote.PortClaims())
rs.start()
sess = server.accept()
sess.expect(kv3.KDS_NEWSOURCE)
sess.send(kv3.KDS_OPENREQ, {1: DEF})
check("unplugged board: opened, and capturing", sess.expect(kv3.KDS_OPENREPORT).code == 1 and
      sess.expect(kv3.KDS_PACKET).pkt_type == kv3.KDS_PACKET)
with fake.lock:
    fake.gone = True
try:
    err = sess.expect(kv3.CMD_ERROR, timeout=remote.SYNC_TIMEOUT_S + 4)
except queue.Empty:
    err = None
check("unplugged board: ERROR, it has not been capturing since (%s)" % (err.fields[1] if err else "none"),
      err is not None and err.fields[1].startswith("esp32c5-COM14: no capture from the board on COM14 for 1 seconds "
                                                   "(last: esp32c5-COM14: ") and
      sess.expect(kv3.CMD_SHUTDOWN).fields == {1: err.fields[1]})
rs.stop()
sess.close()
rs.join(5)
check("unplugged board: stops cleanly", not rs.is_alive())

print("ALL OK")
