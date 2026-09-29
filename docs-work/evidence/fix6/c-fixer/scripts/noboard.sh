#!/bin/bash
# noboard.sh NAME RUNS : kismet_e2e.sh's bare-esp32c5 case (no board plugged in), RUNS times, with Kismet
# starting /tmp/cfix/bin/cap_NAME as its esp32c5 helper (helper_binary_path); what error the source
# shows 15 s after Kismet started
. $(dirname $0)/lib.sh
HB=/tmp/cfix/hb-$1
rm -rf $HB; mkdir -p $HB; cp /tmp/cfix/bin/cap_$1 $HB/kismet_cap_esp32c5
ok=0
for i in $(seq 1 $2); do
    setup_case noboard-$1-$i
    echo "helper_binary_path=$HB" >> $WORK/override.conf
    start_kismet --no-logging -c "esp32c5:name=fx-noboard" > /dev/null || exit 1
    sleep 15
    err=$(src_field fx-noboard kismet.datasource.error_reason)
    reopen=$(grep -c "Attempting to re-open" $LOG/kismet.log)
    case "$err" in "no Espressif"*) ok=$((ok + 1));; esac
    echo "cap_$1 run $i: error_reason='$(echo $err | cut -c1-40)' re-opens=$reopen"
    stop_all; STARTED=""
    rm -rf $WORK
done
echo "cap_$1: the helper's reason shown in $ok of $2 runs"
