#!/usr/bin/env python3
"""raw.py PORT SECS [LINE ...]: open (RTS then DTR released), read SECS, then for each LINE send it and read SECS.
Prints byte counts, marker count, first bytes, and whether the port vanished."""
import sys, time, serial
port, secs = sys.argv[1], float(sys.argv[2])
ser = serial.Serial()
ser.port = port; ser.baudrate = 115200; ser.timeout = 0.1
ser.exclusive = True
import os
if os.environ.get("ORDER") == "pre":
    ser.dtr = False; ser.rts = False
    ser.open()
else:
    ser.open(); ser.rts = False; ser.dtr = False
def rd(label):
    t = time.time(); buf = bytearray(); err = None
    while time.time() - t < secs:
        try:
            buf += ser.read(4096)
        except Exception as e:
            err = repr(e); break
    print("%.3f %s: %d bytes, markers %d, head %r, err %s" % (time.time(), label, len(buf), buf.count(b"<<START>>"), bytes(buf[:80]), err), flush=True)
    return err
if rd("idle") is None:
    for line in sys.argv[3:]:
        ser.write((line + "\n").encode()); ser.flush()
        if rd("after %r" % line):
            break
ser.close()
