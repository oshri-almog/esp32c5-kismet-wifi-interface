"""Hop to 1 then 11, then a refused set: which channel is the answer? python hop_refuse_demo.py CODE_DIR"""
import sys
import time

sys.path.insert(0, sys.argv[1])
from esp32c5_kismet import board as bd, kismet_v3 as kv3, remote  # noqa: E402


class Transport:
    def __init__(self):
        self.sent = []

    def send(self, data):
        self.sent.append(kv3.decode(data))

    def close(self):
        pass


class Link:
    synced = capturing = True
    last_status = None

    def __init__(self):
        self.tuned = []

    def set_channels(self, channels):
        self.tuned.append(list(channels))

    def stop(self):
        pass


class Port:
    def __init__(self, device, serial_number=None):
        self.device, self.serial_number = device, serial_number
        self.vid, self.pid = bd.ESPRESSIF_USB_JTAG


src = remote.parse_definition("esp32c5-COM14", [Port("COM14", "74:4D:BD:A1:B2:C3")], "win32", exists=lambda d: True)
conn = remote.Connection(src, Transport(), "win32")
conn.link, conn.channel = Link(), str(src.initial_channel)
laps = iter([False, False, True])
conn.hop_wait = lambda seconds: next(laps)
conn.dispatch(kv3.decode(kv3.frame(kv3.KDS_CONFIGREQ, 9, 1, {2: {1: 5.0, 2: False, 4: 0, 5: ["1", "11"]}})))
conn.hopper.join(2)
conn.dispatch(kv3.decode(kv3.frame(kv3.KDS_CONFIGREQ, 9, 1, {1: "15"})))
print("initial channel %s; the board was tuned to %s; the refusal answers channel %r" %
      (src.initial_channel, conn.link.tuned, conn.transport.sent[-1].fields[2]))
