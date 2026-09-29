#!/bin/bash
# n10: list_interfaces rows: idle, one board held by a local source, one by a Python remote, one by a C remote; then mask_datasource_interface
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
li() { python3 ~/e2e/hw2/li.py; }
./k.sh start n10 >/dev/null || exit 1
echo "### idle"; li
python3 kq.py post /datasource/add_source.cmd "{\"definition\":\"esp32c5-ttyACM0\"}" > /dev/null; python3 kq.py waitrun esp32c5-ttyACM0 15 >/dev/null
echo "### ttyACM0 held by a local source (add_source.cmd)"; li
(cd ~/esp32c5-kismet-wifi-interface; exec ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source esp32c5zigbee-ttyACM1 > $D/n10.py.log 2>&1) &
PP=$!
KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 setsid $C --connect 127.0.0.1:2501 --source esp32c5btle-ttyACM2 > n10.c.log 2>&1 &
CP=$!
python3 kq.py waitrun esp32c5btle-ttyACM2 20 >/dev/null
echo "### plus ttyACM1 held by Python remote (zigbee), ttyACM2 by C remote (btle)"; li
python3 kq.py src | awk "{print \$1,\$2,\$3,\$5}"
kill -TERM $PP; kill -TERM -$CP; wait
./k.sh stop >/dev/null
./k.sh start n10m --confdir /tmp/hw2/etc-mask >/dev/null || exit 1
echo "### with the three mask_datasource_interface lines for ttyACM3"; li
grep -h "Loading config override\|mask" n10m.log | cut -c1-160
./k.sh stop >/dev/null
