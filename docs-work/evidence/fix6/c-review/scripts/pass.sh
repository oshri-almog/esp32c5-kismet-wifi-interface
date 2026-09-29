#!/bin/bash
# pass.sh CASE : getopt_long takes --pass for --password; does the & warning see it?
. /tmp/crev/lib.sh
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
echo "== --pass with the right password"
/tmp/crev/bin/cap_new --connect 127.0.0.1:$HTTP_PORT --user $KUSER --pass $KPASS --disable-retry \
    --source "esp32c5-$TTY:name=rv-pass,channel=6,channel_hop=false" > $LOG/helper-ok.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep 6
echo "$(ts) running=$(src_field rv-pass kismet.datasource.running) packets=$(src_field rv-pass kismet.datasource.num_packets)"
kill $P; wait $P 2>/dev/null
echo "== --pass with a password holding &"
timeout 8 /tmp/crev/bin/cap_new --connect 127.0.0.1:$HTTP_PORT --user $KUSER --pass "a&b" --disable-retry \
    --source "esp32c5-$TTY:name=rv-pass2,channel=6,channel_hop=false" > $LOG/helper-amp.log 2>&1
echo "exit $?"; grep -v "_lws_smd_msg_send" $LOG/helper-amp.log
echo "== --password with a password holding &"
timeout 8 /tmp/crev/bin/cap_new --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password "a&b" --disable-retry \
    --source "esp32c5-$TTY:name=rv-pass3,channel=6,channel_hop=false" > $LOG/helper-amp2.log 2>&1
echo "exit $?"; grep -v "_lws_smd_msg_send" $LOG/helper-amp2.log
stop_all; rm -rf $WORK
