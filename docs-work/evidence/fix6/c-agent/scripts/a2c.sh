#!/bin/bash
# a2c.sh CASE HELPER SECONDS : close_source.cmd on a C remote source; when does the capture child
# exit and release the flock, and does the helper reconnect?
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port1 WIFI; TTY1=$TTY
UUID=E5C50001-0000-0000-0000-00000000A2C0
strace -f -tt -o $LOG/strace.txt -e trace=recvfrom,sendto,close,exit_group,wait4 $HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY1:name=c6-a2c,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
S1=$!; STARTED="$STARTED $S1"
sleep 6
H1=$(pgrep -P $S1); C1=$(pgrep -P $H1)
echo "$(ts) helper: parent $H1, capture child $C1; flock holders of $TTY1: $(lock_pids /dev/$TTY1 | tr "\n" " ")"
echo "$(ts) close_source.cmd: $(api /datasource/by-uuid/$UUID/close_source.cmd | head -c 200)"
for i in $(seq 1 $(($3 * 4))); do
    sleep 0.25
    alive=no; kill -0 $C1 2>/dev/null && alive=yes
    echo "$(ts) child $C1 alive=$alive; flock holders: $(lock_pids /dev/$TTY1 | tr "\n" " "); helper children: $(pgrep -P $H1 | tr "\n" " "); source running: $(api /datasource/by-uuid/$UUID/source.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(\"kismet.datasource.running\"), d.get(\"kismet.datasource.num_packets\"))" 2>/dev/null)"
done
grep -n "c6-a2c" $LOG/kismet.log | tail -12
echo "--- helper"; grep -v "^\[20" $LOG/helper.log | tail -15
stop_all
rm -rf $WORK
