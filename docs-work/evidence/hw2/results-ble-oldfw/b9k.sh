#!/bin/bash
# b9k.sh TAG SECS DEF: one BTLE source in Kismet, pcapng streamed from REST for SECS, sources polled at 2 Hz,
# then full source + device JSON and the "Detected new BTLE device" lines.  env: EXTRA="..." more kismet args
D=~/e2e/hw2; cd $D
TAG=$1; SECS=$2; DEF=$3
./k.sh start $TAG -c "$DEF" $EXTRA || exit 1
curl -sN -u admin:hw2-Pass-99 http://127.0.0.1:2501/pcap/all_packets.pcapng -o $TAG.pcapng &
CURL=$!
python3 kq.py poll $TAG.poll $SECS 2
python3 kq.py src
curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/datasource/all_sources.json > $TAG.allsrc.json
curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/devices/views/all/devices.json > $TAG.devices.json
curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/messagebus/last-time/0/messages.json > $TAG.msgs.json
kill $CURL 2>/dev/null; wait $CURL 2>/dev/null
./k.sh stop
grep -c "Detected new BTLE device" $TAG.log
python3 summ.py $TAG | grep -v "Detected new" | head -40
