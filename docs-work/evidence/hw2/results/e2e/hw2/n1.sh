#!/bin/bash
# n1: four local sources at once by the short names, with known prior radios
D=~/e2e/hw2; cd $D
PY=~/esp32c5-venv/bin/python
devnums() { for d in /sys/bus/usb/devices/1-1.2.*; do [ -f $d/serial ] && printf "%s=%s " "$(cat $d/serial)" "$(cat $d/devnum)"; done; echo; }
mkdir -p /tmp/hw2/strace; rm -f /tmp/hw2/strace/*
echo "devnums before set: $(devnums)"
$PY tx.py /dev/ttyACM1 --mode-only 802154
$PY tx.py /dev/ttyACM2 --mode-only WIFI
$PY tx.py /dev/ttyACM3 --mode-only WIFI
sleep 1
for p in 0 1 2 3; do timeout 10 $PY probe.py /dev/ttyACM$p --secs 0.3 | python3 -c "import json,sys; d=json.load(sys.stdin); print(\"prior radio\", d[\"port\"], \"linktype\", d[\"start\"][\"linktype\"])"; done
echo "devnums before kismet: $(devnums)"
NOSTOP=1 ./run.sh n1 60 --confdir /tmp/hw2/etc-wrap -c esp32c5-ttyACM0 -c esp32c5-ttyACM1 -c esp32c5zigbee-ttyACM2 -c esp32c5btle-ttyACM3
echo "devnums after 60 s: $(devnums)"
