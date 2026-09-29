"""Kismet's external capture protocol, version 3: frames, and the messages a remote capture helper exchanges.

Nothing in here knows about sockets or boards. A frame is a 20 byte header in network byte order followed
by a msgpack map keyed by small integers:

    signature 0xDECAFBAD | sentinel 0xA9A9 | version 3 | length of the map | packet type | code | seqno
      (u32)                (u16)            (u16)       (u32)               (u16)         (u16)  (u32)

Over the websocket each binary message holds exactly one frame; over the legacy TCP port the frames follow
one another on the stream. The wiki page How-It-Works has an overview of the messages:
https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/How-It-Works

Every number below is copied from Kismet's kis_external_packet.h (master cfe4270); the comments give the
line. What is sent copies capture_framework.c, the C side every Kismet capture helper is built on: the same
fields, in the same order, with the same msgpack types, so the bytes are the ones a C helper would send.
mpack, which Kismet uses, always writes the smallest encoding that holds a value, and so does msgpack for
Python, so an integer written with mpack_write_u32() or mpack_write_uint() comes out identical.
"""

import collections
import struct

import msgpack

PROTO_SIG = 0xDECAFBAD      # KIS_EXTERNAL_PROTO_SIG, line 34
V2_SIG = 0xABCD             # KIS_EXTERNAL_V2_SIG, line 62; only to recognise a legacy ping
V3_SIG = 0xA9A9             # KIS_EXTERNAL_V3_SIG, line 87
V3_VERSION = 3

HEADER = struct.Struct("!IHHIHHI")        # struct kismet_external_frame_v3, lines 88-113
V2_HEADER = struct.Struct("!IHHI32sI")    # struct kismet_external_frame_v2, lines 63-85
STUB = struct.Struct("!IHHI")             # struct kismet_external_frame_stub, lines 38-44: common to both
MAX_FRAME_LEN = 16 << 20                  # sanity bound against a stream that is not Kismet at all

# Packet types, lines 192-210
CMD_REGISTER, CMD_PING, CMD_PONG, CMD_SHUTDOWN, CMD_MESSAGE, CMD_ERROR = 1, 2, 3, 4, 5, 6
KDS_PROBEREQ, KDS_PROBEREPORT, KDS_OPENREQ, KDS_OPENREPORT = 10, 11, 12, 13
KDS_LISTREQ, KDS_LISTREPORT, KDS_PACKET, KDS_CONFIGREQ, KDS_CONFIGREPORT, KDS_NEWSOURCE = 14, 15, 16, 17, 18, 19

PACKET_NAMES = {v: k for k, v in globals().items() if k.startswith(("CMD_", "KDS_"))}

# Message levels, lines 234-238
MSG_DEBUG, MSG_INFO, MSG_ERROR, MSG_ALERT, MSG_FATAL = 1, 2, 4, 8, 16

# Field IDs. Each group is the map of one packet type or sub-block.
SHUTDOWN_FIELD_REASON = 1                                       # line 246
MESSAGE_FIELD_TYPE, MESSAGE_FIELD_STRING = 1, 2                 # lines 268-270
ERROR_FIELD_STRING = 1                                          # line 282

# channel hop sub-block, lines 293-303
CHANHOP_FIELD_RATE, CHANHOP_FIELD_SHUFFLE, CHANHOP_FIELD_SKIP = 1, 2, 3
CHANHOP_FIELD_OFFSET, CHANHOP_FIELD_CHAN_LIST, CHANHOP_FIELD_ENABLED = 4, 5, 6

# interface sub-block, lines 350-360
INTERFACE_FIELD_IFACE, INTERFACE_FIELD_FLAGS, INTERFACE_FIELD_HW = 1, 2, 3
INTERFACE_FIELD_CAPIFACE, INTERFACE_FIELD_CHANNEL, INTERFACE_FIELD_CHAN_LIST = 4, 5, 6

# signal sub-block, lines 368-380
SIGNAL_FIELD_SIGNAL_DBM, SIGNAL_FIELD_NOISE_DBM, SIGNAL_FIELD_SIGNAL_RSSI, SIGNAL_FIELD_NOISE_RSSI = 1, 2, 3, 4
SIGNAL_FIELD_FREQ_KHZ, SIGNAL_FIELD_DATARATE, SIGNAL_FIELD_CHANNEL = 5, 6, 7

# packet sub-block, lines 391-400 (there is no field 5)
PACKET_FIELD_DLT, PACKET_FIELD_TS_S, PACKET_FIELD_TS_US, PACKET_FIELD_LENGTH, PACKET_FIELD_CONTENT = 1, 2, 3, 4, 6

# KDS_PACKET, the data report, lines 432-440
DATAREPORT_FIELD_GPSBLOCK, DATAREPORT_FIELD_SIGNALBLOCK, DATAREPORT_FIELD_PACKETBLOCK = 1, 2, 4

