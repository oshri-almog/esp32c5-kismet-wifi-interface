#!/bin/bash
# pass.sh CASE HELPER : getopt_long takes --pass for --password; does the '&' warning see it, and does
# login_from_env take it for a password?
. $(dirname $0)/lib.sh
H=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
echo "== --pass with a password holding &"
timeout 8 $H --connect 127.0.0.1:$HTTP_PORT --user $KUSER --pass "a&b" --disable-retry \
    --source "esp32c5-$TTY:name=fx-pass2,channel=6,channel_hop=false" > $LOG/helper-amp.log 2>&1
echo "exit $?"; grep -v "_lws_smd_msg_send" $LOG/helper-amp.log
echo "== --pass with the right password, the user from KISMET_CAP_USER"
KISMET_CAP_USER=$KUSER KISMET_CAP_APIKEY=0123456789abcdef $H --connect 127.0.0.1:$HTTP_PORT --pass $KPASS --disable-retry \
    --source "esp32c5-$TTY:name=fx-pass,channel=6,channel_hop=false" > $LOG/helper-ok.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep 6
echo "$(ts) running=$(src_field fx-pass kismet.datasource.running) packets=$(src_field fx-pass kismet.datasource.num_packets)"
kill $P 2>/dev/null; wait $P 2>/dev/null
grep -v "_lws_smd_msg_send" $LOG/helper-ok.log
stop_all; rm -rf $WORK
