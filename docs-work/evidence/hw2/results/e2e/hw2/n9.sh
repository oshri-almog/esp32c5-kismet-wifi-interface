#!/bin/bash
# n9: short names and by-id paths in all three setups; hardware label / interface / capif per setup
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
B0=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_10:BD:A3:CF:05:40-if00
B1=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:C9:10-if00
./k.sh start n9 -c "esp32c5:device=$B0" || exit 1
KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 $C --connect 127.0.0.1:2501 --source esp32c5zigbee-ttyACM2 > n9.c.log 2>&1 &
CP=$!
(cd ~/esp32c5-kismet-wifi-interface; exec ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source esp32c5btle-ttyACM3 --source "esp32c5:device=$B1" > $D/n9.py.log 2>&1) &
PP=$!
python3 kq.py poll n9.poll 25 5
python3 kq.py srcjson | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print(json.dumps({k: s.get(k) for k in (\"name\",\"definition\",\"interface\",\"capture_interface\",\"hardware\",\"uuid\",\"remote\",\"running\",\"num_packets\",\"dlt\",\"channel\",\"hopping\")}))
    print(\"   hop_channels:\", len(s.get(\"hop_channels\") or []), (s.get(\"hop_channels\") or [])[:3])
"
python3 kq.py devs
kill -TERM $CP $PP; sleep 1; for p in $(pgrep -P $CP); do kill -TERM $p; done; wait
./k.sh stop
grep -h "capturing\|connected\|opened" n9.log | grep -v Detected | cut -c1-200
echo "### py log"; cat n9.py.log | cut -c1-200
echo "### c log"; grep -v "lws_\|__lws\|_lws" n9.c.log