PROBEREQ_FIELD_DEFINITION = 1                                                       # line 451
PROBEREPORT_FIELD_SEQNO, PROBEREPORT_FIELD_INTERFACE, PROBEREPORT_FIELD_MSG = 1, 2, 3  # lines 461-465
OPENREQ_FIELD_DEFINITION = 1                                                        # line 475

# open report, lines 485-503
OPENREPORT_FIELD_SEQNO, OPENREPORT_FIELD_DLT, OPENREPORT_FIELD_CAPIF, OPENREPORT_FIELD_CHAN_LIST = 1, 2, 3, 4
OPENREPORT_FIELD_CHANNEL, OPENREPORT_FIELD_CHANHOPBLOCK, OPENREPORT_FIELD_HARDWARE = 5, 6, 7
OPENREPORT_FIELD_UUID, OPENREPORT_FIELD_MSG, OPENREPORT_FIELD_VERSION = 8, 9, 10

CONFIGREQ_FIELD_CHANNEL, CONFIGREQ_FIELD_CHANHOPBLOCK = 1, 2                         # lines 544-546
CONFIGREPORT_FIELD_SEQNO, CONFIGREPORT_FIELD_CHANNEL = 1, 2                          # lines 555-561
CONFIGREPORT_FIELD_CHANHOPBLOCK, CONFIGREPORT_FIELD_MSG = 3, 4
NEWSOURCE_FIELD_DEFINITION, NEWSOURCE_FIELD_SOURCETYPE, NEWSOURCE_FIELD_UUID = 1, 2, 3  # lines 569-573


class ProtocolError(Exception):
    """The peer sent something that is not a v3 frame we can read. The connection is not worth keeping."""


Frame = collections.namedtuple("Frame", "pkt_type code seqno fields")


# ----------------------------------------------------------------------------------------------
# Frames
# ----------------------------------------------------------------------------------------------

def pack(fields):
    # mpack_write_float() writes a float32 and Kismet reads the hop rate with mpack_node_float(), so floats
    # go out as single precision. Strings are str, bytes are bin, as mpack_write_cstr() and _bin() do.
    return msgpack.packb(fields, use_bin_type=True, use_single_float=True)


def unpack(data):
    if not data:
        return {}
    try:
        fields = msgpack.unpackb(data, raw=False, strict_map_key=False)
    except (ValueError, TypeError, msgpack.UnpackException) as e:
        raise ProtocolError("unreadable msgpack content: %s" % e)
    if not isinstance(fields, dict):
        raise ProtocolError("frame content is not a map")
    return fields


def frame(pkt_type, seqno, code=0, fields=None):
    """One frame as cf_prepare_packet() lays it out. fields=None means no content at all, as in a PONG."""
    data = pack(fields) if fields is not None else b""
    return HEADER.pack(PROTO_SIG, V3_SIG, V3_VERSION, len(data), pkt_type, code, seqno) + data


def take_frame(buf):
    """Cut the first frame off a byte stream. Returns (Frame, bytes used), or (None, 0) while incomplete.

    A legacy v2 PING is answered like a v3 one, as capture_framework.c does: Kismet uses it to find out
    which protocol a helper speaks. Anything else in v2 means a Kismet too old for this helper.
    """
    if len(buf) < STUB.size:
        return None, 0
    signature, sentinel, version, length = STUB.unpack_from(buf)
    if signature != PROTO_SIG:
        raise ProtocolError("not a Kismet frame (signature %08X)" % signature)
    if length > MAX_FRAME_LEN:
        raise ProtocolError("frame of %d bytes is too large" % length)
    if sentinel == V2_SIG:
        total = V2_HEADER.size + length
        if len(buf) < total:
            return None, 0
        _, _, _, _, command, seqno = V2_HEADER.unpack_from(buf)
        if command.split(b"\0")[0].upper() != b"PING":
            raise ProtocolError("Kismet speaks the older v2 protocol; it needs upgrading")
        return Frame(CMD_PING, 0, seqno, {}), total
    if sentinel != V3_SIG:
        raise ProtocolError("unknown Kismet protocol (sentinel %04X, version %d)" % (sentinel, version))
    total = HEADER.size + length
    if len(buf) < total:
        return None, 0
    _, _, _, _, pkt_type, code, seqno = HEADER.unpack_from(buf)
    return Frame(pkt_type, code, seqno, unpack(bytes(buf[HEADER.size:total]))), total


def decode(message):
    """A websocket message, which always holds exactly one whole frame."""
    fr, _ = take_frame(message)
    if fr is None:
        raise ProtocolError("truncated frame (%d bytes)" % len(message))
    return fr


