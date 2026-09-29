#!/bin/bash
# btle40.sh CASE c|py : a BTLE remote source told to tune to channel 40 (not an advertising channel)
. /tmp/crev/lib.sh
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port BLE
if [ "$2" = c ]; then
    /tmp/crev/bin/cap_new --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
        --source "esp32c5btle-$TTY:name=rv-b40" > $LOG/helper.log 2>&1 &
else
    (cd /tmp/crev/pyrepo && PYTHONPATH=/tmp/crev/pyrepo exec /root/esp32c5-venv/bin/python -m esp32c5_kismet.remote \
        --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS --source "esp32c5btle-$TTY:name=rv-b40") > $LOG/helper.log 2>&1 &
fi
P=$!; STARTED="$STARTED $P"
sleep 8
uuid=$(src_field rv-b40 kismet.datasource.uuid)
echo "$(ts) before: running=$(src_field rv-b40 kismet.datasource.running) channel=$(src_field rv-b40 kismet.datasource.channel) packets=$(src_field rv-b40 kismet.datasource.num_packets)"
code=$(curl -s -o $LOG/set40.json -w "%{http_code}" -u "$KUSER:$KPASS" --data-urlencode "json={\"channel\": \"40\"}" "$API/datasource/by-uuid/$uuid/set_channel.cmd")
echo "$(ts) set_channel 40: HTTP $code: $(head -c 200 $LOG/set40.json)"
sleep 3
echo "$(ts) after: running=$(src_field rv-b40 kismet.datasource.running) error=$(src_field rv-b40 kismet.datasource.error) error_reason=$(src_field rv-b40 kismet.datasource.error_reason) channel=$(src_field rv-b40 kismet.datasource.channel) packets=$(src_field rv-b40 kismet.datasource.num_packets)"
echo "--- kismet log"; grep -n "rv-b40\|channel 40" $LOG/kismet.log | tail -8
echo "--- helper log"; grep -v "_lws_smd_msg_send" $LOG/helper.log | tail -8
stop_all; rm -rf $WORK
