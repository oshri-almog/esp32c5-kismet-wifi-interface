#!/usr/bin/env python3
"""diag.py PORT: open without a reset, then: START only (6 s), CHANNELS 6 (6 s), CHANNELS 1-177 (6 s). Prints
bytes per second in each phase and the text before the first START answer (boot log, if any)."""
import os
import sys
import time

import serial

port = sys.argv[1]
s = serial.Serial()
s.port = port
s.baudrate = 115200
s.timeout = 0.1
s.exclusive = True
s.open()
s.rts = False
s.dtr = False
pre = b""
end = time.time() + 1.0
while time.time() < end:
    pre += s.read(4096)
print("%s -> %s: %d bytes before anything was sent: %r" % (port, os.path.realpath(port), len(pre), pre[:300]))


def phase(label, cmd, secs=6):
    s.write(cmd)
    buf = b""
    per = []
    t0 = time.time()
    while time.time() - t0 < secs:
        n0 = len(buf)
        e = time.time() + 1
        while time.time() < e:
            buf += s.read(4096)
        per.append(len(buf) - n0)
    i = buf.find(b"<<START>>")
    print("%-26s bytes per second %s; START answers %d; text before the first: %r" % (
        label, per, buf.count(b"<<START>>"), buf[:i][:200] if i > 0 else b""))
    return buf


phase("START only", b"START %d d1\n" % int(time.time() * 1e6))
phase("CHANNELS 6", b"CHANNELS 6\n")
phase("CHANNELS 1-177", b"CHANNELS 1-177\n")
s.close()
