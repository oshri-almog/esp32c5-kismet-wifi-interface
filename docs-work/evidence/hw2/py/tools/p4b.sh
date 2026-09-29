#!/bin/bash
# p4b: does a remote source that reconnects under a known UUID keep options of an earlier definition?
# And channel=36 without channel_hop=false in a fresh Kismet (start at 36, then hop).
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
show() { python3 kq.py srcjson | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print('   ', {k: s.get(k) for k in ('name','definition','running','channel','hopping','hop_rate')}, 'hop_channels', len(s.get('hop_channels') or []))"; }
chw() { echo "    CHANNELS writes: $(grep -c 'CHANNELS' $1); first: $(grep -o 'CHANNELS [0-9]*' $1 | head -8 | tr '\n' ' ')"; }
./k.sh start p4b || exit 1
n=0
for def in "esp32c5-ttyACM0:channel=36,channel_hop=false,name=lock36" "esp32c5-ttyACM0" "C:esp32c5-ttyACM0" "esp32c5-ttyACM0:channel_hop=true" "esp32c5-ttyACM0:name=plain"; do
  n=$((n+1))
  echo "=== $n: $def"
  if [ "${def:0:2}" = "C:" ]; then
    KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=py-Pass-77 strace -f -tt -e trace=write -o $D/p4b.$n.strace $C --connect 127.0.0.1:2501 --source "${def:2}" > p4b.$n.log 2>&1 &
    P=$!
  else
    STRACE=$D/p4b.$n.strace ./pyh.sh $D/p4b.$n.log $PYA --source "$def" &
    P=$(pidof_log $D/p4b.$n.log)
  fi
  for i in $(seq 1 100); do python3 kq.py src | grep -q "run=1" && break; sleep 0.1; done
  sleep 6; show; chw $D/p4b.$n.strace
  grep -h "opening" p4b.$n.log | cut -c1-200
  kill -TERM $P; sleep 3; pkill -KILL -f "kismet_cap_esp32c5 --connect" 2>/dev/null
done
./k.sh stop
grep -h "Matching\|reconnected\|New remote" p4b.log | cut -c1-200
echo "##### fresh Kismet: channel=36 (no channel_hop=false)"
./k.sh start p4c || exit 1
STRACE=$D/p4c.strace ./pyh.sh $D/p4c.log $PYA --source "esp32c5-ttyACM0:channel=36" &
P=$(pidof_log $D/p4c.log)
for i in $(seq 1 100); do python3 kq.py src | grep -q "run=1" && break; sleep 0.1; done
sleep 6; show
grep 'CHANNELS' p4c.strace | head -8 | cut -c1-70; chw p4c.strace
kill -TERM $P; sleep 2
./k.sh stop
