#!/bin/bash
# suid.sh CASE HELPER : the helper installed setuid root, run by a user (nobody) with retry, on a port of
# the user (the fake board run by nobody too, so its pseudo-terminal is nobody:tty 0620). kill -TERM the
# parent: does the capture child end with it (PR_SET_PDEATHSIG)?
. /tmp/crev/lib.sh
setup_case $1
D=$(mktemp -d /tmp/crev/suid.XXXXXX); chmod 755 $D
cp $2 $D/cap; chown root:root $D/cap; chmod 4755 $D/cap
PD=$(mktemp -d /tmp/crev/pd.XXXXXX); chmod 777 $PD
start_kismet --no-logging || exit 1
rm -f $PD/port
python3 $REPO/tools/fake_board.py $PD/port WIFI > $LOG/fake.log 2>&1 &
FPID=$!; STARTED="$STARTED $FPID"
for i in $(seq 1 50); do grep -q booted $LOG/fake.log 2>/dev/null && break; sleep 0.1; done
TTY=$(readlink -f $PD/port | sed "s|^/dev/||"); ls -l /dev/$TTY
setpriv --reuid=nobody --regid=nogroup --clear-groups $D/cap --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY:name=rv-suid,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep 6
C=$(pgrep -P $P)
echo "$(ts) parent $P (uid/euid $(ps -o ruid=,euid= -p $P | xargs)), capture child $C; running=$(src_field rv-suid kismet.datasource.running) packets=$(src_field rv-suid kismet.datasource.num_packets); flock holders: $(lock_pids /dev/$TTY | tr "\n" " ")"
kill -TERM $P
echo "$(ts) kill -TERM $P (the parent)"
sleep 2
ca=no; kill -0 $C 2>/dev/null && ca="yes (ppid $(ps -o ppid= -p $C | tr -d " "))"
echo "$(ts) parent alive=$(kill -0 $P 2>/dev/null && echo yes || echo no); child alive=$ca; flock holders: $(lock_pids /dev/$TTY | tr "\n" " "); packets=$(src_field rv-suid kismet.datasource.num_packets)"
[ -n "$C" ] && kill -0 $C 2>/dev/null && { echo "$(ts) child $C still running: killing it by pid"; kill -9 $C; }
grep -v "_lws_smd_msg_send\|N: " $LOG/helper.log
stop_all
rm -rf $WORK $D $PD