# ----------------------------------------------------------------------------------------------
# What the helper sends (capture_framework.c's cf_send_* functions, field for field)
# ----------------------------------------------------------------------------------------------

def pong(ping_seqno):
    # cf_send_pong: the PING's own sequence number, code 0, and no content, not even an empty map
    return frame(CMD_PONG, ping_seqno)


def message(seqno, text, level=MSG_INFO):
    # cf_send_message
    return frame(CMD_MESSAGE, seqno, 0, {MESSAGE_FIELD_TYPE: level, MESSAGE_FIELD_STRING: text})


def error(seqno, text):
    # cf_send_error: seqno is the request that failed or 0, and the header code is always 1
    return frame(CMD_ERROR, seqno, 1, {ERROR_FIELD_STRING: text} if text is not None else {})


def shutdown(seqno, reason):
    # Not in capture_framework.c. Kismet's handle_packet_shutdown_v3 reads the reason and puts the source
    # into error with it, which an ERROR packet does not do (the v3 server has no handler for those).
    return frame(CMD_SHUTDOWN, seqno, 0, {SHUTDOWN_FIELD_REASON: reason})


def newsource(seqno, definition, source_type, uuid):
    # cf_send_newsource. Kismet reads the uuid unconditionally, so it is always sent.
    return frame(KDS_NEWSOURCE, seqno, 0, {NEWSOURCE_FIELD_DEFINITION: definition,
                                           NEWSOURCE_FIELD_SOURCETYPE: source_type,
                                           NEWSOURCE_FIELD_UUID: uuid})


def _hop_block(hop, enabled):
    """hop: dict with channels, rate, shuffle, offset, skip. The order is cf_send_openresp's."""
    block = {}
    if hop["channels"]:
        block[CHANHOP_FIELD_CHAN_LIST] = list(hop["channels"])
    block[CHANHOP_FIELD_RATE] = float(hop["rate"])
    block[CHANHOP_FIELD_SHUFFLE] = bool(hop["shuffle"])
    block[CHANHOP_FIELD_OFFSET] = int(hop["offset"])
    block[CHANHOP_FIELD_SKIP] = int(hop["skip"])
    block[CHANHOP_FIELD_ENABLED] = enabled
    return block


def probereport(seqno, success, msg, capif=None, hardware=None, channel=None, channels=()):
    # cf_send_proberesp. The header code is the success flag, 1 or 0.
    fields = {}
    if msg is not None:
        fields[PROBEREPORT_FIELD_MSG] = msg
    fields[PROBEREPORT_FIELD_SEQNO] = seqno
    if capif is not None:
        iface = {INTERFACE_FIELD_CAPIFACE: capif}
        if hardware is not None:
            iface[INTERFACE_FIELD_HW] = hardware
        if channel is not None:
            iface[INTERFACE_FIELD_CHANNEL] = channel
        if channels:
            iface[INTERFACE_FIELD_CHAN_LIST] = list(channels)
        fields[PROBEREPORT_FIELD_INTERFACE] = iface
    return frame(KDS_PROBEREPORT, seqno, 1 if success else 0, fields)


def openreport(seqno, success, msg, dlt, version, uuid=None, capif=None, hardware=None, channel=None,
               channels=(), hop=None, hopping=True):
    """cf_send_openresp. The C framework always has a message buffer, so an empty msg is still sent.

    hopping=False (a source defined with channel_hop=false) adds a hop block without a rate. That is the
    only thing that makes Kismet's handle_packet_opensource_report_v3() mark a source as not hopping, and
    Kismet never sends such a source a hop list that would. Without it a source Kismet knows from an
    earlier connection -- as it does by the stable uuid -- keeps showing the hopping it had then. That
    block carries no rate on purpose: Kismet stores a rate from an open report and then overwrites it
    with 1 (set_int_source_hop_rate(true)).
    """
    fields = {}
    if msg is not None:
        fields[OPENREPORT_FIELD_MSG] = msg
    fields[OPENREPORT_FIELD_SEQNO] = seqno
    fields[OPENREPORT_FIELD_DLT] = dlt
    fields[OPENREPORT_FIELD_VERSION] = version
    if uuid is not None:
        fields[OPENREPORT_FIELD_UUID] = uuid
    if capif is not None:
        fields[OPENREPORT_FIELD_CAPIF] = capif
    if hardware is not None:
        fields[OPENREPORT_FIELD_HARDWARE] = hardware
    if channel is not None:
        fields[OPENREPORT_FIELD_CHANNEL] = channel
    if channels:
        fields[OPENREPORT_FIELD_CHAN_LIST] = list(channels)
    if hop is not None:
        fields[OPENREPORT_FIELD_CHANHOPBLOCK] = _hop_block(hop, True)
    elif not hopping:
        fields[OPENREPORT_FIELD_CHANHOPBLOCK] = {CHANHOP_FIELD_ENABLED: False}
    return frame(KDS_OPENREPORT, seqno, 1 if success else 0, fields)


