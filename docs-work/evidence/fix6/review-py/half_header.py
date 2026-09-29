"""A board that answers START with our marker and only the first 10 bytes of the PCAP global header, then
goes silent (port still open). Counts what BoardLink does for 9 s: STARTs sent, reopens, statuses."""
import re, struct, sys, threading, time
sys.path.insert(0, sys.argv[1])
from esp32c5_kismet import board as bd

HDR = struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 127)

class HalfHeaderBoard:
    def __init__(self):
        self.out, self.commands, self.lock, self.in_waiting = bytearray(), [], threading.Lock(), 0
    def write(self, data):
        with self.lock:
            for line in data.decode().splitlines():
                self.commands.append((round(time.monotonic() - T0, 2), line))
                m = re.fullmatch(r"START \d+ (\w+)", line)
                if m:
                    self.out += b"\n<<START>> %s\n" % m.group(1).encode() + HDR[:10]
        return len(data)
    def read(self, size):
        time.sleep(0.01)
        with self.lock:
            data, self.out[:] = bytes(self.out), b""
        return data
    def close(self):
        pass

opens = []
fake = HalfHeaderBoard()
def fake_open(port, baud=921600):
    opens.append(round(time.monotonic() - T0, 2))
    return fake
bd.open_serial = fake_open
bd.close_serial = lambda ser: None
bd.port_identity = lambda ser, port, platform=None: None
statuses = []
T0 = time.monotonic()
link = bd.BoardLink("FAKE", "wifi", [6], 250, on_packet=lambda *r: None,
                    on_status=lambda text, kind: statuses.append((round(time.monotonic() - T0, 2), text, kind)))
link.start()
time.sleep(9)
link.stop(); link.join(3)
print("opens at:", opens)
print("commands:", [c for c in fake.commands if not c[1].startswith(("CHANNELS", "DWELL"))])
print("statuses:", statuses)
print("after 9 s: synced=%s capturing=%s" % (link.synced, link.capturing))
