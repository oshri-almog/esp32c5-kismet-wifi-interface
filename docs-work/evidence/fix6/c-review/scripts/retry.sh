#!/bin/bash
# retry.sh CASE HELPER SECONDS : a remote helper with retry (the default) on a fake board; is it capturing?
. /tmp/crev/lib.sh
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
$2 --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5-$TTY:name=rv-retry,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep $3
echo "$(ts) running=$(src_field rv-retry kismet.datasource.running) packets=$(src_field rv-retry kismet.datasource.num_packets)"
grep -v "_lws_smd_msg_send\|N: " $LOG/helper.log
stop_all; rm -rf $WORK
