"""The Python remote helper: feed ESP32-C5 sniffer boards to a Kismet server running elsewhere, over Kismet's
remote capture protocol.

For boards plugged into one machine (a Windows PC, say) while Kismet runs on another, or in WSL or Docker:

    python -m esp32c5_kismet.remote --list
    python -m esp32c5_kismet.remote --connect 192.168.1.20:2501 --apikey KEY --source esp32c5zigbee-COM14

It runs from the repository root with the packages in requirements.txt; --help lists every option. The
Kismet server has to know the esp32c5 source type (Kismet built with kismet/add-to-kismet.sh, or the
project's Docker image). The wiki pages Command-Line-Reference, Source-Definitions and Remote-Capture have
the details: https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Command-Line-Reference

Each --source is one board on one radio with its own connection to Kismet. A definition reads

    esp32c5-COM14, esp32c5zigbee-COM14, esp32c5btle-ttyACM0        the radio and the port in the name
    esp32c5[anything]:device=<port>,mode=<wifi|zigbee|btle>         or said outright
    esp32c5, esp32c5zigbee, esp32c5btle                             the only board plugged in

followed by options after a ':' (comma separated): mode=, device=, name=, uuid=, dwell=<ms> and
channel=<n>. The radio is mode= when it is given, otherwise the word between "esp32c5" and the first '-':
zigbee (802154, 802.15.4, thread), btle (ble, bluetooth) or wifi; anything else, or nothing, is Wi-Fi. The
port follows the first '-': COM14 on Windows, in any case; elsewhere a name serial ports have under /dev --
tty*, cu.*, cua*, dty* or pts/N, ttyACM0 for /dev/ttyACM0 -- taken as written, whether or not it is there
right now: a port that is not there is waited for, not swapped for another board. Any other name, such as
esp32c5-kitchen, is only a name, and whatever /dev holds by it is left alone. device= may be left out when
the name gives the port or when exactly one board is plugged in; a definition without a port then keeps to
the board it found first, by its MAC. channel= is the channel to start on, and with channel_hop=false the
one to stay on. dwell= is checked and then has no effect, as the board is only ever given one channel.
Bluetooth LE scans the three advertising channels together, so any of 37, 38 and 39 is accepted and
reported to Kismet as 37 -- at open, when Kismet sets a channel and in a hop list -- and any other is
refused. A channel Kismet sets that the radio does not have is refused the way the C helper and Kismet's
own helpers refuse one: the capture goes on where it was, Kismet is answered with that channel, not with a
failure (on which it would put the source in error and close it), and the reason goes to Kismet as an
error message, which it logs. Kismet's other options (channels=, channel_hop= ...) are Kismet's business;
channel_hop= is read as well, only to tell Kismet that a source it will not hop does not hop. A value that
holds commas goes in double quotes, channels="1,6,11", or Kismet reads only its first item. These are the
names and rules of kismet_cap_esp32c5, the C helper.

A board captures with one radio at a time, so a port belongs to one source: two definitions for one
port, or two that name no port, are refused at startup, and the port is held exclusively while it is in
use -- the same lock the C helper takes (board.open_serial: a flock on the device node, and the tty's
exclusive mode, not on a Linux pseudo-terminal, which also holds between a container and the host; Windows
opens a COM port for one process only), so the two helpers keep out of each other's way as well. On Linux
a source whose port another process holds (board.port_locked: a capture from either helper, Kismet's own
esp32c5 source included) is not offered to Kismet at all, and looked at again every 5 s while the other
sources go on. Offered anyway, it could only fail to open -- or, under the uuid of a source Kismet has
running (the same board and radio), make Kismet close that one. --list leaves such a board out, all
three of its names, as the C helper's --list does.

Kismet does not hop a remote source itself: it hands the helper a channel list and a rate, and the helper
retunes the board on its own timer, as capture_framework.c does for the C capture tools.

Every packet carries its frequency in the signal block, as the C helper sends it: from the radiotap header's
Channel field for Wi-Fi (the firmware always writes one; a header without it gets no signal block), from
the TAP header's channel for 802.15.4, and 2402 MHz (channel 37) for Bluetooth LE.

Only a stop ends a source. Whatever else goes wrong -- Kismet down or restarting, no PING from it for 15 s,
the board not plugged in, a board that has not been capturing for 15 s -- is logged, and the source is
offered again 5 s later, under the same uuid, so Kismet takes it for the source it had. A board is
capturing once it answers with the PCAP header of the radio asked for; a board whose firmware lacks that
radio answers in another link type, which is lost sync, said once. What the board does goes to Kismet as
messages in the C helper's words, each starting with the source's name, as "<name> capturing (<radio>)"
and "<name>: lost sync (...)".

The Kismet login may come from the environment instead of the command line, where every user of the
machine can read it: KISMET_CAP_APIKEY, or KISMET_CAP_USER and KISMET_CAP_PASSWORD, when the command line
has none of --user, --password and --apikey; KISMET_CAP_PASSWORD with --user alone, KISMET_CAP_USER with
--password alone. None of them is read with --tcp, which has no login. A login goes to Kismet in an HTTP
Authorization header (Basic), which Kismet takes as it is, '&' and all -- in the websocket's address it
decodes the login and then cuts it at every '&'. Only a user name that holds ':', where Basic ends a user
name, goes in the address; with an '&' anywhere in the login as well it cannot log in either way, and the
helper warns about it once, at startup. An API key goes in a cookie, KISMET=<key>, which Kismet reads
before anything else. So no secret is in the address, which proxies and their access logs keep, but the
login of a user name that holds ':'. A redirect is not followed, as the login would go along to wherever it
points; Kismet never answers the websocket with one.

The websocket goes through the HTTP proxy the environment names, as websocket-client reads it: https_proxy
with --ssl, http_proxy without (or the same in capitals). Not to a host that no_proxy (or NO_PROXY) covers,
read much as curl reads it, and never to a loopback address: localhost, 127.0.0.0/8 or ::1. --tcp never
goes through a proxy.

Ctrl+C, Ctrl+Break (Windows) or SIGTERM stop the helper, with exit status 0. It is 1 when --list lists no
board (none plugged in, or every one in use) and after an internal error -- every source thread dead, or a
traceback; a source never ends by itself -- and 2 for a mistake on the command line or in a definition, or
a proxy in the environment that the websocket would go through and that cannot be read.
"""

import argparse
import base64
import collections
import errno
import http.client
import ipaddress
import logging
import math
import os
import re
import signal
import socket
import struct
import sys
import threading
import time
from urllib.parse import quote, unquote, urlsplit

from . import __version__
from . import board as bd
from . import kismet_v3 as kv3

log = logging.getLogger("esp32c5_kismet.remote")

SOURCE_TYPE = "esp32c5"
HELPER_VERSION = "esp32c5_kismet-%s" % __version__
WS_ENDPOINT = "/datasource/remote/remotesource.ws"
LEGACY_TCP_PORT = 3501

# Kismet's names for the three radios, and what a definition may call them
MODE_ALIASES = {"wifi": "wifi", "zigbee": "zigbee", "802154": "zigbee", "802.15.4": "zigbee", "thread": "zigbee",
                "btle": "btle", "ble": "btle", "bluetooth": "btle"}
MODE_NAME_WORD = {"wifi": "", "zigbee": "zigbee", "btle": "btle"}  # esp32c5<word>-<port>, as --list names them
BOARD_MODE = {"wifi": bd.MODE_WIFI, "zigbee": bd.MODE_154, "btle": bd.MODE_BLE}
UUID_MODE_DIGIT = {"wifi": 1, "zigbee": 2, "btle": 3}
INITIAL_CHANNEL = {"wifi": 6, "zigbee": 15, "btle": 37}
# Bluetooth LE: the controller scans 37, 38 and 39 together, and the firmware labels every packet 37
BTLE_CHANNEL = "37"
BTLE_FREQ_KHZ = 2402000

LINKTYPE_IEEE802_15_4_NOFCS = 230
KISMET_DLT = {"wifi": bd.LINKTYPE_IEEE802_11_RADIOTAP, "zigbee": LINKTYPE_IEEE802_15_4_NOFCS,
              "btle": bd.LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR}

DEFAULT_DWELL_MS = 250     # only used if the board is given several channels, which this helper never does
SYNC_TIMEOUT_S = 15.0      # a board that has not been capturing for this long takes its source down
PING_TIMEOUT_S = 15.0      # capture_framework.c gives up on a server that has not pinged for this long,
RECONNECT_BACKOFF_S = 5.0  # and waits this long before offering the source again
SOCKET_TIMEOUT_S = 30.0    # longer than anything legitimate: Kismet pings every 5 s
FIRST_OPEN_WAIT_S = 2.0    # how long an OPENREQ waits for the board's port to be tried
STATUS_REPEAT_S = 10.0     # the same board error goes to Kismet at most this often
HOP_MIN_INTERVAL_US = 50000
HOP_SHUFFLE_SPACING = 4    # what capture_linux_wifi.c and the other hopping C tools set at startup


# ----------------------------------------------------------------------------------------------
# Source definitions
# ----------------------------------------------------------------------------------------------

class DefinitionError(ValueError):
    """The definition itself is wrong; trying again will not help."""


class BoardNotFound(DefinitionError):
    """No port to open yet; plugging a board in may fix that."""


class PortTaken(DefinitionError):
    """Another source of this helper has the port; it keeps it."""


def _pieces(text):
    """Split at the commas outside double quotes, keeping the quotes."""
    out, cur, quoted = [], [], False
    for c in text:
        if c == '"':
            quoted = not quoted
        if c == "," and not quoted:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return out


_REPEATED = object()  # the option a piece continues is a repeat, whose value is not used


def _split(definition):
    """split_definition(), and what is odd in how the definition is written: the pieces without a value
    that come before the first option, and the options whose value took in pieces after an unquoted comma."""
    interface, _, rest = definition.partition(":")
    flags, key = {}, None  # key: the option the last piece set, which a piece without '=' continues
    stray, joined = [], []
    pieces = _pieces(rest) if rest else []
    if pieces and not pieces[-1]:
        pieces.pop()  # a trailing comma
    for piece in pieces:
        name, eq, value = piece.partition("=")
        if eq:
            key = name.strip().lower()
            if key in flags:
                key = _REPEATED  # the first one wins, and nothing is added to it
            else:
                flags[key] = value
        elif key is None:
            stray.append(piece.strip())
        elif key is not _REPEATED:
            flags[key] += "," + piece
            if key not in joined:
                joined.append(key)
    return interface.strip(), {k: v.replace('"', "").strip() for k, v in flags.items()}, stray, joined