def configreport(seqno, success, msg, channel=None, hop=None):
    # cf_send_configresp. Its hop block says "enabled" with mpack_write_uint(true), an integer 1, where the
    # open report uses a real boolean; Kismet reads neither, but the bytes follow the C.
    fields = {}
    if msg is not None:
        fields[CONFIGREPORT_FIELD_MSG] = msg
    fields[CONFIGREPORT_FIELD_SEQNO] = seqno
    if hop is not None:
        fields[CONFIGREPORT_FIELD_CHANHOPBLOCK] = _hop_block(hop, 1)
    elif channel is not None:
        fields[CONFIGREPORT_FIELD_CHANNEL] = channel
    return frame(KDS_CONFIGREPORT, seqno, 1 if success else 0, fields)


def datareport(seqno, dlt, ts_sec, ts_usec, orig_len, content, channel=None, dbm=0, freq_khz=0):
    """cf_send_data: an optional signal block, then the packet block.

    Kismet reads signal_dbm with mpack_node_u32(), which refuses a negative msgpack integer, and the C
    framework writes the int32 with mpack_write_u32(). So -60 dBm travels as the unsigned 0xFFFFFFC4.
    Like the C, a zero dBm or frequency is left out.
    """
    fields = {}
    if channel is not None or dbm or freq_khz:
        sig = {}
        if channel is not None:
            sig[SIGNAL_FIELD_CHANNEL] = channel
        if dbm:
            sig[SIGNAL_FIELD_SIGNAL_DBM] = dbm & 0xFFFFFFFF
        if freq_khz:
            sig[SIGNAL_FIELD_FREQ_KHZ] = freq_khz
        fields[DATAREPORT_FIELD_SIGNALBLOCK] = sig
    fields[DATAREPORT_FIELD_PACKETBLOCK] = {
        PACKET_FIELD_DLT: dlt,
        PACKET_FIELD_TS_S: ts_sec,
        PACKET_FIELD_TS_US: ts_usec,
        PACKET_FIELD_LENGTH: orig_len,
        PACKET_FIELD_CONTENT: bytes(content),
    }
    return frame(KDS_PACKET, seqno, 0, fields)


# ----------------------------------------------------------------------------------------------
# What the helper receives
# ----------------------------------------------------------------------------------------------

def _text(fields, key, what):
    value = fields.get(key)
    if not isinstance(value, str):
        raise ProtocolError("missing or malformed %s" % what)
    return value


def parse_definition(fr):
    """The source definition in an OPENREQ or PROBEREQ (both use field 1)."""
    return _text(fr.fields, OPENREQ_FIELD_DEFINITION, "source definition")


HopRequest = collections.namedtuple("HopRequest", "channels rate shuffle skip offset")


def parse_configreq(fr):
    """Returns ("channel", "6"), ("hop", HopRequest) or None when the request asks for neither.

    As in capture_framework.c a channel wins over a hop block, and a hop field that Kismet left out is
    None: the helper keeps its current value. Kismet sends rate, shuffle, offset and the list, never skip.
    """
    f = fr.fields
    if CONFIGREQ_FIELD_CHANNEL in f:
        return "channel", _text(f, CONFIGREQ_FIELD_CHANNEL, "channel")
    if CONFIGREQ_FIELD_CHANHOPBLOCK not in f:
        return None
    hop = f[CONFIGREQ_FIELD_CHANHOPBLOCK]
    if not isinstance(hop, dict):
        raise ProtocolError("malformed channel hop block")
    channels = hop.get(CHANHOP_FIELD_CHAN_LIST)
    if not isinstance(channels, list) or not channels or not all(isinstance(c, str) for c in channels):
        raise ProtocolError("channel hop block without a channel list")
    rate, shuffle = hop.get(CHANHOP_FIELD_RATE), hop.get(CHANHOP_FIELD_SHUFFLE)
    skip, offset = hop.get(CHANHOP_FIELD_SKIP), hop.get(CHANHOP_FIELD_OFFSET)
    if rate is not None and (isinstance(rate, bool) or not isinstance(rate, (int, float))):
        raise ProtocolError("malformed hop rate")
    if shuffle is not None and not isinstance(shuffle, bool):
        raise ProtocolError("malformed hop shuffle flag")
    for value in (skip, offset):  # mpack_node_u16()
        if value is not None and (isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFF):
            raise ProtocolError("malformed hop skip or offset")
    return "hop", HopRequest(channels, None if rate is None else float(rate), shuffle, skip, offset)


def parse_text(fr, key):
    """The string of a MESSAGE, ERROR or SHUTDOWN, or "" when there is none."""
    value = fr.fields.get(key)
    return value if isinstance(value, str) else ""
