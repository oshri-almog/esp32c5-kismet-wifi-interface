#!/bin/bash
# b4b.sh CASE HELPER : a python fcntl.flock holder; the remote helper over websocket and TCP, with
# and without retry
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
python3 -c "import fcntl,os,sys,time; fd=os.open(\"/dev/$TTY\", os.O_RDWR|os.O_NOCTTY); fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB); print(\"holding\", flush=True); time.sleep(600)" > $LOG/holder.log 2>&1 &
HOLD=$!; STARTED="$STARTED $HOLD"
sleep 1
echo "$(ts) holder pid $HOLD; flock holders of $TTY: $(lock_pids /dev/$TTY | tr "\n" " ")"
echo "== websocket, --disable-retry"
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS --disable-retry --source "esp32c5-$TTY:name=c6-b4b" 2>&1 | grep -v _lws_smd
echo "exit status $?"
( $HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS --disable-retry --source "esp32c5-$TTY:name=c6-b4b" >/dev/null 2>&1; echo "exit status (websocket, no retry): $?" )
echo "== legacy TCP, --disable-retry"
( $HELPER --tcp --connect 127.0.0.1:$TCP_PORT --disable-retry --source "esp32c5-$TTY:name=c6-b4b" 2>&1 | grep -v _lws_smd; echo "exit status (TCP, no retry): ${PIPESTATUS[0]}" )
echo "== legacy TCP, with retry, for 12 s"
$HELPER --tcp --connect 127.0.0.1:$TCP_PORT --source "esp32c5-$TTY:name=c6-b4b" > $LOG/tcp-retry.log 2>&1 &
T=$!; STARTED="$STARTED $T"
sleep 7
kill $HOLD; echo "$(ts) holder $HOLD killed (the port is free)"
sleep 7
cat $LOG/tcp-retry.log
echo "$(ts) sources: $(api /datasource/all_sources.json | python3 -c "import json,sys; print([(s[\"kismet.datasource.name\"], s[\"kismet.datasource.running\"], s[\"kismet.datasource.num_packets\"]) for s in json.load(sys.stdin)])")"
stop_all
rm -rf $WORK
