#!/usr/bin/env python3
"""openers.py PORT: try a plain os.open, a pyserial open (no exclusive), a pyserial exclusive open; print results."""
import os, sys, errno
import serial
port = sys.argv[1]
try:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    print("os.open O_RDWR|O_NOCTTY: OPENED (fd %d)" % fd); os.close(fd)
except OSError as e:
    print("os.open O_RDWR|O_NOCTTY: errno %d %s (%s)" % (e.errno, errno.errorcode.get(e.errno), e.strerror))
for excl in (False, True):
    s = serial.Serial(); s.port = port; s.exclusive = excl
    try:
        s.open(); s.rts = False; s.dtr = False
        print("pyserial open exclusive=%s: OPENED" % excl); s.close()
    except Exception as e:
        print("pyserial open exclusive=%s: %s" % (excl, e))
