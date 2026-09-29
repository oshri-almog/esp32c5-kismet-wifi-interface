#!/bin/bash
# run.sh TAG SECS [kismet args...]  -- start Kismet, poll REST at 10 Hz for SECS, summarise, stop.
# env: NOSTOP=1 leaves Kismet running
D=$HOME/e2e/hw2
TAG=$1; SECS=$2; shift 2
cd $D
$D/k.sh start $TAG "$@" || exit 1
python3 $D/kq.py poll $D/$TAG.poll $SECS 10
python3 $D/kq.py src
python3 $D/kq.py srcjson > $D/$TAG.src.json
python3 $D/kq.py devs
python3 $D/summ.py $TAG
if [ -z "$NOSTOP" ]; then $D/k.sh stop; fi
