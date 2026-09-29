#!/usr/bin/env python3
"""diag2.py PORT MODE [MODE...]: for each MODE (WIFI, 802154, BLE): open without a reset, send MODE, wait 1.5 s,
send CHANNELS 6 for WIFI (the firmware's list otherwise), START, read 6 s; print the link type and the bytes per
second after the header."""
import os
import struct
import sys
import time

import serial

port = sys.argv[1]
for mode in sys.argv[2:]:
    s = serial.Serial()
    s.port = port
    s.baudrate = 115200
    s.timeout = 0.1
    s.exclusive = True
    s.open()
    s.rts = False
    s.dtr = False
    s.write(b"MODE %s\n" % mode.encode())
    boot = b""
    e = time.time() + 1.5
    while time.time() < e:
        boot += s.read(4096)
    if mode == "WIFI":
        s.write(b"CHANNELS 6\n")
        time.sleep(0.2)
    s.write(b"START %d d2\n" % int(time.time() * 1e6))
    buf = b""
    per = []
    for _ in range(6):
        n0 = len(buf)
        e = time.time() + 1
        while time.time() < e:
            buf += s.read(4096)
        per.append(len(buf) - n0)
    s.close()
    i = buf.find(b"<<START>> d2")
    lt = None
    if i >= 0:
        j = buf.index(b"\n", i) + 1
        lt = struct.unpack("<IHHiIII", buf[j:j + 24])[6]
    print("%s MODE %-6s: rebooted (boot marker) %s; START answered %s, link type %s; bytes per second %s" % (
        os.path.realpath(port), mode, b"<<START>>\n" in boot, i >= 0, lt, per), flush=True)
    time.sleep(1)
