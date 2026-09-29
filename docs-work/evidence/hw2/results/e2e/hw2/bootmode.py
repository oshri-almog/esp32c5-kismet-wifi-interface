#!/usr/bin/env python3
"""bootmode.py PORT DELAY MODE: reset the board by opening with pyserial pre-open line settings (DTR then RTS
cleared = reset), send "MODE <MODE>" DELAY s after open, then START every 2 s for 10 s; report answers."""
import sys, time, serial, os
port, delay, mode = sys.argv[1], float(sys.argv[2]), sys.argv[3]
ser = serial.Serial(); ser.port = port; ser.baudrate = 115200; ser.timeout = 0.05; ser.exclusive = True
ser.dtr = False; ser.rts = False
t0 = time.time(); ser.open()
buf = bytearray(); sent_mode = False; n = 0; answers = []; last = 0; err = None
while time.time() - t0 < 12:
    try:
        buf += ser.read(4096)
    except Exception as e:
        err = repr(e); break
    el = time.time() - t0
    if not sent_mode and el >= delay:
        ser.write(("MODE %s\n" % mode).encode()); sent_mode = True; tm = el
    if sent_mode and el - tm > 1.0 and el - last > 2.0:
        n += 1; nonce = "n%07d" % n; last = el
        ser.write(("START 1 %s\n" % nonce).encode())
        answers.append((round(el, 2), nonce))
got = [(t, nc, (b"<<START>> " + nc.encode()) in buf) for t, nc in answers]
print("delay %.2f mode %s: boot markers %d, ROM banners %d, starts %s, bytes %d, err %s" % (
    delay, mode, buf.count(b"<<START>>\n"), buf.count(b"ESP-ROM"), got, len(buf), err))
ser.close()
