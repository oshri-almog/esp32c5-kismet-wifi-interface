#!/bin/bash
# fr.sh TAG SECS SOURCE: the same --source first through the C remote helper, then through the Python remote helper,
# each for SECS, each with its own pcapng stream (TAG.c.pcapng, TAG.py.pcapng) and its own device dump.
D=~/e2e/hw2; cd $D
TAG=$1; SECS=$2; SRC=$3
C=~/kismet-install/bin/kismet_cap_esp32c5
./k.sh start $TAG || exit 1
phase() {  # phase NAME
  curl -sN -u admin:hw2-Pass-99 http://127.0.0.1:2501/pcap/all_packets.pcapng -o $TAG.$1.pcapng &
  CURL=$!
  python3 kq.py poll $TAG.$1.poll $SECS 2
  python3 kq.py src
  curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/devices/views/all/devices.json > $TAG.$1.devices.json
  curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/datasource/all_sources.json > $TAG.$1.allsrc.json
  python3 kq.py devs
  kill $CURL; wait $CURL 2>/dev/null
}
date +%s.%N > $TAG.tc
KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 setsid $C --connect 127.0.0.1:2501 --source "$SRC" > $TAG.c.log 2>&1 &
CP=$!
phase c
kill -TERM -$CP; wait $CP 2>/dev/null; echo "C helper exit=$?"
sleep 3
date +%s.%N > $TAG.tpy
(cd ~/esp32c5-kismet-wifi-interface; exec ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source "$SRC" > $D/$TAG.py.log 2>&1) &
PP=$!
phase py
kill -TERM $PP; wait $PP 2>/dev/null; echo "Python helper exit=$?"
./k.sh stop
echo "### kismet log (filtered)"; grep -v "Detected new\|advertising new\|advertising a new" $TAG.log | grep -i "esp32c5\|CRC\|impossible\|lost sync\|capturing\|remote\|error" | cut -c1-400
echo "### C helper log"; grep -v "lws_\|__lws\|_lws" $TAG.c.log | cut -c1-400
echo "### Python helper log"; cut -c1-400 $TAG.py.log
for p in c py; do echo "### $p pcapng"; python3 pcapng.py $TAG.$p.pcapng | python3 -c "import json,sys; d=json.load(sys.stdin); print('pcapng', d['interfaces'], d['packets']); [print(' ', k, dict(sorted(v.items(), key=lambda x: -x[1])[:10])) for k, v in d['per_interface'].items()]"; done
