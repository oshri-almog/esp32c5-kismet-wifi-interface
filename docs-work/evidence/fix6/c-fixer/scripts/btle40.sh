#!/bin/bash
# btle40.sh CASE HELPER : a BTLE remote source told to tune to channel 40 (not an advertising channel)
. $(dirname $0)/lib.sh
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port BLE
$2 --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5btle-$TTY:name=fx-b40" > $LOG/helper.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep 8
uuid=$(src_field fx-b40 kismet.datasource.uuid)
echo "$(ts) before: running=$(src_field fx-b40 kismet.datasource.running) channel=$(src_field fx-b40 kismet.datasource.channel) packets=$(src_field fx-b40 kismet.datasource.num_packets)"
code=$(curl -s -o $LOG/set40.json -w "%{http_code}" -u "$KUSER:$KPASS" --data-urlencode "json={\"channel\": \"40\"}" "$API/datasource/by-uuid/$uuid/set_channel.cmd")
echo "$(ts) set_channel 40: HTTP $code"
sleep 3
echo "$(ts) after: running=$(src_field fx-b40 kismet.datasource.running) error=$(src_field fx-b40 kismet.datasource.error) error_reason=$(src_field fx-b40 kismet.datasource.error_reason) channel=$(src_field fx-b40 kismet.datasource.channel) packets=$(src_field fx-b40 kismet.datasource.num_packets)"
echo "--- kismet log"; grep -n "fx-b40\|channel 40" $LOG/kismet.log | tail -8
echo "--- helper log"; grep -v "_lws_smd_msg_send" $LOG/helper.log | tail -8
stop_all; rm -rf $WORK