def split_definition(definition):
    """'iface:key=value,key="a,b"' -> ('iface', {'key': ...}).

    Read the way Kismet reads it (string_to_opts() in its util.cc): a comma inside double quotes does not
    separate options, and the quotes themselves are dropped, wherever they are in a value. Kismet sends a
    definition back in OPENREQ in its own rewrite, keys sorted and every value unquoted, so a quoted list
    comes back as channels=1,6,11,mode=zigbee. A piece without '=' therefore continues the value before
    it; it is not an option of its own. Keys are case-insensitive and the first of a repeated key wins, as
    capture_framework.c's cf_find_flag() reads them.

    A piece without '=' before the first option belongs to none and is passed over, as cf_find_flag()
    passes over it. Kismet sends such pieces when the user left a list unquoted: it reads
    channels=1,6,11,mode=zigbee as channels=1 and an option named "6,11,mode", and its rewrite, sorted,
    is 6,11,mode=zigbee,channels=1 -- mode=zigbee to both helpers. check_sources() tells the user.
    """
    return _split(definition)[:2]


# What the helper takes from a definition. The other options are Kismet's, channels= for one.
SOURCE_OPTIONS = ("device", "mode", "name", "uuid", "dwell", "channel", "channel_hop")


def same_definition(a, b):
    """Do two definitions mean the same source, however they are written? Kismet's rewrite of one does.

    Only the name and the options the helper reads are compared. One it leaves to Kismet can come back
    changed -- an unquoted channels=1,6,11 comes back as channels=1 -- and that is no other source."""
    (ia, fa), (ib, fb) = split_definition(a), split_definition(b)
    return ia == ib and all(fa.get(k) == fb.get(k) for k in SOURCE_OPTIONS)


def device_from_interface(interface, platform=None):
    """The port the name gives: what follows the first '-', as in esp32c5-COM14 and esp32c5zigbee-COM14 on
    Windows, or esp32c5btle-ttyACM0 (/dev/ttyACM0) elsewhere.

    Elsewhere only a name serial ports have under /dev counts: tty* (Linux ttyACM and ttyUSB, macOS tty.*,
    BSD ttyU), cu.* (macOS), cua* (FreeBSD and OpenBSD cuaU), dty* (NetBSD dtyU) or pts/N (a pseudo-
    terminal, the fake board), and none that climbs out of /dev with "..". serial_name() in the C helper.
    Any other name, such as esp32c5-kitchen, is only a name for the source, and whatever /dev holds by it
    -- watchdog, which reboots the machine when it is opened and not closed properly, or serial1, the
    Raspberry Pi's Bluetooth UART -- is never opened for it. The name counts as written, not whether it
    exists right now, so a board that is rebooting is waited for rather than swapped for another."""
    if not interface.startswith(SOURCE_TYPE):
        return None
    _, dash, name = interface.partition("-")
    if not dash or not name:
        return None
    if (platform or sys.platform) == "win32":
        m = re.fullmatch(r"(?i)com(\d+)", name)
        return "COM%d" % int(m.group(1)) if m else None
    if ".." in name or not name.startswith(("tty", "cu.", "cua", "dty", "pts/")):
        return None
    return "/dev/" + name


def named_port(interface, flags, platform=None):
    """The port a definition names, device= or the name's, in the spelling it is opened by; None if none.
    On Windows com14 and \\\\.\\COM14 are written COM14."""
    device = flags.get("device") or device_from_interface(interface, platform)
    if not device:
        return None
    if (platform or sys.platform) == "win32":
        m = re.fullmatch(r"(?i)(?:\\\\\.\\)?com(\d+)", device.strip())
        if m:
            return "COM%d" % int(m.group(1))
    return device


def mode_of(interface, flags):
    """mode= when it is there, otherwise the name: esp32c5zigbee-COM14 is 802.15.4, esp32c5-COM14 and
    esp32c5-kitchen are Wi-Fi."""
    word = flags.get("mode", "").strip()
    if word:
        mode = MODE_ALIASES.get(word.lower())
        if mode is None:
            raise DefinitionError("unknown mode %r: use wifi, zigbee (802154, 802.15.4, thread) "
                                  "or btle (ble, bluetooth)" % word)
        return mode
    word = interface[len(SOURCE_TYPE):].partition("-")[0]
    return MODE_ALIASES.get(word.lower(), "wifi")


def short_definition(device, mode, platform=None):
    """The shortest definition that opens this port in this mode, as --list prints it."""
    interface = "esp32c5%s-%s" % (MODE_NAME_WORD[mode], device.replace("\\", "/").rsplit("/", 1)[-1])
    if device_from_interface(interface, platform) == device:
        return interface
    return "esp32c5:device=%s,mode=%s" % (device, mode)


def fnv1a48(text):
    """64-bit FNV-1a over the UTF-8 bytes, low 48 bits, as 12 upper-case hex digits."""
    h = 0xCBF29CE484222325
    for b in text.encode("utf-8"):
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%012X" % (h & 0xFFFFFFFFFFFF)


def default_uuid(mode, mac, device):
    """E5C5000M-0000-0000-0000-<MAC>: stable per board and radio, so Kismet recognises a source it has seen.
    Without a MAC the port stands in, hashed. make_uuid() in the C helper, so both give a board the same."""
    tail = mac.replace(":", "").upper() if mac else fnv1a48(device)
    return "E5C5000%d-0000-0000-0000-%s" % (UUID_MODE_DIGIT[mode], tail)


def hardware_name(mac):
    """What the USB ID and serial number say, which is an Espressif USB-Serial-JTAG device, not which chip."""
    return "Espressif USB-Serial-JTAG (%s)" % mac if mac else "ESP32-C5"


class Source:
    """A definition resolved to a port and a radio."""

    def __init__(self, definition, interface, device, mode, dwell_ms, uuid, mac, channel=None, hopping=True,
                 name=None, key=None, explicit_uuid=False, platform=None):
        self.definition = definition
        self.interface = interface
        self.name = name or interface
        self.device = device
        self.key = key if key is not None else bd.port_key(device, platform)  # the port, for comparing
        self.mode = mode
        self.dwell_ms = dwell_ms
        self.uuid = uuid
        self.mac = mac
        self.explicit_uuid = explicit_uuid
        self.board_mode = BOARD_MODE[mode]
        self.dlt = KISMET_DLT[mode]
        self.initial_channel = INITIAL_CHANNEL[mode] if channel is None else channel
        self.hopping = hopping  # False for channel_hop=false: Kismet will never send a hop list
        # Bluetooth LE reports 37 alone: the controller scans 37, 38 and 39 together and cannot be restricted
        self.channels = [str(c) for c in bd.all_channels(self.board_mode)]
        self.hardware = hardware_name(mac)

    def adopt(self, mac, uuid):
        """Take on an identity found before (see RemoteSource.resolve)."""
        self.mac, self.uuid, self.hardware = mac, uuid, hardware_name(mac)


def parse_definition(definition, boards=None, platform=None, exists=None, pinned_mac=None):
    """Resolve a --source definition. The port is device= if given, else the one the name gives, else the
    board with pinned_mac, else the only board plugged in.

    boards defaults to the boards plugged in now. exists(device) says whether a port the definition names
    is there; it defaults to bd.port_exists when boards is not given, and to not asking when it is, so a
    test that hands in its boards does not depend on the ports of the machine it runs on. A named port
    that is not there is BoardNotFound (unless uuid= is given): offered to Kismet it could only have a
    made-up identity, and Kismet would count it as another source once the board is back.
    """
    interface, flags = split_definition(definition)
    if not interface.startswith(SOURCE_TYPE):
        raise DefinitionError("the interface must start with %s, not %r" % (SOURCE_TYPE, interface))
    mode = mode_of(interface, flags)
    try:
        dwell = int(flags.get("dwell", DEFAULT_DWELL_MS))
    except ValueError:
        raise DefinitionError("dwell=%s is not a number of milliseconds" % flags["dwell"])
    if not bd.MIN_DWELL_MS <= dwell <= bd.MAX_DWELL_MS:
        raise DefinitionError("dwell must be between %d and %d ms" % (bd.MIN_DWELL_MS, bd.MAX_DWELL_MS))

    # channel= is where to start, and with channel_hop=false where to stay: Kismet only adds it to the
    # channel list and never tunes a source to it. Checked before any port is looked at.
    channel = INITIAL_CHANNEL[mode]
    text = flags.get("channel", "")
    if text:
        ok = re.fullmatch(r"[0-9]+", text) is not None and int(text) <= 177
        if ok:
            # BTLE scans the three advertising channels together: any of them is 37
            ok = 37 <= int(text) <= 39 if mode == "btle" else bd.channel_is_valid(int(text), BOARD_MODE[mode])
        if not ok:
            raise DefinitionError("%s: channel=%s is not a channel the board can tune to in %s mode"
                                  % (interface, text, mode))
        if mode != "btle":
            channel = int(text)
    # Kismet's own reading of the option (string_to_bool: "false" or "f", in any case)
    hopping = flags.get("channel_hop", "").lower() not in ("false", "f")

    device = named_port(interface, flags, platform)
    if device:
        if exists is None and boards is None:
            exists = lambda d: bd.port_exists(d, platform)  # noqa: E731
        if exists is not None and not flags.get("uuid") and not exists(device):
            raise BoardNotFound("%s is not there; is the board plugged in? (waiting for it)" % device)
        boards = bd.find_boards() if boards is None else boards
    else:
        boards = bd.find_boards() if boards is None else boards
        if pinned_mac:
            # this definition has found its board before: that board, wherever it is now
            device = bd.find_port_by_mac(pinned_mac, boards)
            if device is None:
                raise BoardNotFound("the board %s is not plugged in (waiting for it)" % pinned_mac)
        elif len(boards) == 1:
            device = boards[0].device
        elif not boards:
            raise BoardNotFound("no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board "
                                "in, or give device= in the source definition")
        else:
            raise BoardNotFound("%d Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found (%s), and every "
                                "ESP32 on native USB has that ID; say which one with device= or a source name "
                                "like %s" % (len(boards), ", ".join(p.device for p in boards),
                                             short_definition(boards[0].device, mode, platform)))
    mac = bd.mac_of_port(device, boards, platform)
    uuid = flags.get("uuid") or default_uuid(mode, mac, device)
    return Source(definition, interface, device, mode, dwell, uuid, mac, channel=channel, hopping=hopping,
                  name=flags.get("name"), explicit_uuid=bool(flags.get("uuid")), platform=platform)


