#!/bin/bash
# hup.sh CASE HELPER [--disable-retry] : a remote helper started under nohup (SIGHUP ignored) gets SIGHUP,
# as its processes do when the terminal it was started from closes. Does it keep capturing?
. $(dirname $0)/lib.sh
HELPER=$2; EXTRA=${3:-}
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
nohup $HELPER --connect 127.0.0.1:$HTTP_PORT --user $KUSER --password $KPASS $EXTRA \
    --source "esp32c5-$TTY:name=fx-hup,channel=6,channel_hop=false" > $LOG/helper.log 2>&1 &
P=$!; STARTED="$STARTED $P"
sleep 6
C=$(pgrep -P $P)
echo "$(ts) helper $P (SigIgn $(grep SigIgn /proc/$P/status | cut -f2)), capture child: ${C:-none} (SigIgn $( [ -n "$C" ] && grep SigIgn /proc/$C/status | cut -f2)); packets $(src_field fx-hup kismet.datasource.num_packets)"
kill -HUP $P $C
echo "$(ts) kill -HUP $P $C"
for i in 1 2 3 4 5 6 7 8; do
    sleep 1
    pa=no; kill -0 $P 2>/dev/null && pa=yes
    ca=none; [ -n "$C" ] && { ca=no; kill -0 $C 2>/dev/null && ca=yes; }
    echo "$(ts) helper alive=$pa child alive=$ca children now: $(pgrep -P $P | tr "\n" " ") packets $(src_field fx-hup kismet.datasource.num_packets) running=$(src_field fx-hup kismet.datasource.running)"
done
echo "--- helper log (lws W: lines dropped)"; grep -v "_lws_smd_msg_send" $LOG/helper.log
stop_all
rm -rf $WORK
