#!/bin/bash
# a2s.sh CASE HELPER SECONDS : eviction, with the evicted helper under strace; ss and flock watched
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port1 WIFI; TTY1=$TTY
start_fake two $WORK/port2 WIFI; TTY2=$TTY
UUID=E5C50001-0000-0000-0000-00000000A2A2
strace -f -tt -o $LOG/strace-one.txt -e trace=recvfrom,sendto,close,shutdown,exit_group,kill,wait4 $HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY1:name=c6-a2,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper-one.log 2>&1 &
S1=$!; STARTED="$STARTED $S1"
sleep 6
H1=$(pgrep -P $S1); C1=$(pgrep -P $H1)
echo "$(ts) helper one: parent $H1, capture child $C1; flock holders of $TTY1: $(lock_pids /dev/$TTY1 | tr "\n" " ")"
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY2:name=c6-a2b,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper-two.log 2>&1 &
H2=$!; STARTED="$STARTED $H2"
echo "$(ts) helper two started (pid $H2), same uuid on $TTY2"
for i in $(seq 1 $3); do
    sleep 1
    alive=no; [ -n "$C1" ] && kill -0 $C1 2>/dev/null && alive=yes
    echo "$(ts) t=$i child $C1 alive=$alive; flock holders of $TTY1: $(lock_pids /dev/$TTY1 | tr "\n" " "); helper one children: $(pgrep -P $H1 | tr "\n" " "); conns: $(ss -tnp | grep -c "kismet_cap_esp3")"
done
grep -n "c6-a2" $LOG/kismet.log | tail -20
echo "--- helper one"; grep -v "^\[20" $LOG/helper-one.log | tail -15
stop_all
rm -rf $WORK