def check_sources(definitions, boards=None, platform=None, exists=None):
    """One board, one source: refuse definitions that want the same port, before anything starts.

    Ports are compared however they are written (com14 and COM14, a by-id link and its ttyACM). Two
    definitions that name no port could only ever take the same single board, so they are refused whether
    or not a board is plugged in. Raises DefinitionError; a board that is not there yet is only a warning.

    This is also where the user hears about a definition Kismet reads otherwise than meant. A piece with
    no value before the first option means nothing to anyone and is refused. A comma list that is not in
    double quotes is a warning only, as the C helper takes it too: Kismet keeps its first item (with
    channels=, the only channel it will hop) and makes an option of the rest, which the helpers pass over.
    """
    named = {}
    for definition in definitions:
        interface, flags, stray, joined = _split(definition)
        if stray:
            raise DefinitionError("%s: option %r has no value" % (definition, stray[0]))
        for key in joined:
            log.warning('%s: the comma list in %s= is not in double quotes, so Kismet reads only its first item '
                        'and takes the rest for another option; write %s="%s"', definition, key, key, flags[key])
        named[definition] = named_port(interface, flags, platform)
    portless = [d for d in definitions if not named[d]]
    if len(portless) > 1:
        raise DefinitionError("%s and %s name no port, so both would take the same board; say which with "
                              "device= or a source name like esp32c5-<port>" % (portless[0], portless[1]))
    ports = {}
    for definition in definitions:
        try:
            src = parse_definition(definition, boards, platform, exists)
        except BoardNotFound as e:
            # a port that is not there says already that it is waited for
            text = str(e)
            log.warning("%s: %s%s", definition, text,
                        "" if text.endswith("(waiting for it)") else " (will keep looking)")
            src = None
        except DefinitionError as e:
            raise DefinitionError("%s: %s" % (definition, e))
        device = src.device if src is not None else named[definition]
        if device is None:
            continue
        key = src.key if src is not None else bd.port_key(device, platform)
        if key in ports:
            raise DefinitionError("%s and %s both want %s" % (ports[key], definition, device))
        ports[key] = definition


# ----------------------------------------------------------------------------------------------
# 802.15.4: the board's TAP header in, plain frames and a signal block out
# ----------------------------------------------------------------------------------------------

TAP_TLV_RSS, TAP_TLV_CHANNEL = 1, 3


def rewrap_tap(record):
    """Split an 802.15.4 TAP record (link type 283) into (MAC frame, channel, RSS dBm or None, header length).

    Kismet's TAP parser assumes a fixed 28 byte header and would misread the board's, so the frame goes to
    Kismet as 802.15.4 without FCS and the two TLVs it needs go into the signal block. The header's own
    length is used, never an assumed one. Returns None when the header does not hold together.
    """
    if len(record) < 4:
        return None
    version, _, hdr_len = struct.unpack_from("<BBH", record)
    # the length counts the 4 byte preamble and covers whole padded TLVs, and a frame has to follow
    if version != 0 or hdr_len < 4 or hdr_len % 4 or hdr_len >= len(record):
        return None
    channel = rss = None
    pos = 4
    while pos < hdr_len:
        tlv_type, tlv_len = struct.unpack_from("<HH", record, pos)
        value, pos = pos + 4, pos + 4 + (tlv_len + 3) // 4 * 4
        if pos > hdr_len:
            return None
        if tlv_type == TAP_TLV_RSS:
            if tlv_len != 4:
                return None
            rss = struct.unpack_from("<f", record, value)[0]
            if not math.isfinite(rss):
                return None
        elif tlv_type == TAP_TLV_CHANNEL:
            if tlv_len != 3:  # u16 channel, u8 page
                return None
            channel = struct.unpack_from("<H", record, value)[0]
    if channel is None or not 11 <= channel <= 26:
        return None
    return record[hdr_len:], channel, rss, hdr_len


def zigbee_freq_khz(channel):
    return (2405 + 5 * (channel - 11)) * 1000


def c_round(x):
    """Half away from zero, like C's round(), which the C helper uses; Python's round() goes to even."""
    return int(math.copysign(math.floor(abs(x) + 0.5), x))


# ----------------------------------------------------------------------------------------------
# Wi-Fi: the frequency in the radiotap header
# ----------------------------------------------------------------------------------------------

RADIOTAP_TSFT, RADIOTAP_FLAGS, RADIOTAP_RATE, RADIOTAP_CHANNEL, RADIOTAP_EXT = 0, 1, 2, 3, 31


def radiotap_freq_khz(record):
    """The frequency of the Channel field of a radiotap header, in kHz; 0 when there is none.

    The firmware writes Flags, Channel, antenna signal and noise, but the header is read by its own
    presence bits: the fields before Channel (TSFT, 8 bytes aligned to 8 from the header's start; Flags and
    Rate, a byte each) are stepped over, as are the further presence words that bit 31 announces. Kismet
    reads the same field itself; the signal block carries it too, as it does for the other radios.
    """
    if len(record) < 8:
        return 0
    version, _, length, present = struct.unpack_from("<BBHI", record)
    if version != 0 or not 8 <= length <= len(record) or not present & (1 << RADIOTAP_CHANNEL):
        return 0
    pos, word = 8, present
    while word & (1 << RADIOTAP_EXT):
        if pos + 4 > length:
            return 0
        word = struct.unpack_from("<I", record, pos)[0]
        pos += 4
    if present & (1 << RADIOTAP_TSFT):
        pos = (pos + 7) // 8 * 8 + 8
    pos += bool(present & (1 << RADIOTAP_FLAGS)) + bool(present & (1 << RADIOTAP_RATE))
    pos += pos % 2  # frequency and flags, two u16
    if pos + 4 > length:
        return 0
    return struct.unpack_from("<H", record, pos)[0] * 1000


# ----------------------------------------------------------------------------------------------
# Bluetooth LE: the CRC flags Kismet needs
# ----------------------------------------------------------------------------------------------

# LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR: a 10 byte pseudo-header (flags at offset 8), the 4 byte access
# address, the PDU (2 byte header and up to 255 bytes), the 3 byte CRC
BTLE_PHDR_LEN, BTLE_AA_LEN, BTLE_CRC_LEN = 10, 4, 3
BTLE_MIN_RECORD = BTLE_PHDR_LEN + BTLE_AA_LEN + 2 + BTLE_CRC_LEN
BTLE_MAX_RECORD = BTLE_PHDR_LEN + BTLE_AA_LEN + 2 + 255 + BTLE_CRC_LEN
BTLE_FLAG_CRC_CHECKED, BTLE_FLAG_CRC_VALID = 0x0400, 0x0800


def btle_adv_crc(pdu):
    """The advertising channel CRC: 24 bits, x^24+x^10+x^9+x^6+x^4+x^3+x+1, shifted in least significant bit
    first from 0x555555, which is 0xAAAAAA in this reflected register. The firmware's, and the C helper's."""
    state = 0xAAAAAA
    for cur in pdu:
        for _ in range(8):
            feedback = (state ^ cur) & 1
            cur >>= 1
            state >>= 1
            if feedback:
                state |= 1 << 23
                state ^= 0x5A6000
    return state


def fix_btle(record):
    """A BTLE record as Kismet takes it: (record, whether it was changed), or None when it is too short
    (or, needing the fix, too long) to be one.

    Kismet trusts the CRC only when the pseudo-header says it was checked; otherwise it checks the CRC
    itself -- against another initial value -- and drops the packet. This firmware sets "CRC checked" and
    "CRC valid" and writes the CRC, since the controller reports only advertising packets whose CRC passed.
    Older firmware (the published esp32c5-wireshark-sniffer builds) leaves both flags clear and the CRC
    zeroed. Such a record gets the CRC of its PDU in its last three bytes and the two flags, which is what
    newer firmware sends. A record that says it was checked is left as it is, whatever it says of the CRC.
    """
    if len(record) < BTLE_MIN_RECORD:
        return None
    flags = struct.unpack_from("<H", record, 8)[0]
    if flags & BTLE_FLAG_CRC_CHECKED:
        return record, False
    if len(record) > BTLE_MAX_RECORD:
        return None
    fixed = bytearray(record)
    crc = btle_adv_crc(fixed[BTLE_PHDR_LEN + BTLE_AA_LEN:-BTLE_CRC_LEN])
    fixed[-3:] = struct.pack("<I", crc)[:3]
    struct.pack_into("<H", fixed, 8, flags | BTLE_FLAG_CRC_CHECKED | BTLE_FLAG_CRC_VALID)
    return bytes(fixed), True


# ----------------------------------------------------------------------------------------------
# Channel hopping
# ----------------------------------------------------------------------------------------------

def channel_number(text):
    """The channel a channel Kismet sets or hops to names, read as the C helper reads it (sscanf "%u" into an
    unsigned int, in its chantranslate_callback): the number it starts with, after any white space and a
    sign, so that Kismet's Wi-Fi name 6HT40 is 6, and a minus wrapped round as C wraps it, which no radio
    has. None when it does not start with a number. channel= in a definition is read strictly instead."""
    m = re.match(r"[ \t\n\v\f\r]*([+-]?)([0-9]+)", text)
    if m is None:
        return None
    number = int(m.group(2))
    return (-number if m.group(1) == "-" else number) & 0xFFFFFFFF


class Hopper(threading.Thread):
    """Walks a hop list the way capture_framework.c's cf_int_chanhop_thread() does, calling tune(channel).

    It sleeps first and tunes after, every 1/rate seconds but never faster than 50 ms. The walk starts at
    the offset Kismet gives (that is how it splits one list among several sources). With shuffle it jumps
    by the skip, and each time it runs off the end it starts one further along, so a skip of 4 visits every
    channel once in four laps. The C restarts that way without shuffle too; that is copied as well.
    """

    def __init__(self, channels, rate, shuffle, skip, offset, tune, wait=None):
        super().__init__(daemon=True)
        skip = max(int(skip), 1)  # the C would divide by zero on 0
        if shuffle and skip >= len(channels):
            skip = 1              # cf_handler_assign_hop_channels()
        self.channels, self.rate, self.shuffle = list(channels), rate, bool(shuffle)
        self.skip, self.offset = skip, offset
        self.pos, self.laps = offset, 0
        self.tune = tune
        self.cancelled = threading.Event()
        self.wait = wait or self.cancelled.wait  # returns True when it is time to stop

    def interval(self):
        # wait_usec = 1000000L / rate, kept as an unsigned int, and at least 50 ms
        return max(min(int(1000000 / self.rate), 0xFFFFFFFF), HOP_MIN_INTERVAL_US) / 1e6

    def next_channel(self):
        n = len(self.channels)
        channel = self.channels[self.pos % n]
        self.pos += self.skip if self.shuffle else 1
        if self.pos >= n:
            self.laps += 1
            self.pos = (self.laps % self.skip) % n
        return channel

    def report(self):
        return {"channels": self.channels, "rate": self.rate, "shuffle": self.shuffle,
                "offset": self.offset, "skip": self.skip}

    def run(self):
        # a rate of 0 means not hopping at all; the C thread exits on it too
        while self.rate > 0 and not self.wait(self.interval()):
            self.tune(self.next_channel())

    def cancel(self):
        self.cancelled.set()


