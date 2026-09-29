#!/usr/bin/env python3
"""probe_start.py PORT [SECS]: open PORT without resetting the board (exclusive; RTS then DTR released after the
open, as the helpers do), send only 'START <us> probe', read for SECS (default 4) and report whether the board
answered, with which link type, and how many bytes followed. Sends no MODE, so the radio is left as it is."""
import os
import struct
import sys
import time

import serial

port = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
s = serial.Serial()
s.port = port
s.baudrate = 115200
s.timeout = 0.2
s.exclusive = True
s.open()
s.rts = False
s.dtr = False
pre = s.read(4096)
s.write(b"START %d probe\n" % int(time.time() * 1e6))
buf = b""
end = time.time() + secs
while time.time() < end:
    buf += s.read(4096)
s.close()
i = buf.find(b"<<START>> probe")
print("%.3f %s -> %s: %d bytes before START, %d bytes in %.0f s after it" % (
    time.time(), port, os.path.realpath(port), len(pre), len(buf), secs))
if i < 0:
    print("  NO START ANSWER; first bytes: %r" % buf[:120])
else:
    j = buf.index(b"\n", i) + 1
    magic, vmaj, vmin, _, _, snap, lt = struct.unpack("<IHHiIII", buf[j:j + 24])
    print("  START answered: magic %08x, link type %d, %d bytes of records after the header" % (magic, lt, len(buf) - j - 24))
