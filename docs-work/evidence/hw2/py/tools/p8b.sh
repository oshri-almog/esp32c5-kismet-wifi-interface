#!/bin/bash
# p8b: the silent board (ROM download mode) as a C local source, in a fresh Kismet, for comparison with p8
D=~/e2e/py; cd $D
PY=~/esp32c5-venv/bin/python
BYID2=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:D8:0C-if00
$PY -m esptool --chip esp32c5 -p $BYID2 --after no-reset chip-id 2>&1 | tail -1
sleep 1
./k.sh start p8b -c esp32c5-ttyACM2 || exit 1
T0=$(cat p8b.t0)
for i in $(seq 1 45); do sleep 1; echo "t+$i $(python3 kq.py src | awk '{print $1,$2,$3,$5}')"; done | awk 'NR%5==0'
python3 kq.py src | cut -c1-300
./k.sh stop > /dev/null
grep -v "Detected new\|802.11 Wi-Fi device" p8b.log | grep -i "ttyACM2\|answer\|capturing\|launched\|re-open\|IPC" | awk -v t=$T0 '{printf "%+7.2f %s\n", $1-t, substr($0, index($0,$2))}' | cut -c1-250
$PY -m esptool --chip esp32c5 -p $BYID2 chip-id 2>&1 | tail -1
sleep 2; timeout 20 $PY ~/e2e/hw2/probe.py /dev/ttyACM2 --secs 1 | cut -c1-160