# ----------------------------------------------------------------------------------------------
# Transports: the websocket (default) and the legacy TCP stream
# ----------------------------------------------------------------------------------------------

class TcpTransport:
    """The legacy protocol (--tcp, Kismet's port 3501): frames back to back on a plain TCP stream."""

    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=SOCKET_TIMEOUT_S)
        self.buf = bytearray()

    def send(self, data):
        self.sock.sendall(data)

    def recv(self):
        while True:
            fr, used = kv3.take_frame(self.buf)
            if fr is not None:
                del self.buf[:used]
                return fr
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("Kismet closed the connection")
            self.buf += data

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)  # wakes the reader thread
        except OSError:
            pass
        self.sock.close()


def one_line(text):
    """An exception's text for a log line: its line breaks, and the white space around them, made one space.
    The lines after the first would go out on their own, with no time and no level to them."""
    return re.sub(r"\s*[\r\n]+\s*", " ", text).strip()


def refused_status(e):
    """'401 Unauthorized': the status and reason of a refused handshake (websocket-client's
    WebSocketBadStatusException), never the headers and body its text holds as well. Before 1.9 the reason
    is only in that text, and the standard one stands in for it."""
    reason = getattr(e, "status_message", None) or http.client.responses.get(e.status_code, "")
    return one_line("%s %s" % (e.status_code, reason))


def redirect_shown(location):
    """Where a redirect's Location points, as far as it can be said, and byte for byte as the C helper says it
    (add-to-kismet.sh): up to its query or fragment, which a server that sends every request elsewhere makes
    the request's own, and so the login of a user name with ':'; and with each byte that is not printable
    ASCII, the space included, percent-encoded, as in a URI, since a terminal could take it for part of a
    control sequence. websocket-client decodes the header from UTF-8, so encoding it again gives back the
    bytes the server sent."""
    shown = []
    for c in location.encode("utf-8"):
        if c in b"?#":
            shown.append(chr(c) + "...")
            break
        shown.append(chr(c) if 0x20 < c < 0x7f else "%%%02X" % c)
    return "".join(shown)


class WsTransport:
    """Kismet's websocket endpoint on its web port: one frame per binary message."""

    def __init__(self, url, sslopt=None, host=None, origin=None, authorization=None, cookie=None, proxy=None):
        """host and origin, when given, are the Host and Origin headers instead of the URL's; authorization is
        the Authorization header's value, when the login goes in one, and cookie the Cookie header's, when
        an API key goes in one; proxy, websocket-client's options for an HTTP proxy (make_connector)."""
        import websocket  # imported here so that --list and --tcp work without it
        self.wsmod = websocket
        # The C tools (libwebsockets) ask for the "kismet-remote" subprotocol. Kismet never echoes it, and
        # websocket-client refuses a handshake that drops a subprotocol it was told to ask for, so the header
        # goes in by hand instead of through subprotocols=.
        header = ["Sec-WebSocket-Protocol: kismet-remote"]
        if authorization:
            header.append("Authorization: " + authorization)
        # What create_connection() does, with the WebSocket kept: a redirect's answer is on it
        self.ws = websocket.WebSocket(sslopt=sslopt)
        self.ws.settimeout(SOCKET_TIMEOUT_S)
        try:
            # The cookie through cookie=, not the header list: websocket-client joins it with the cookies a
            # server has set (a proxy in front of Kismet, say) into the one Cookie header a request may have;
            # of two Cookie headers, the proxy or Kismet would read only one.
            # No redirect is followed: Kismet never answers the websocket with one, and websocket-client
            # follows one anywhere, another host or ws:// from wss://, with every header, login and key.
            self.ws.connect(url, host=host, origin=origin, header=header, cookie=cookie, redirect_limit=0,
                            **(proxy or {}))
        except websocket.WebSocketBadStatusException as e:
            # The status alone: the exception's text has Kismet's whole answer in it, its headers and its HTML
            # page, over several lines
            hint = (" (check the login -- --user/--password or KISMET_CAP_USER/KISMET_CAP_PASSWORD -- "
                    "or the API key -- --apikey or KISMET_CAP_APIKEY; the key needs the datasource role)"
                    if e.status_code == 401 else "")
            raise ConnectionError("Kismet refused the websocket: %s%s" % (refused_status(e), hint))
        except websocket.WebSocketException as e:
            # 1.9 and later refuse a redirect themselves, as "Redirect limit exhausted"
            raise ConnectionError(self._redirected() or one_line(str(e)) or type(e).__name__)
        redirected = self._redirected()
        if redirected:
            # before 1.9 a redirect that is not followed passes for a connection
            self.close()
            raise ConnectionError(redirected)

    def _redirected(self):
        """What to say of a redirect the handshake was answered with; None when it was not."""
        answer = self.ws.handshake_response
        if answer is None or not 300 <= answer.status < 400:
            return None
        where = answer.headers.get("location")
        return ("the websocket was answered with a redirect (HTTP %d%s), which the helper does not follow: Kismet "
                "never redirects it, and the login would go along to wherever it points; check --connect, "
                "--endpoint and --ssl" % (answer.status, " to %s" % redirect_shown(where) if where else ""))

    def send(self, data):
        try:
            self.ws.send_binary(data)
        except self.wsmod.WebSocketException as e:
            raise ConnectionError(one_line(str(e)) or type(e).__name__)

    def recv(self):
        try:
            opcode, data = self.ws.recv_data()  # answers websocket-level pings by itself
        except self.wsmod.WebSocketException as e:
            raise ConnectionError(one_line(str(e)) or type(e).__name__)
        if opcode == self.wsmod.ABNF.OPCODE_CLOSE:
            raise ConnectionError("Kismet closed the websocket")
        if opcode != self.wsmod.ABNF.OPCODE_BINARY:
            raise kv3.ProtocolError("unexpected text message on the websocket")
        return kv3.decode(data)

    def close(self):
        # Best effort, each step on its own. websocket-client before 1.9.1 lets abort() raise ENOTCONN on a
        # connection the peer has reset (Linux), and the reader thread can clear ws.sock at the same moment;
        # neither may keep the socket from being closed or end the source.
        for step in (self.ws.abort, self.ws.shutdown):  # abort wakes the reader thread
            try:
                step()
            except Exception:
                pass


# ----------------------------------------------------------------------------------------------
# One connection to Kismet
# ----------------------------------------------------------------------------------------------

