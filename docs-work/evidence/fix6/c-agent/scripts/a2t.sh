#!/bin/bash
# a2t.sh CASE HELPER : the server closes the websocket but not the TCP connection. Does the capture
# child end (and release its port) once lws gives up on the close handshake?
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
python3 /root/c-agent-fix6/closing_ws_server.py 2602 > $LOG/server.log 2>&1 &
SPID=$!; STARTED="$STARTED $SPID"
sleep 0.5
start_fake one $WORK/port WIFI
$HELPER --connect 127.0.0.1:2602 --user u --password p --disable-retry \
    --source "esp32c5-$TTY:name=c6-a2t" > $LOG/helper.log 2>&1 &
H=$!; STARTED="$STARTED $H"
echo "$(ts) helper started (pid $H, --disable-retry: one process)"
for i in $(seq 1 30); do
    sleep 1
    alive=no; kill -0 $H 2>/dev/null && alive=yes
    echo "$(ts) t=$i helper alive=$alive; lines: $(grep -c . $LOG/helper.log)"
    [ $alive = no ] && break
done
cat $LOG/server.log
echo "--- helper"; cat $LOG/helper.log
stop_all
rm -rf $WORK
