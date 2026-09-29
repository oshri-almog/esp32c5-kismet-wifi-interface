#!/bin/bash
# a2.sh CASE HELPER : a second remote helper with the same uuid evicts the first; does the first
# one's capture child exit, release its port and reconnect?
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port1 WIFI; TTY1=$TTY
start_fake two $WORK/port2 WIFI; TTY2=$TTY
UUID=E5C50001-0000-0000-0000-00000000A2A2
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY1:name=c6-a2,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper-one.log 2>&1 &
H1=$!; STARTED="$STARTED $H1"
sleep 6
if [ -n "${STRACE1:-}" ]; then H1=$(pgrep -P $H1); fi
C1=$(pgrep -P $H1)
echo "$(ts) helper one: parent $H1, capture child $C1; flock holders of pts/${TTY1#pts/}: $(lock_pids /dev/$TTY1 | tr "\n" " ")"
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY2:name=c6-a2b,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper-two.log 2>&1 &
H2=$!; STARTED="$STARTED $H2"
echo "$(ts) helper two started (pid $H2), same uuid on $TTY2"
for i in $(seq 1 40); do
    sleep 0.5
    alive=no; [ -n "$C1" ] && kill -0 $C1 2>/dev/null && alive=yes
    echo "$(ts) t=$(echo "$i*0.5" | bc) child $C1 alive=$alive; flock holders of $TTY1: $(lock_pids /dev/$TTY1 | tr "\n" " "); children of helper one now: $(pgrep -P $H1 | tr "\n" " ")"
done
ss -tnp | grep ":$HTTP_PORT" > $LOG/ss.txt
grep -n "c6-a2\|matches existing\|still running\|will be closed\|closed" $LOG/kismet.log | tail -20
echo "--- helper one"; cat $LOG/helper-one.log | grep -v "^\[20" | tail -15
stop_all
rm -rf $WORK
