#!/bin/bash
# a3.sh CASE HELPER PASSWORD : a Kismet whose login password is PASSWORD; does the C remote helper
# log in (websocket) with --user/--password on the command line?
. /root/c-agent-fix6/lib.sh
HELPER=$2
KPASS=$3
setup_case $1
echo "kismet_httpd.conf: $(cat $WORK/home/.kismet/kismet_httpd.conf | tr "\n" " ")"
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
$HELPER --connect 127.0.0.1:$HTTP_PORT --user "$KUSER" --password "$KPASS" \
    --source "esp32c5-$TTY:name=c6-a3,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
H=$!; STARTED="$STARTED $H"
sleep 8
echo "$(ts) sources: $(api /datasource/all_sources.json | python3 -c "import json,sys; print([(s[\"kismet.datasource.name\"], s[\"kismet.datasource.running\"], s[\"kismet.datasource.num_packets\"]) for s in json.load(sys.stdin)])")"
grep -n "c6-a3\|401\|uthenticat\|login" $LOG/kismet.log | tail -5
echo "--- helper"; grep -v "_lws_smd\|N: " $LOG/helper.log | head -12
stop_all
rm -rf $WORK
