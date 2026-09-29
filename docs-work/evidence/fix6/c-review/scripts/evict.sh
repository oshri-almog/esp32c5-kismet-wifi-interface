#!/bin/bash
# evict.sh CASE : helper one evicted by helper two (same uuid=); does Kismet go on reading helper one's websocket?
. /tmp/crev/lib.sh
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port1 WIFI; TTY1=$TTY
start_fake two $WORK/port2 WIFI; TTY2=$TTY
UUID=E5C50001-0000-0000-0000-0000000EE1EE
/tmp/crev/bin/cap_new --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY1:name=rv-e1,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper-one.log 2>&1 &
H1=$!; STARTED="$STARTED $H1"
sleep 5
C1=$(pgrep -P $H1)
P1=$(ss -tnp | grep "pid=$C1," | awk "{print \$4}" | sed "s/.*://")
echo "$(ts) helper one child $C1, local port $P1"
/tmp/crev/bin/cap_new --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY2:name=rv-e2,uuid=$UUID,channel=6,channel_hop=false" > $LOG/helper-two.log 2>&1 &
H2=$!; STARTED="$STARTED $H2"
for i in $(seq 1 16); do
    sleep 1
    echo "$(ts) t=$i: kismet side of helper one ws (Recv-Q Send-Q): $(ss -tn "sport = :$HTTP_PORT and dport = :$P1" | tail -n +2 | awk "{print \$2, \$3}") ; helper one side: $(ss -tn "sport = :$P1" | tail -n +2 | awk "{print \$2, \$3}"); child alive: $(kill -0 $C1 2>/dev/null && echo yes || echo no); fake one records sent: $(grep -c . $LOG/fake-one.log)"
done
grep -v "_lws_smd_msg_send" $LOG/helper-one.log | tail -5
stop_all; rm -rf $WORK
