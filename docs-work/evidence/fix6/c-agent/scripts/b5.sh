#!/bin/bash
# b5.sh CASE HELPER : a BTLE remote source; set_channel 38, 39, 40, 37: what does Kismet show?
. /root/c-agent-fix6/lib.sh
HELPER=$2
setup_case $1
start_kismet --no-logging || exit 1
start_fake b $WORK/port BLE
$HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS \
    --source "esp32c5btle-$TTY:name=c6-b5,channel=38" > $LOG/helper.log 2>&1 &
H=$!; STARTED="$STARTED $H"
sleep 5
chan() { api /datasource/all_sources.json | python3 -c "import json,sys; s=[x for x in json.load(sys.stdin) if x[\"kismet.datasource.name\"]==\"c6-b5\"][0]; print(\"channel=%r hopping=%s packets=%s uuid=%s\" % (s[\"kismet.datasource.channel\"], s[\"kismet.datasource.hopping\"], s[\"kismet.datasource.num_packets\"], s[\"kismet.datasource.uuid\"]))"; }
echo "$(ts) opened with channel=38: $(chan)"
UUID=$(chan | sed "s/.*uuid=//")
for c in 38 39 40 37; do
    code=$(curl -s -o $LOG/set$c.json -w "%{http_code}" -u "$KUSER:$KPASS" --data-urlencode "json={\"channel\": \"$c\"}" "$API/datasource/by-uuid/$UUID/set_channel.cmd")
    sleep 1
    echo "$(ts) set_channel $c: HTTP $code; $(chan)"
done
grep -n "c6-b5" $LOG/kismet.log | tail -6
stop_all
rm -rf $WORK
