#!/bin/bash
# a1.sh CASE HELPER : websocket packet cadence of a C remote helper
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake a1 $WORK/port WIFI
echo "helper: $HELPER" > $LOG/helper.log
T0=$(date +%s.%N)
strace -f -tt -e trace=sendto,write -o $LOG/strace.txt $HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY:name=c6-$1,channel=6,channel_hop=false" >> $LOG/helper.log 2>&1 &
HPID=$!; STARTED="$STARTED $HPID"
echo "helper started at $(date -d @$T0 +%H:%M:%S.%N | cut -c1-12) (strace pid $HPID)"
python3 /root/c-agent-fix6/poll.py c6-$1 20 5 $KUSER $KPASS $API > $LOG/poll.txt
stop_all
rm -rf $WORK
# first packet time and gaps
python3 - $LOG/poll.txt <<"PY"
import sys
rows=[l.split() for l in open(sys.argv[1])]
first=None; prev=None; flat=0; maxflat=0; incs=0
for r in rows:
    try: n=int(r[1])
    except: continue
    t=float(r[0])
    if n>0 and first is None: first=t
    if prev is not None:
        if n==prev and first is not None: flat+=1; maxflat=max(maxflat,flat)
        else:
            if n>prev: incs+=1
            flat=0
    prev=n
print("first packet seen by Kismet at %.2f s; polls with an increase: %d of %d; longest flat run after the first packet: %d polls (%.1f s)" % (first if first is not None else -1, incs, len(rows), maxflat, maxflat/5.0))
PY
