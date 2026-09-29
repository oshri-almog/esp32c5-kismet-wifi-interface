"""Before/after: a refused BTLE channel set, where an API key goes, and the lost-sync status's name.
python repro.py <dir holding the esp32c5_kismet package>"""
import sys, time, types
sys.path.insert(0, sys.argv[1])
from esp32c5_kismet import board as bd, kismet_v3 as kv3, remote


class T:
    def __init__(self):
        self.sent = []
    def send(self, data):
        self.sent.append(kv3.decode(data))
    def close(self):
        pass


class Port:
    def __init__(self, device, mac):
        self.device, self.serial_number, self.vid, self.pid = device, mac, 0x303A, 0x1001


src = remote.parse_definition("esp32c5btle-COM14:name=fake-btle", [Port("COM14", "74:4D:BD:A1:B2:C3")], "win32")
conn = remote.Connection(src, T(), "win32")
conn.channel = "37"
conn.dispatch(kv3.decode(kv3.frame(kv3.KDS_CONFIGREQ, 9, 1, {1: "40"})))
for f in conn.transport.sent:
    print("set 40 ->", kv3.PACKET_NAMES[f.pkt_type], "code", f.code, f.fields)
print("connection closed:", conn.closed.is_set(), conn.reason)

seen = []
real = remote.WsTransport
remote.WsTransport = lambda *a: seen.append(a) or "t"
args = types.SimpleNamespace(tcp=False, user=None, password=None, apikey="4F1A0B9C2D", ssl=False,
                             ssl_certificate=None, endpoint=remote.WS_ENDPOINT)
remote.make_connector(args, "kismet.lan", 2501)()
print("API key: url", seen[0][0], "| other args", seen[0][1:])

statuses = []
link = bd.BoardLink("/tmp/x/nob", bd.MODE_BLE, [37], 250, lambda *r: None, lambda t, k: statuses.append(t),
                    **({"name": "oldfw"} if "name" in bd.BoardLink.__init__.__code__.co_varnames else {}))
scanner, framer = bd.MarkerScanner(), bd.PcapFramer(256)
import struct
link._consume(b"\n<<START>> abc\n" + struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 127), scanner, framer, b"abc")
print("lost-sync status:", statuses)