class Connection:
    """One connection to Kismet for one source: announce it, open the board when asked, stream until either
    side gives up. A reader thread answers Kismet, the board's own thread sends the packets, and run() keeps
    watch over both."""

    def __init__(self, source, transport, platform=None, resolve=None, clock=None):
        self.source = source
        self.transport = transport
        self.platform = platform
        # how a definition that is not this source's is resolved: RemoteSource.resolve, which knows the board
        self.resolve = resolve or (lambda definition: parse_definition(definition, platform=platform))
        self.clock = clock or time.monotonic
        self.link = None
        self.hopper = None
        self.hop_wait = None   # the hopper's clock, for tests
        self.channel = None    # the channel last set, reported back as capture_framework.c does
        # capture_framework.c keeps these between requests and uses them for whatever Kismet leaves out
        self.hop_settings = {"rate": 0.0, "shuffle": False, "skip": HOP_SHUFFLE_SPACING, "offset": 0}
        self.malformed = 0
        self.dropped_btle = 0
        self.btle_fixups = 0
        self.reason = None
        self.closed = threading.Event()
        self.last_ping = self.clock()
        self.unsynced_since = None
        self._state = None     # the board's last opened / capturing / lost status told to Kismet
        self._errors = {}      # board error or notice text -> [when last told, times since not told]
        self._seqno = 1
        self._seq_lock = threading.Lock()
        self._send_lock = threading.Lock()  # one frame at a time on the wire

    def next_seqno(self):
        # cf_get_next_seqno(): incremented before use, never 0
        with self._seq_lock:
            self._seqno = (self._seqno + 1) & 0xFFFFFFFF or 1
            return self._seqno

    def send(self, data):
        if self.closed.is_set():
            return
        pkt_type = struct.unpack_from("!H", data, 12)[0]
        if pkt_type != kv3.KDS_PACKET:
            log.debug("-> %s, %d bytes", kv3.PACKET_NAMES.get(pkt_type, pkt_type), len(data))
        try:
            with self._send_lock:
                self.transport.send(data)
        except OSError as e:
            self.close("sending to Kismet failed: %s" % e)

    def message(self, text, level=kv3.MSG_INFO):
        self.send(kv3.message(self.next_seqno(), text, level))

    def close(self, reason):
        if not self.closed.is_set():
            self.reason = reason
            self.closed.set()

    def fail(self, reason):
        """Give the source up with a reason, which names the source, and leave it to the reconnect to offer it
        afresh."""
        log.error("%s", reason)
        # What capture_framework.c's cf_send_error() sends. Kismet's v3 server has no handler for it, so the
        # SHUTDOWN after it is what puts the source into error with this reason in Kismet.
        self.send(kv3.error(0, reason))
        self.send(kv3.shutdown(self.next_seqno(), reason))
        self.close(reason)

    def run(self):
        """Serve until the connection ends; returns why it ended. Whatever happens, the board is let go
        and the transport closed on the way out."""
        reader = None
        try:
            self.send(kv3.newsource(self.next_seqno(), self.source.definition, SOURCE_TYPE, self.source.uuid))
            reader = threading.Thread(target=self._read_loop, daemon=True)
            reader.start()
            while not self.closed.wait(0.25):
                self._watchdog()
        finally:
            self.close("internal error")  # only if nothing closed it before, as on an exception
            self._stop_board()
            try:
                self.transport.close()
            except Exception:
                log.debug("closing the transport", exc_info=True)
            if reader is not None:
                reader.join(2)
        return self.reason

    def _read_loop(self):
        try:
            while not self.closed.is_set():
                self.dispatch(self.transport.recv())
        except Exception as e:
            if self.closed.is_set():
                return  # run() closed the transport under it, as intended
            if not isinstance(e, (OSError, kv3.ProtocolError)):
                log.exception("handling a request from Kismet")
            self.close(str(e) or type(e).__name__)

    def _watchdog(self):
        now = self.clock()
        if now - self.last_ping > PING_TIMEOUT_S:
            self.close("no PING from Kismet for %.0f seconds" % PING_TIMEOUT_S)
            return
        link = self.link
        if link is None or link.capturing:
            self.unsynced_since = None
        elif self.unsynced_since is None:
            self.unsynced_since = now
        elif now - self.unsynced_since > SYNC_TIMEOUT_S:
            # The C helper's words, and what the board last said: this reason is what Kismet shows as the
            # source's error (see fail), where the statuses before it are only in its log
            last = " (last: %s)" % link.last_status if link.last_status else ""
            self.fail("%s: no capture from the board on %s for %.0f seconds%s; is it flashed with the esp32c5 "
                      "sniffer firmware, and is nothing else holding the port?"
                      % (self.source.name, self.source.device, SYNC_TIMEOUT_S, last))

    # --- requests from Kismet, in the reader thread ---

    def dispatch(self, fr):
        t = fr.pkt_type
        if t not in (kv3.CMD_PING, kv3.CMD_PONG):
            log.debug("<- %s seqno %d", kv3.PACKET_NAMES.get(t, t), fr.seqno)
        if t == kv3.CMD_PING:
            self.last_ping = self.clock()
            self.send(kv3.pong(fr.seqno))
        elif t == kv3.CMD_PONG:
            pass
        elif t == kv3.KDS_OPENREQ:
            self.open(fr.seqno, kv3.parse_definition(fr))
        elif t == kv3.KDS_CONFIGREQ:
            self.configure(fr.seqno, kv3.parse_configreq(fr))
        elif t == kv3.KDS_PROBEREQ:
            self.probe(fr.seqno, kv3.parse_definition(fr))
        elif t == kv3.CMD_SHUTDOWN:
            self.close("Kismet shut the source down: %s" % kv3.parse_text(fr, kv3.SHUTDOWN_FIELD_REASON))
        elif t == kv3.CMD_MESSAGE:
            log.info("Kismet: %s", one_line(kv3.parse_text(fr, kv3.MESSAGE_FIELD_STRING)))
        elif t == kv3.CMD_ERROR:
            log.error("Kismet: %s", one_line(kv3.parse_text(fr, kv3.ERROR_FIELD_STRING)))
        else:
            # capture_framework.c's answer to anything it does not know
            self.send(kv3.probereport(fr.seqno, False, "Unsupported request"))

    def _resolve(self, definition):
        # Kismet does not send back the definition it was given: it sends its own rewrite of it, the options
        # sorted and unquoted. The same options mean this source, as it was resolved and announced.
        if same_definition(definition, self.source.definition):
            return self.source
        return self.resolve(definition)

    def open(self, seqno, definition):
        try:
            src = self._resolve(definition)
        except DefinitionError as e:
            self.send(kv3.openreport(seqno, False, str(e), 0, HELPER_VERSION))
            self.close("could not open %s: %s" % (definition, e))  # a failed open ends the C tool too
            return
        self._stop_board()  # a second OPENREQ replaces the first
        self.source = src
        self.channel = str(src.initial_channel)
        link = bd.BoardLink(src.device, src.board_mode, [src.initial_channel], src.dwell_ms,
                            self._on_packet, self._on_status, mac=src.mac, name=src.name)
        self.link = link
        log.info("%s: opening %s for %s", src.definition, src.device, src.mode)
        link.start()
        # The answer says whether the port could be opened, as the C helper's open callback does; a port
        # that cannot be is Kismet's error to show, with the reason, rather than a source running on nothing.
        link.first_attempt.wait(FIRST_OPEN_WAIT_S)
        if link.open_error is not None:
            # The reason names the port: pyserial's and the helper's own errors do, and one that does not
            # is said as "could not open <port>: <error>"
            error = reason = str(link.open_error)
            if src.device not in error:
                error = "%s: %s" % (src.device, error)
                reason = "could not open " + error
            self._stop_board()
            self.send(kv3.openreport(seqno, False, error, 0, HELPER_VERSION))
            self.close(reason)
            return
        self.unsynced_since = self.clock()
        self.send(kv3.openreport(seqno, True, "", src.dlt, HELPER_VERSION, src.uuid, src.device, src.hardware,
                                 self.channel, src.channels, hopping=src.hopping))

    def probe(self, seqno, definition):
        try:
            src = self._resolve(definition)
        except DefinitionError as e:
            self.send(kv3.probereport(seqno, False, str(e)))
            return
        self.send(kv3.probereport(seqno, True, "", src.device, src.hardware, str(src.initial_channel),
                                  src.channels))

    def configure(self, seqno, request):
        if request is None:
            return  # neither a channel nor a hop list: capture_framework.c does not answer either
        kind, value = request
        if kind == "channel":
            self._cancel_hop()  # a single channel cancels hopping, one that is refused as well
            number = channel_number(value)
            if number is None:
                # What capture_esp32c5.c's chantranslate_callback says; then nothing is tuned, and the
                # framework answers with the channel the board is on. No message in the answer, as the
                # patched framework (add-to-kismet.sh) leaves an empty one out.
                self._say("unable to parse channel '%s'; esp32c5 channels are plain numbers" % value)
                self.send(kv3.configreport(seqno, True, None, channel=self.channel))
                return
            if not self._tunable(value):
                # Refused as the C helper refuses it (refuse_channel), the way Kismet's own helpers do: the
                # capture goes on where it was, and the answer is that channel with the reason. A failed
                # answer would have Kismet put the source in error and close it, and the helper would offer it
                # again hopping, the channel lost. The answer's text is not logged by Kismet, so the reason
                # goes to it as an error message as well.
                error = "%s cannot tune to channel %d in %s mode" % (self.source.name, number, self.source.mode)
                self._say(error, kv3.MSG_ERROR)
                self.send(kv3.configreport(seqno, True, error, channel=self.channel))
                return
            self._tune(value)
            # Bluetooth LE goes on scanning 37, 38 and 39 together whichever of them is asked for, and 37
            # stands for the three, as in the open report: Kismet shows what the board does, not what it was
            # asked. Anything else is reported as Kismet sent it, as capture_framework.c does after a set.
            self.channel = BTLE_CHANNEL if self.source.mode == "btle" else value
            self.send(kv3.configreport(seqno, True, None, channel=self.channel))
            return

        settings = self.hop_settings
        for key in ("rate", "shuffle", "skip", "offset"):
            if getattr(value, key) is not None:
                settings[key] = getattr(value, key)
        channels = [c for c in value.channels if self._tunable(c)]
        dropped = [c for c in value.channels if c not in channels]
        if not channels:
            error = "none of the channels %s can be tuned in %s mode" % (",".join(dropped), self.source.mode)
            self.send(kv3.configreport(seqno, False, error, channel=self.channel))
            self.close(error)
            return
        if self.source.mode == "btle":
            # 37 for each of the three, as for a channel set; the C helper reports its hop list the same way
            channels = [BTLE_CHANNEL for _ in channels]
        self._cancel_hop()
        self.hopper = Hopper(channels, settings["rate"], settings["shuffle"], settings["skip"],
                             settings["offset"], self._tune, self.hop_wait)
        settings["skip"] = self.hopper.skip  # the C keeps the clamped value too
        self.hopper.start()
        self.send(kv3.configreport(seqno, True, None, hop=self.hopper.report()))
        if dropped:
            # capture_framework.c drops the channels it fails to tune after a lap and says so; this does it
            # up front, and Kismet takes the shorter list from the report above
            self.message("Removed %d channels from the channel list because the source could not tune to "
                         "them: %s" % (len(dropped), ", ".join(dropped)), kv3.MSG_ERROR)

    def _tunable(self, channel):
        number = channel_number(channel)
        if number is None:
            return False
        if self.source.mode == "btle":
            return 37 <= number <= 39  # any advertising channel is all three, see _tune(); as channel= reads it
        return bd.channel_is_valid(number, self.source.board_mode)

    def _tune(self, channel):
        """Tunes the board to a channel of a set or of a hop list, as Kismet writes it. The channel reported
        from now on is its number, as the C helper's chancontrol_callback keeps it for every hop, so that a
        refused set is answered with the channel the hopping left the board on."""
        # The Bluetooth controller scans 37, 38 and 39 together and cannot be restricted to one: nothing to
        # tune, and the channel stays 37
        if self.source.mode == "btle":
            return
        number = channel_number(channel)
        self.channel = str(number)
        link = self.link
        if link is not None:
            link.set_channels([number])

    def _cancel_hop(self):
        hopper, self.hopper = self.hopper, None
        if hopper is not None:
            hopper.cancel()
            hopper.join(2)  # a hop already under way must not land after the channel that replaces it

    def _stop_board(self):
        self._cancel_hop()
        link, self.link = self.link, None
        if link is not None:
            link.stop()
            link.join(3)

    # --- from the board's thread ---

    def _on_packet(self, ts_sec, ts_usec, orig_len, payload):
        src = self.source
        if src.mode == "btle":
            fixed = fix_btle(payload)
            if fixed is None:
                self.dropped_btle += 1
                if self.dropped_btle == 1 or self.dropped_btle % 1000 == 0:
                    # a status, as the C helper says it: the board goes on capturing
                    self._say("%s: %d BTLE records of impossible length dropped" % (src.name, self.dropped_btle))
                return
            payload, changed = fixed
            if changed:
                self.btle_fixups += 1
                if self.btle_fixups == 1:
                    self._say("%s: the board's firmware does not mark BTLE packets as CRC checked, so Kismet "
                              "would drop them; the helper fills in the CRC and the flags (the board only "
                              "reports packets whose CRC passed). Flashing current firmware makes this "
                              "unnecessary" % src.name)
            self.send(kv3.datareport(self.next_seqno(), src.dlt, ts_sec, ts_usec, orig_len, payload,
                                     freq_khz=BTLE_FREQ_KHZ))
            return
        if src.mode == "wifi":
            self.send(kv3.datareport(self.next_seqno(), src.dlt, ts_sec, ts_usec, orig_len, payload,
                                     freq_khz=radiotap_freq_khz(payload)))
            return
        parts = rewrap_tap(payload)
        if parts is None:
            self.malformed += 1
            if self.malformed == 1 or self.malformed % 1000 == 0:
                self._say("%s: %d 802.15.4 frames with a malformed TAP header dropped" % (src.name, self.malformed))
            return
        frame, channel, rss, hdr_len = parts
        self.send(kv3.datareport(self.next_seqno(), src.dlt, ts_sec, ts_usec, max(orig_len - hdr_len, len(frame)),
                                 frame, channel=str(channel), dbm=c_round(rss) if rss is not None else 0,
                                 freq_khz=zigbee_freq_khz(channel)))

    def _say(self, text, level=kv3.MSG_INFO):
        (log.warning if level >= kv3.MSG_ERROR else log.info)("%s", text)
        self.message(text, level)  # Kismet shows it as "<source name> - <text>"

    def _on_status(self, text, kind="info"):
        """The board's status, to the log and to Kismet's messages without flooding them.

        opened, capturing and lost sync go once per change between them, so a port that opens and fails
        every second says "opened" once. The same error or notice goes at most once every STATUS_REPEAT_S,
        with how often it came meanwhile. Everything is in the debug log.
        """
        now = self.clock()
        if kind in ("opened", "capturing", "lost"):
            if kind == self._state:
                log.debug("%s", text)
                return
            self._state = kind
        else:
            seen = self._errors.get(text)
            if seen is not None and now - seen[0] < STATUS_REPEAT_S:
                seen[1] += 1
                log.debug("%s", text)
                return
            told = text
            if seen is not None and seen[1]:
                told = "%s (%d more times in the last %.0f s)" % (text, seen[1], now - seen[0])
            self._errors[text] = [now, 0]
            text = told
        log.info("%s", text)
        self.message(text)


