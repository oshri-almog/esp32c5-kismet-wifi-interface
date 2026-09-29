#!/usr/bin/env python3
"""tx.py PORT CHANNEL COUNT [--back-to-wifi] [--mode-only MODE]

Opens PORT with DTR/RTS released before open, puts the board in MODE 802154, CHANNELS <ch>,
TXTEST <count>, waits for the frames to go out, then (with --back-to-wifi) MODE WIFI.
Prints timestamped steps.
"""
import sys
import time

import serial


def log(msg):
    print("%.3f %s" % (time.time(), msg), flush=True)


def open_port(path):
    ser = serial.Serial()
    ser.port = path
    ser.baudrate = 115200
    ser.timeout = 0.1
    ser.write_timeout = 2
    ser.exclusive = True
    ser.open()
    # as board.open_serial on POSIX: the kernel raised both lines at open; RTS goes first
    ser.rts = False
    ser.dtr = False
    return ser


def drain(ser, secs):
    end = time.time() + secs
    buf = bytearray()
    while time.time() < end:
        buf += ser.read(4096)
    return buf


def main():
    port = sys.argv[1]
    if "--mode-only" in sys.argv:
        mode = sys.argv[sys.argv.index("--mode-only") + 1]
        ser = open_port(port)
        log("open %s" % port)
        ser.write(("MODE %s\n" % mode).encode())
        buf = drain(ser, 1.5)
        log("MODE %s sent; boot marker seen: %s" % (mode, b"<<START>>\n" in buf))
        ser.close()
        return
    ch, count = int(sys.argv[2]), int(sys.argv[3])
    ser = open_port(port)
    log("open %s" % port)
    ser.write(b"MODE 802154\n")
    buf = drain(ser, 1.5)
    log("MODE 802154 sent; boot marker seen: %s" % (b"<<START>>\n" in buf))
    ser.write(("CHANNELS %d\n" % ch).encode())
    time.sleep(0.3)
    ser.write(("TXTEST %d\n" % count).encode())
    log("TXTEST %d on channel %d sent" % (count, ch))
    drain(ser, max(2.0, count * 0.012))
    log("TXTEST done (waited)")
    if "--back-to-wifi" in sys.argv:
        ser.write(b"MODE WIFI\n")
        buf = drain(ser, 1.5)
        log("MODE WIFI sent; boot marker seen: %s" % (b"<<START>>\n" in buf))
    ser.close()


if __name__ == "__main__":
    main()
