#!/bin/bash
# b4.sh CASE HELPER : a local source holds the board; a remote helper for the same board is started.
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
WORKP=$WORK/port
start_fake one $WORKP WIFI
start_kismet --no-logging -c "esp32c5-$TTY:name=c6-local,channel=6,channel_hop=false" || exit 1
srcs() { api /datasource/all_sources.json | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print(\"%s running=%s remote=%s packets=%s uuid=%s\" % (s.get(\"kismet.datasource.name\"), s.get(\"kismet.datasource.running\"), s.get(\"kismet.datasource.remote\", s.get(\"kismet.datasource.ipc_pid\")), s.get(\"kismet.datasource.num_packets\"), s.get(\"kismet.datasource.uuid\")))
" | tr "\n" ";"; }
for i in $(seq 1 20); do sleep 0.5; srcs | grep -q "packets=[1-9]" && break; done
echo "$(ts) local source: $(srcs) flock holders of $TTY: $(lock_pids /dev/$TTY | tr "\n" " ")"
UUID=$(api /datasource/all_sources.json | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"kismet.datasource.uuid\"])")
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY:name=c6-remote,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
H=$!; STARTED="$STARTED $H"
echo "$(ts) remote helper started (pid $H) for the same board"
for i in $(seq 1 6); do
    sleep 2
    echo "$(ts) t=$((i*2)) $(srcs) flock holders: $(lock_pids /dev/$TTY | tr "\n" " ")"
done
echo "$(ts) close_source.cmd on the local source ($UUID): $(api /datasource/by-uuid/$UUID/close_source.cmd >/dev/null; echo done)"
for i in $(seq 1 14); do
    sleep 0.5
    echo "$(ts) +$(echo "$i*0.5" | bc)s $(srcs) flock holders: $(lock_pids /dev/$TTY | tr "\n" " ")"
done
echo "--- kismet log"; grep -n "c6-\|matches existing\|will be closed" $LOG/kismet.log | tail -15
echo "--- helper stderr"; grep -v "_lws_smd_msg_send" $LOG/helper.log
stop_all
rm -rf $WORK