Identity = collections.namedtuple("Identity", "key mac uuid")


class PortClaims:
    """Which source has which port, for the life of the process. A claim is never given up when a
    connection ends: the source that lost would take the board during the other's reconnect wait, and
    whichever holds it sends MODE, so the board would keep rebooting between two radios."""

    def __init__(self):
        self.owners = {}
        self.lock = threading.Lock()

    def claim(self, key, owner, previous=None):
        """Takes the port for owner unless another owner has it; returns the one that has it. A source
        whose board moved to another port lets its old one go."""
        with self.lock:
            holder = self.owners.setdefault(key, owner)
            if holder is owner and previous is not None and previous != key and self.owners.get(previous) is owner:
                del self.owners[previous]
            return holder


CLAIMS = PortClaims()


class RemoteSource(threading.Thread):
    """One --source: connect, serve, and after anything goes wrong wait RECONNECT_BACKOFF_S and offer it again,
    until stop(). A port another process holds is not offered at all until it is free (in_use, by default
    board.port_locked, which knows only on Linux)."""

    def __init__(self, definition, connect, parse=None, claims=None, in_use=None):
        super().__init__(daemon=True)
        self.definition = definition
        self.connect = connect
        self.parse = parse or parse_definition
        self.claims = CLAIMS if claims is None else claims
        self.in_use = in_use or bd.port_locked
        self.identity = None  # the board this definition was last resolved to: port key, MAC, uuid
        self.claimed = None   # the port key this source holds
        self.stopping = threading.Event()
        self.connection = None
        self.connections = 0
        self.held_off = None  # the port found in use, and said so, until it is offered again

    def resolve(self, definition=None):
        """The definition, resolved to a board the way the last resolution found it.

        A definition that names no port keeps to the board it found first, by its MAC, wherever that is
        plugged in now, rather than failing once another board is plugged in. A named port whose board
        cannot be identified for a moment keeps the identity it had. Then the port is claimed.
        """
        definition = definition or self.definition
        pinned = self.identity
        src = self.parse(definition, pinned_mac=pinned.mac if pinned else None)
        if pinned is not None and pinned.mac and src.key == pinned.key and not src.explicit_uuid:
            if src.mac is None:
                src.adopt(pinned.mac, pinned.uuid)
            elif src.mac != pinned.mac:
                log.warning("%s: %s holds board %s now, not %s; Kismet will see it as another source (%s)",
                            definition, src.device, src.mac, pinned.mac, src.uuid)
        holder = self.claims.claim(src.key, self, self.claimed)
        if holder is not self:
            raise PortTaken("%s is %s's port already; a board captures with one radio at a time"
                            % (src.device, holder.definition))
        self.claimed = src.key
        self.identity = Identity(src.key, src.mac, src.uuid)
        return src

    def available(self, source):
        """Is the source's port free of other captures? Said once when it is not, until it is offered again.

        Kismet opens whatever it is offered. A source on a held port could only fail to open, and one under
        the uuid of a source Kismet has running -- the same board and radio, from Kismet itself, the C helper
        or another copy of this one -- makes Kismet close the running one first. So a held port is not
        offered while it is held."""
        if not self.in_use(source.device):
            self.held_off = None
            return True
        if self.held_off != source.device:
            self.held_off = source.device
            # the C helper's words for it, which its probe gives
            log.warning("%s: %s is already in use by another capture; not offering it to Kismet until it is free "
                        "(looked at again every %g seconds)", source.name, source.device, RECONNECT_BACKOFF_S)
        else:
            log.debug("%s: %s is still in use by another capture", source.name, source.device)
        return False

    def run(self):
        while not self.stopping.is_set():
            try:
                # capture_framework.c probes the source before every connection; so does this, which is
                # how a board plugged in later is found
                source = self.resolve()
                if not self.available(source):
                    self.stopping.wait(RECONNECT_BACKOFF_S)
                    continue
                transport = self.connect()
            except (DefinitionError, OSError) as e:
                log.error("%s: %s", self.definition, one_line(str(e)))
            except Exception:
                log.exception("%s: connecting to Kismet", self.definition)
            else:
                # Nothing that goes wrong in one connection may end the source: the reconnect is what
                # brings it back after Kismet restarts.
                try:
                    conn = self.connection = Connection(source, transport, resolve=self.resolve)
                    self.connections += 1
                    if self.stopping.is_set():
                        conn.close("stopped")
                    log.info("%s: connected, offering it to Kismet as %s", self.definition, source.uuid)
                    reason = conn.run()
                except Exception:
                    log.exception("%s: connection failed", self.definition)
                    reason = "internal error"
                # the reason may be a network error's text, or Kismet's
                log.info("%s: connection ended: %s", self.definition, one_line(reason))
            self.stopping.wait(RECONNECT_BACKOFF_S)

    def stop(self):
        self.stopping.set()
        conn = self.connection
        if conn is not None:
            conn.close("stopped")


# ----------------------------------------------------------------------------------------------
# Command line
# ----------------------------------------------------------------------------------------------

def parse_hostport(text):
    """--connect's HOST:PORT, split at the last ':', so that [::1]:2501 is ('::1', 2501). ValueError without a port."""
    host, sep, port = text.rpartition(":")
    if not sep or not host or not port.isdigit():
        raise ValueError("expected host:port, not %r" % text)
    return host.strip("[]"), int(port)


def connect_order(host):
    """Where to look for Kismet, in order. localhost is 127.0.0.1 first: Windows tries ::1 first and takes
    about two seconds to give up on it when Kismet only listens on IPv4, as behind WSL2's port forwarding
    (and perhaps Docker Desktop's, which was not measured). ::1 is still tried when 127.0.0.1 refuses or
    cannot be reached (_first_that_connects), so a Kismet on IPv6 alone is found too. IPv6 addresses and
    other names are used as they are. Only the address changes: the Host header and the certificate check
    stay with the name (make_connector)."""
    return ["127.0.0.1", "::1"] if host.lower() == "localhost" else [host]


# Why a connection may work at the next address: nothing listens there, or it is not reachable
_TRY_NEXT_ERRNOS = (errno.ECONNREFUSED, errno.EADDRNOTAVAIL, errno.ENETUNREACH, errno.EHOSTUNREACH,
                    errno.EAFNOSUPPORT)


def _first_that_connects(openers):
    """The first transport that opens. An error that another address could avoid (refused, unreachable, timed
    out) moves on to the next; any other is raised at once. When none opens, the error of the first address
    is raised."""
    first = None
    for opener in openers:
        try:
            return opener()
        except OSError as e:
            if first is None:
                first = e
            if not isinstance(e, (ConnectionRefusedError, socket.timeout)) and e.errno not in _TRY_NEXT_ERRNOS:
                raise
    raise first


def _loopback(host):
    """localhost, or a loopback address however it is written: this machine, which a proxy, another one,
    cannot reach by it."""
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def no_proxy_covers(host, no_proxy):
    """Does no_proxy, the variable's value, name host? Read much as curl reads it: the entries apart at commas
    or white space; "*" covers every host; an address or a network (10.0.0.0/8, fd00::/8) the addresses in
    it; a name itself and the names under it, in any case, a dot in front or behind making no difference --
    kismet.lan and .kismet.lan both cover kismet.lan and k.kismet.lan, and neither badkismet.lan."""
    host = host.lower().rstrip(".")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    for entry in re.split(r"[\s,]+", no_proxy.lower()):
        name = entry.strip(".")
        if entry == "*":
            return True
        if not name:
            continue
        if address is None:
            if host == name or host.endswith("." + name):
                return True
            continue
        try:
            if address in ipaddress.ip_network(name, strict=False):
                return True
        except ValueError:
            pass  # a name, which covers no address
    return False


def proxy_variable(secure, environ):
    """Which variable names the HTTP proxy, as websocket-client reads them: https_proxy for wss, http_proxy for
    ws, in small letters or else in capitals."""
    name = "https_proxy" if secure else "http_proxy"
    return name if name in environ else name.upper()


def proxy_route(secure, host, environ=None):
    """The HTTP proxy in the environment that the websocket to host (an address connect_order dials, or a
    name) goes through, as (the variable it is in, its host, its port, (user, password) or None); None to go
    direct.

    The proxy is the one websocket-client would take by itself (proxy_variable). Not for a host that no_proxy
    (or NO_PROXY) covers (no_proxy_covers), and never for a loopback address. websocket-client is not left to
    decide that (proxy_options): on its own 1.9 sends even 127.0.0.1 through the proxy unless no_proxy names
    it, 1.7 and 1.8 leave out localhost and 127.0.0.1 only while no_proxy is not set, ::1 never, and each
    matches no_proxy in its own way, in the case it is written in. (curl and urllib send a loopback address
    that no_proxy does not name through the proxy. The C helper's libwebsockets takes http_proxy alone, for
    ws and wss, and no no_proxy.) A proxy written without "http://" in front has no host, and is none, as
    websocket-client reads it. Raises ValueError for a proxy that would be used and cannot be read; the
    message does not hold the proxy, which may have a password in it.
    """
    environ = os.environ if environ is None else environ
    name = proxy_variable(secure, environ)
    value = environ.get(name, "").replace(" ", "")
    if not value or _loopback(host) or no_proxy_covers(host, environ.get("no_proxy", environ.get("NO_PROXY", ""))):
        return None
    try:
        proxy = urlsplit(value)
        port = proxy.port or 80  # websocket-client's default
    except ValueError:
        raise ValueError("the proxy in %s is not http://HOST:PORT with a port up to 65535" % name)
    if not proxy.hostname:
        return None
    auth = (unquote(proxy.username), unquote(proxy.password or "")) if proxy.username else None
    return name, proxy.hostname, port, auth


