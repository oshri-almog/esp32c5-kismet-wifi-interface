"""A board that captures, then is unplugged for good: is link.capturing still True (the watchdog's input)?"""
import re, struct, sys, threading, time
sys.path.insert(0, sys.argv[1])
import serial
from esp32c5_kismet import board as bd

HDR = struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 127)
def rec(i):
    return struct.pack("<IIII", 1700000000 + i, 0, 40, 40) + bytes(40)

class Board:
    def __init__(self):
        self.out, self.lock, self.in_waiting, self.n, self.gone, self.streaming = bytearray(), threading.Lock(), 0, 0, False, False
    def write(self, data):
        with self.lock:
            if self.gone:
                raise serial.SerialException("write failed: gone")
            for line in data.decode().splitlines():
                m = re.fullmatch(r"START \d+ (\w+)", line)
                if m:
                    self.out += b"\n<<START>> %s\n" % m.group(1).encode() + HDR
                    self.streaming = True
        return len(data)
    def read(self, size):
        time.sleep(0.01)
        with self.lock:
            if self.gone:
                raise serial.SerialException("device reports readiness to read but returned no data")
            if self.streaming:
                self.n += 1
                self.out += rec(self.n)
            data, self.out[:] = bytes(self.out), b""
        return data
    def close(self):
        pass

board = Board()
state = {"plugged": True}
def fake_open(port, baud=921600):
    if not state["plugged"]:
        raise serial.SerialException("could not open port %s: [Errno 2] No such file or directory" % port)
    return board
bd.open_serial = fake_open
bd.close_serial = lambda ser: None
bd.port_identity = lambda ser, port, platform=None: None
bd.find_port_by_mac = lambda mac, boards=None: None
got = []
link = bd.BoardLink("FAKE", "wifi", [6], 250, on_packet=lambda *r: got.append(r), on_status=lambda t, k: print("   status:", t))
link.start()
time.sleep(2)
print("capturing before unplug: %s, %d packets" % (link.capturing, len(got)))
with board.lock:
    board.gone = True
state["plugged"] = False
time.sleep(3)
print("3 s after unplug: capturing=%s synced=%s" % (link.capturing, link.synced))
link.stop(); link.join(3)
