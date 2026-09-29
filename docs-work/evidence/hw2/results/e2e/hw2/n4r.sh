#!/bin/bash
# n4r: channel=20,channel_hop=false on Python remote and C remote zigbee sources, with TXTEST 200 from another board
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
PY=~/esp32c5-venv/bin/python
DEF="esp32c5zigbee-ttyACM2:channel=20,channel_hop=false"
./k.sh start n4r >/dev/null || exit 1
(cd ~/esp32c5-kismet-wifi-interface; exec $PY -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source "$DEF" --debug > $D/n4r.py.log 2>&1) &
PP=$!
python3 kq.py waitrun esp32c5zigbee-ttyACM2 20 >/dev/null; sleep 2
echo "### Python remote: $(python3 kq.py src | cut -c1-150)"
$PY tx.py /dev/ttyACM3 20 200
sleep 4; echo "### after TXTEST: $(python3 kq.py src | cut -c1-110)"
kill -TERM $PP; wait $PP; sleep 1
KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 setsid strace -f -tt -e trace=write -o n4r.c.strace $C --connect 127.0.0.1:2501 --source "$DEF" > n4r.c.log 2>&1 &
CP=$!
for i in $(seq 1 60); do python3 kq.py src | grep -q "run=1" && break; sleep 0.25; done; sleep 6
echo "### C remote: $(python3 kq.py src | cut -c1-150)"
$PY tx.py /dev/ttyACM3 20 200 --back-to-wifi
sleep 8; echo "### after TXTEST: $(python3 kq.py src | cut -c1-110)"
python3 kq.py devs 802.15.4
kill -TERM -$CP; wait
./k.sh stop >/dev/null
echo "### C helper serial writes"; grep -o "write(3, \"[A-Z][^\"]*" n4r.c.strace | sort | uniq -c
echo "### Python helper debug lines about channels"; grep -i "chan\|CONFIG" n4r.py.log | head -8 | cut -c1-200