def proxy_options(secure, host, environ=None):
    """websocket-client's options for the websocket to host, which say which way it goes (proxy_route): through
    that proxy, or direct. Given a proxy host, websocket-client reads neither variable itself, and takes the
    hosts the proxy is not for from http_no_proxy alone while that is not empty: "*" there matches every host,
    and "@" none, as no host name in a URL holds one. {} when the environment names no proxy, as
    websocket-client then finds none either."""
    environ = os.environ if environ is None else environ
    route = proxy_route(secure, host, environ)
    if route is not None:
        _, proxy_host, port, auth = route
        return {"http_proxy_host": proxy_host, "http_proxy_port": port, "http_proxy_auth": auth,
                "http_no_proxy": ["@"]}
    if environ.get(proxy_variable(secure, environ), "").replace(" ", ""):
        # A proxy that is never asked for, so one that cannot be read stops nothing
        return {"http_proxy_host": "unused", "http_proxy_port": 1, "http_no_proxy": ["*"]}
    return {}


def make_connector(args, host, port, environ=None):
    """A function that opens a fresh transport to Kismet, from the command line options. ValueError for a
    proxy in the environment that would be used and cannot be read (proxy_route)."""
    hosts = connect_order(host)
    if args.tcp:
        return lambda: _first_that_connects([lambda h=h: TcpTransport(h, port) for h in hosts])
    authorization, cookie, query = None, None, ""
    if args.user is not None and ":" not in args.user:
        # A login goes in a Basic Authorization header, which Kismet reads before the address and takes as it
        # is. In the address it would be cut at every '&' (login_cannot_pass), and an address is what proxies
        # and logs keep.
        login = ("%s:%s" % (args.user, args.password)).encode("utf-8")
        authorization = "Basic " + base64.b64encode(login).decode("ascii")
    elif args.user is not None:
        # Basic ends the user name at its first ':', so a user name that holds one goes in the address
        query = "?user=%s&password=%s" % (quote(args.user, safe=""), quote(args.password, safe=""))
    else:
        # An API key goes in the cookie Kismet keeps a session in, KISMET, which it reads before the address
        # and before an Authorization header: not in the address (?KISMET=), for the same reason as a login.
        # Kismet percent-decodes the whole Cookie header, and turns '+' into a space there (in the address's
        # query it does not), before it splits it into cookies at ';', so the key is percent-encoded (a key
        # Kismet makes is hex, and needs none)
        cookie = "KISMET=%s" % quote(args.apikey, safe="")
    sslopt = {"ca_certs": args.ssl_certificate} if args.ssl_certificate else {}
    host_header = origin = None
    if hosts != [host]:
        # Dialled at an address, but still Kismet by the name given: the certificate names "localhost", not
        # 127.0.0.1, and a proxy in front of Kismet may go by the Host header. websocket-client checks the
        # certificate against sslopt's server_hostname when there is one, and writes the Host header without
        # the port for 80 and 443; so does this.
        host_header = _bracketed(host) if port in (80, 443) else "%s:%d" % (_bracketed(host), port)
        origin = ("https://" if args.ssl else "http://") + host_header
        if args.ssl:
            sslopt["server_hostname"] = host
    environ = os.environ if environ is None else environ
    targets = []
    for h in hosts:
        route = proxy_route(args.ssl, h, environ)
        if route is not None:
            # Said, as a proxy that is down shows only as a refused connection
            log.info("the websocket to %s goes through the HTTP proxy in %s (%s:%d)", h, route[0],
                     _bracketed(route[1]), route[2])
        targets.append(("%s://%s:%d%s%s" % ("wss" if args.ssl else "ws", _bracketed(h), port, args.endpoint, query),
                        proxy_options(args.ssl, h, environ)))
    return lambda: _first_that_connects([lambda u=u, p=p: WsTransport(u, sslopt or None, host_header, origin,
                                                                      authorization, cookie, p)
                                         for u, p in targets])


def _bracketed(host):
    """An IPv6 address as it is written in a URL or a Host header."""
    return "[%s]" % host if ":" in host else host


def login_from_env(args, environ=None):
    """Take what the command line leaves out of the Kismet login from the environment, as kismet_cap_esp32c5
    does: with none of --user, --password and --apikey, KISMET_CAP_APIKEY or else KISMET_CAP_USER and
    KISMET_CAP_PASSWORD; with --user alone, KISMET_CAP_PASSWORD; with --password alone, KISMET_CAP_USER. On
    the command line the login can be read by every user in the process list. Empty values count as unset.
    Returns what was used, or None."""
    environ = os.environ if environ is None else environ
    if args.tcp or args.apikey is not None or (args.user is not None and args.password is not None):
        return None
    apikey = environ.get("KISMET_CAP_APIKEY") or None
    user, password = environ.get("KISMET_CAP_USER") or None, environ.get("KISMET_CAP_PASSWORD") or None
    # Half a login given: only the other half can complete it, never an API key
    if args.user is not None:
        if password:
            args.password = password
            return "KISMET_CAP_PASSWORD"
        return None
    if args.password is not None:
        if user:
            args.user = user
            return "KISMET_CAP_USER"
        return None
    if apikey:
        args.apikey = apikey
        return "KISMET_CAP_APIKEY"
    if user and password:
        args.user, args.password = user, password
        return "KISMET_CAP_USER and KISMET_CAP_PASSWORD"
    return None


def login_cannot_pass(args):
    """Is the websocket login one Kismet can take neither way?

    make_connector sends a login in a Basic Authorization header, which Kismet reads before anything else
    and takes as it is, except that Basic ends the user name at its first ':'. A user name that holds one
    goes in the websocket's address instead, and there Kismet's server percent-decodes the whole query and
    only then splits it into variables at '&' (decode_get_variables() in kis_net_beast_httpd.cc): the %26
    this helper writes for '&' comes out as a separator all the same, and the login it checks is cut short.
    So a user name with ':' and an '&' anywhere in the login is turned away either way. An API key goes in
    a cookie, and has no such trouble."""
    if args.tcp or args.user is None:
        return False
    return ":" in args.user and "&" in args.user + (args.password or "")


STOP_SIGNALS = ("SIGINT", "SIGTERM", "SIGBREAK")


class StopFlag:
    """What stops main(): the name of the stop signal that came, or of whatever else stopped it.

    Not a threading.Event. A signal's handler runs in the main thread, between two steps of whatever it is
    doing, and that may be the end of the Event's wait(), which holds the Event's lock for a moment: set()
    would wait there for that lock for ever (seen on Windows, with one stop signal after another). So the
    handler takes no lock -- it does not log either, as logging takes locks too -- and wait() looks at the
    flag every 0.1 s.
    """

    def __init__(self):
        self.why = None

    def set(self, why):
        self.why = why

    def is_set(self):
        return self.why is not None

    def wait(self, timeout):
        """Whether it is set, after timeout seconds at most."""
        end = time.monotonic() + timeout
        while self.why is None and time.monotonic() < end:
            time.sleep(0.1)
        return self.why is not None


def install_stop_handlers(stop):
    """Ctrl+C, SIGTERM and, on Windows, Ctrl+Break set stop, a StopFlag, to the signal's name. Returns the
    handlers they replace.

    Not KeyboardInterrupt alone: a console Ctrl+C does not always reach the main thread as one, and a
    process started with Ctrl+C ignored (Windows passes that on to child processes, and some shells start
    background jobs so) would have no clean way to stop at all.
    """
    def on_signal(signum, frame):
        stop.set(getattr(signal.Signals(signum), "name", str(signum)))

    previous = {}
    for name in STOP_SIGNALS:
        sig = getattr(signal, name, None)
        if sig is None:
            continue
        try:
            previous[sig] = signal.signal(sig, on_signal)
        except (ValueError, OSError):  # not the main thread
            pass
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.kernel32.SetConsoleCtrlHandler(None, False)  # an inherited "ignore Ctrl+C" off
        except Exception:
            pass
    return previous


def set_stop_handlers(handlers):
    """Sets the handler of each stop signal in handlers, {signal: handler} as install_stop_handlers returns
    them."""
    for sig, handler in handlers.items():
        try:
            signal.signal(sig, handler)
        except (ValueError, OSError, TypeError):  # TypeError: None, a handler that was not set from Python
            pass


def list_boards(platform=None):
    """--list: each Espressif USB-Serial-JTAG device pyserial lists, with its MAC and the shortest --source
    for each radio. Returns the exit status, 1 when it lists none.

    No port is opened (opening one moves DTR and RTS, which can reset a board). On Linux a board whose port
    another process holds (board.port_locked) is left out, all three of its names, as the C helper's --list
    leaves it out: a source on it could only fail. A line after the list names what was left out. Elsewhere
    a board in use is listed too, as there is no telling without opening it."""
    boards = bd.find_boards()
    if not boards:
        print("No Espressif USB-Serial-JTAG device (USB ID 303a:1001) found.")
        return 1
    held = [p.device for p in boards if bd.port_locked(p.device, platform)]
    for p in boards:
        if p.device in held:
            continue
        print("%s  %s" % (p.device, bd.board_mac(p) or "(no MAC in its USB serial number)"))
        for mode in ("wifi", "zigbee", "btle"):
            print("    --source %s" % short_definition(p.device, mode, platform))
    if held:
        print("Left out, in use by another capture: %s" % ", ".join(held))
    if len(held) == len(boards):
        return 1
    print("One source per board: it captures with one radio at a time. Every ESP32 on its native USB port "
          "has this USB ID, so a board listed here need not be an ESP32-C5 sniffer.")
    return 0


