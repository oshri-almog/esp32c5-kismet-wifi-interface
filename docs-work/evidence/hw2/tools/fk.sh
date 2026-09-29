#!/bin/bash
# fk.sh TAG SECS DEF [TXPORT]: one local source; pcapng streamed from REST; sources polled at 2 Hz for SECS.
# With TXPORT: once the source logs "capturing", TXTEST 200 on channel 20 from TXPORT (then back to Wi-Fi).
# Saves TAG.{log,poll,pcapng,allsrc.json,devices.json,msgs.json,tx.out}.  env EXTRA: more kismet args
D=~/e2e/hw2; cd $D
TAG=$1; SECS=$2; DEF=$3; TX=$4
./k.sh start $TAG -c "$DEF" $EXTRA || exit 1
curl -sN -u admin:hw2-Pass-99 http://127.0.0.1:2501/pcap/all_packets.pcapng -o $TAG.pcapng &
CURL=$!
python3 kq.py poll $TAG.poll $SECS 2 &
POLL=$!
if [ -n "$TX" ]; then
  for i in $(seq 1 100); do grep -q "capturing (zigbee)" $TAG.log && break; sleep 0.2; done
  grep "capturing (zigbee)" $TAG.log | head -1
  ~/esp32c5-venv/bin/python tx.py $TX 20 200 --back-to-wifi > $TAG.tx.out 2>&1
  cat $TAG.tx.out
fi
wait $POLL
python3 kq.py src
curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/datasource/all_sources.json > $TAG.allsrc.json
curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/devices/views/all/devices.json > $TAG.devices.json
curl -s -u admin:hw2-Pass-99 http://127.0.0.1:2501/messagebus/last-time/0/messages.json > $TAG.msgs.json
python3 kq.py devs
kill $CURL 2>/dev/null; wait $CURL 2>/dev/null
./k.sh stop
python3 summ.py $TAG | grep -v "Detected new" | grep -v "^ *[0-9.]* \(INFO: \(Generated\|Setting server\|PHY80211\|(HTTPD)\|Serving\|Enabling\|Sources will\|Saving\|Data sources passed\)\|DEBUG\|ERROR: Tried to re-register\)" | grep -v "^[0-9. ]*$" | grep -v "KISMET IS SHUTTING\|restart networking\|interface (varies\|typically one of\|sudo \|^[0-9. ]*or$\|nmcli\|EXITING"
python3 pcapng.py $TAG.pcapng | python3 -c "import json,sys; d=json.load(sys.stdin); print('pcapng', d['interfaces'], d['packets']); [print(' ', k, dict(sorted(v.items(), key=lambda x: -x[1])[:14])) for k, v in d['per_interface'].items()]"
