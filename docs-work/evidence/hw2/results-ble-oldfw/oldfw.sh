#!/bin/bash
# oldfw.sh VER: board 38:44:BE:BF:D8:0C (ttyACM2) on an old image; C local btle / zigbee (+TXTEST) / wifi, then
# Python remote btle and zigbee.  Prints the helper-related Kismet log lines with times relative to each start.
D=~/e2e/hw2; cd $D
V=$1; T=o${V//./}
TX=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:C9:10-if00
rel() {  # rel TAG: esp32c5 lines of TAG.log relative to TAG.t0
  python3 - "$1" <<'PY'
import sys
tag = sys.argv[1]; t0 = float(open(tag + ".t0").read())
for l in open(tag + ".log", errors="replace"):
    p = l.split(" ", 1)
    if len(p) < 2 or ("esp32c5" not in p[1] and "EXIT" not in p[1]) or "Detected new" in p[1] or "advertising" in p[1]:
        continue
    print("%7.2f %s" % (float(p[0]) - t0, p[1].rstrip()[:300]))
PY
}
for r in btle zigbee wifi; do
  case $r in btle) DEF=esp32c5btle-ttyACM2; X="";; zigbee) DEF="esp32c5zigbee-ttyACM2:channel=20,channel_hop=false"; X=$TX;; wifi) DEF=esp32c5-ttyACM2; X="";; esac
  echo "######## C local $r ($DEF)"
  ./fk.sh $T.$r 40 "$DEF" $X > $T.$r.out 2>&1
  grep "run=" $T.$r.out; grep "pcapng \[" $T.$r.out; grep -A1 "pcapng \[" $T.$r.out | tail -1 | cut -c1-200
  rel $T.$r
done
for r in btle zigbee; do
  case $r in btle) SRC=esp32c5btle-ttyACM2;; zigbee) SRC=esp32c5zigbee-ttyACM2;; esac
  echo "######## Python remote $r"
  ./ab.sh $T.py$r 30 $SRC py > $T.py$r.out 2>&1
  tail -1 $T.py$r.out
  rel $T.py$r
  echo "--- helper log"; cut -c1-300 $T.py$r.1py.log
done
pgrep -af "kismet|esp32c5" | grep -v avahi