# --help. The two texts are printed as they are written here (RawDescriptionHelpFormatter), so their lines
# stay within 79 columns, the URL aside; argparse wraps only the options' help. The wiki's
# Command-Line-Reference says the same at more length, and the names and rules are the C helper's
# (kismet_cap_esp32c5): change them together.
HELP_DESCRIPTION = """\
Feed ESP32-C5 sniffer boards plugged into this machine to a Kismet server
elsewhere, over Kismet's remote capture: the websocket on Kismet's web port
(2501), or its legacy TCP port (3501) with --tcp. The server has to know the
esp32c5 source type (Kismet built with kismet/add-to-kismet.sh, or the
project's Docker image). Each --source is one board on one radio, with its own
connection to Kismet. A source that fails, or loses its board or its server,
is offered again 5 s later, until the helper is stopped. On Linux a board that
another capture holds is not offered to Kismet until it is free."""

HELP_EPILOG = """\
source definitions (--source DEF):
  esp32c5-<port>          Wi-Fi on the board on <port>
  esp32c5zigbee-<port>    802.15.4 (Zigbee, Thread) on that board
  esp32c5btle-<port>      Bluetooth LE advertising on that board
  esp32c5:device=<port>,mode=wifi|zigbee|btle
                          the port and the radio said outright
  esp32c5                 Wi-Fi on the only board plugged in (esp32c5zigbee
                          and esp32c5btle likewise)
  <port> is COMn on Windows, in any case (esp32c5-COM14); elsewhere a serial
  port's name under /dev: tty* (esp32c5-ttyACM0), cu.*, cua*, dty* or pts/N.
  A named port that is not there is waited for. Any other name after the '-'
  (esp32c5-kitchen) is only a name: the port is then device=, or the only
  board plugged in. Options follow a ':', separated by commas:
    mode=<radio>          wifi, zigbee (802154, 802.15.4, thread) or btle
                          (ble, bluetooth); wins over the name
    device=<port>         COM14, /dev/ttyACM0, a /dev/serial/by-id/ link
    channel=<n>           the channel to start on, and with channel_hop=false
                          the one to stay on (default wifi 6, zigbee 15,
                          btle 37: BTLE scans 37, 38 and 39 together, and
                          takes and reports any of them as 37, no other)
    name=<text>           the source's name in Kismet
    uuid=<uuid>           a fixed Kismet UUID (8-4-4-4-12 hex); by default it
                          comes from the board's MAC and the radio
    dwell=<ms>            20 to 60000; checked, then of no effect (the board
                          is given one channel at a time)
  Kismet's own options (channels=, channel_hop=, ...) go to Kismet. A value
  that holds commas goes in double quotes, channels="1,6,11", and the shell
  has to pass them on (PowerShell and cmd: see Source-Definitions). A board
  captures with one radio at a time: one --source per board.

login from the environment (not read with --tcp; the command line wins):
  KISMET_CAP_APIKEY       used when none of --user, --password and --apikey
                          is given
  KISMET_CAP_USER, KISMET_CAP_PASSWORD
                          both used when none of those is given and
                          KISMET_CAP_APIKEY is not set; each one also
                          completes a login given half on the command line
  An empty variable counts as unset. The environment keeps the login out of
  the process list, where every user of this machine can read it. The login
  goes in an Authorization header, which takes any character, and an API
  key in a cookie, so neither is in the address, which proxies log. A user
  name that holds ':' goes in the address instead, where Kismet cuts a login
  at every '&': with an '&' in the login too it cannot log in (the helper
  warns), so use an API key.

exit status:
  0  stopped with Ctrl+C, Ctrl+Break (Windows) or SIGTERM; --help; --list
     listed a board
  1  --list listed no board (none plugged in, or every one in use by
     another capture); an internal error (a source never ends by itself)
  2  a mistake on the command line or in a definition; a proxy the
     websocket would go through (http_proxy, https_proxy, or in capitals)
     that cannot be read; websocket-client missing (it is needed unless
     --tcp)

examples (each is one command line; KEY is an API key, datasource role):
  python -m esp32c5_kismet.remote --list
  python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey KEY
    --source esp32c5-COM14 --source esp32c5btle-COM15:name=desk-ble
  python -m esp32c5_kismet.remote --connect 127.0.0.1:3501 --tcp
    --source esp32c5zigbee-ttyACM0:channel=20,channel_hop=false

More on the wiki, pages Command-Line-Reference, Source-Definitions and
Remote-Capture:
https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Command-Line-Reference"""


def main(argv=None, exiting=False):
    """The command line. Returns the exit status; argparse itself exits with 2 on a mistake in it.

    The stop signals get their handlers back on the way out, for a caller that goes on (the tests). exiting
    says that the process ends with main(), as with python -m: they are left ignored then (see the stop
    below)."""
    p = argparse.ArgumentParser(prog="python -m esp32c5_kismet.remote", description=HELP_DESCRIPTION,
                                epilog=HELP_EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--connect", metavar="HOST:PORT",
                   help="the Kismet server: its web port (2501) for the websocket, or its legacy TCP port "
                        "(3501) with --tcp; split at the last ':', so [::1]:2501 works. localhost is dialled "
                        "as 127.0.0.1, then ::1 (TLS and the Host header keep the name). Required unless "
                        "--list")
    p.add_argument("--tcp", action="store_true",
                   help="Kismet's legacy TCP remote capture (port 3501): no login and no TLS, and Kismet "
                        "listens on it on 127.0.0.1 only by default; a --user, --password or --apikey is "
                        "ignored. Needs no websocket-client")
    p.add_argument("--ssl", action="store_true",
                   help="wss:// instead of ws://, for Kismet behind a TLS proxy; the server's certificate is "
                        "checked against the system's CAs, or --ssl-certificate's")
    p.add_argument("--ssl-certificate", metavar="CAFILE",
                   help="CA certificate file to check the server's certificate with, instead of the system's; "
                        "implies --ssl")
    p.add_argument("--user", help="Kismet login name, with --password (or KISMET_CAP_USER, see below); a login "
                                  "wins over an API key")
    p.add_argument("--password", help="the login's password, with --user (or KISMET_CAP_PASSWORD)")
    p.add_argument("--apikey", help="Kismet API key with the datasource role, instead of a login (or "
                                    "KISMET_CAP_APIKEY)")
    p.add_argument("--endpoint", default=WS_ENDPOINT,
                   help="websocket path, for Kismet behind a reverse proxy that adds a prefix "
                        "(default: %(default)s)")
    p.add_argument("--source", action="append", default=[], metavar="DEF",
                   help="a source definition (see below); repeat it for more boards, one per board. "
                        "Required with --connect")
    p.add_argument("--list", action="store_true",
                   help="list the boards plugged in (USB ID 303a:1001), each with a --source per radio, and "
                        "exit. Opens no port; on Linux a board that another capture holds is left out")
    p.add_argument("--debug", action="store_true",
                   help="log every protocol message except packets, the stop signal, and where the login "
                        "came from")
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO,
                        format="%(asctime)s %(levelname)s: %(message)s", datefmt="%H:%M:%S")

    if args.list:
        return list_boards()
    if not args.connect:
        p.error("--connect HOST:PORT is required (or --list to see the boards)")
    try:
        host, port = parse_hostport(args.connect)
    except ValueError as e:
        p.error(str(e))
    if not args.source:
        p.error("--source is required when connecting to Kismet")
    args.ssl = args.ssl or bool(args.ssl_certificate)
    if args.tcp:
        if args.user or args.password or args.apikey:
            log.warning("ignoring the user, password and API key in legacy TCP mode")
        if args.ssl:
            p.error("--ssl needs the websocket protocol, not --tcp")
    else:
        used = login_from_env(args)
        if used:
            log.debug("the Kismet login comes from %s", used)
        if (args.user is None) != (args.password is None):
            p.error("give both --user and --password" + (
                "" if args.apikey is not None else
                " (the one left out may also be in KISMET_CAP_USER or KISMET_CAP_PASSWORD)"))
        if args.user is None and args.apikey is None:
            p.error("a user and password, or an API key, are required for the websocket protocol "
                    "(--user and --password, --apikey, or KISMET_CAP_APIKEY or KISMET_CAP_USER and "
                    "KISMET_CAP_PASSWORD in the environment)")
        if args.user is not None and args.apikey:
            log.warning("ignoring --apikey and using the login")
        if login_cannot_pass(args):
            log.warning("the Kismet user name holds ':' and the login '&': Kismet reads a user name in an "
                        "Authorization header only up to its first ':', and cuts a login in the websocket's "
                        "address at every '&' (after decoding it), so this one cannot log in either way; use an "
                        "API key (--apikey or KISMET_CAP_APIKEY) instead of the login")
        if port == LEGACY_TCP_PORT:
            log.warning("port 3501 is Kismet's legacy TCP port; did you mean --tcp, or port 2501?")
        try:
            import websocket  # noqa: F401  -- found out now, not by every source thread dying of it
        except ImportError:
            p.error("the websocket protocol needs websocket-client (pip install websocket-client), or use --tcp")

    try:
        check_sources(args.source)
    except DefinitionError as e:
        p.error(str(e))

    try:
        connect = make_connector(args, host, port)
    except ValueError as e:
        p.error(str(e))
    sources = [RemoteSource(d, connect) for d in args.source]
    stop = StopFlag()
    previous = install_stop_handlers(stop)
    try:
        for s in sources:
            s.start()
        try:
            while not stop.wait(0.5):
                if not any(s.is_alive() for s in sources):
                    break
        except KeyboardInterrupt:
            stop.set("KeyboardInterrupt")
        stopped = stop.is_set()
        # The exit status is decided. A stop signal from here on, such as Ctrl+C pressed again, is ignored:
        # given back to the handler from before main(), it would raise KeyboardInterrupt in a join below, or
        # end the process at once (Ctrl+Break, SIGTERM), with the signal's own exit status (0xC000013A on
        # Windows) instead of 0. Ignored, not left to on_signal: under python -m (exiting) Python shuts down
        # as soon as main() returns, and while it does a signal with a handler of its own gets its default
        # action back; a quick stop can be over before the second press. The joins keep their limits, so a
        # source that does not stop still cannot keep the helper from exiting.
        set_stop_handlers(dict.fromkeys(previous, signal.SIG_IGN))
        if stopped:
            log.debug("stop signal %s", stop.why)
            log.info("stopping")
        for s in sources:
            s.stop()
        for s in sources:
            s.join(5)
    finally:
        if not exiting:
            set_stop_handlers(previous)
    if not stopped:
        # A source only ends when it is stopped (RemoteSource.run catches everything else), so this is a
        # thread that died of something it cannot catch: say so rather than wait for ever on nothing
        log.error("every source thread has died, which is an internal error; stopping")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(exiting=True))
