#!/bin/bash
# b6.sh CASE : stderr of the C remote helper over --connect localhost:PORT, before and after
. /root/c-agent-fix6/lib.sh
setup_case $1
start_kismet --no-logging || exit 1
start_fake one $WORK/port WIFI
for v in before after; do
    B=/root/kismet-install/bin/kismet_cap_esp32c5; [ $v = before ] && B=/root/c-agent-fix6/before/kismet_cap_esp32c5.repo
    timeout -s INT 6 $B --connect localhost:$HTTP_PORT --user $KUSER --password $KPASS --disable-retry \
        --source "esp32c5-$TTY:name=c6-b6-$v" > $LOG/helper-$v.log 2>&1
    echo "===== $v ($B), --connect localhost:$HTTP_PORT, 6 s"
    cat $LOG/helper-$v.log
    sleep 1
done
stop_all
rm -rf $WORK
