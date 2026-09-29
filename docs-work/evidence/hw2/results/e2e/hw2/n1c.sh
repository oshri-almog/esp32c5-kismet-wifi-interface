#!/bin/bash
D=~/e2e/hw2; cd $D
PY=~/esp32c5-venv/bin/python
devnums() { for d in /sys/bus/usb/devices/1-1.2.*; do [ -f $d/serial ] && printf "%s=%s " "$(cat $d/serial)" "$(cat $d/devnum)"; done; echo; }
$PY tx.py /dev/ttyACM0 --mode-only BLE
$PY tx.py /dev/ttyACM1 --mode-only WIFI
$PY tx.py /dev/ttyACM2 --mode-only WIFI
$PY tx.py /dev/ttyACM3 --mode-only WIFI
sleep 1
for p in 0 1 2 3; do timeout 10 $PY probe.py /dev/ttyACM$p --secs 0.3 | python3 -c "import json,sys; d=json.load(sys.stdin); print(\"prior radio\", d[\"port\"], \"linktype\", d[\"start\"][\"linktype\"])"; done
echo "devnums before kismet: $(devnums)"
NOSTOP=1 ./run.sh n1c 60 -c esp32c5-ttyACM0 -c esp32c5-ttyACM1 -c esp32c5zigbee-ttyACM2 -c esp32c5btle-ttyACM3
python3 kq.py devs > n1c.devs.txt; echo "devices per phy: $(head -1 n1c.devs.txt)"
python3 kq.py srcjson > n1c.src.json
./k.sh stop
echo "devnums after: $(devnums)"
