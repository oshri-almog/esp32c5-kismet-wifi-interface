#!/bin/bash
# b3.sh CASE HELPER : kill -TERM the parent of a C remote helper with retry; does its capture child
# end and release the port?
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY:name=c6-b3,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep 6
C=$(pgrep -P $P)
echo "$(ts) parent $P, capture child $C; flock holders of $TTY: $(lock_pids /dev/$TTY | tr "\n" " ")"
kill -TERM $P
echo "$(ts) kill -TERM $P (the parent)"
for i in $(seq 1 30); do
    sleep 0.1
    ca=no; kill -0 $C 2>/dev/null && ca="yes (ppid $(ps -o ppid= -p $C | tr -d " "))"
    pa=no; kill -0 $P 2>/dev/null && pa=yes
    echo "$(ts) parent alive=$pa; child alive=$ca; flock holders: $(lock_pids /dev/$TTY | tr "\n" " ")"
done
[ -n "$C" ] && kill -0 $C 2>/dev/null && { echo "$(ts) child $C still running: killing it (by pid)"; kill -9 $C; }
cat $LOG/helper.log | grep -v "_lws_smd_msg_send\|N: "
stop_all
rm -rf $WORK
