#!/bin/bash
# b1.sh CASE HELPER : a silent board behind a C remote helper (websocket, retry): does the 15 s
# reason reach Kismet, and does the helper end the connection and come back?
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake s $WORK/port WIFI --silent
T0=$(date +%s.%N)
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY:name=c6-b1" > $LOG/helper.log 2>&1 &
H=$!; STARTED="$STARTED $H"
echo "$(ts) helper started (parent $H)"
for i in $(seq 1 13); do
    sleep 2
    echo "$(ts) t=$((i*2)) capture children: $(pgrep -P $H | tr "\n" " ") flock holders: $(lock_pids /dev/$TTY | tr "\n" " ")"
done
echo "--- kismet log"; grep -n "c6-b1" $LOG/kismet.log
echo "--- helper"; grep -v "_lws_smd" $LOG/helper.log
stop_all
rm -rf $WORK
