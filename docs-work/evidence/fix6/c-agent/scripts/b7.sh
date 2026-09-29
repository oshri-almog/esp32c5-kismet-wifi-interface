#!/bin/bash
# b7.sh CASE : three local sources (Wi-Fi, 802.15.4 locked on 15, BTLE), kismetdb logging; what
# frequency does Kismet store for packets and devices?
. /root/c-agent-fix6/lib.sh
setup_case $1
start_fake w $WORK/pw WIFI; TW=$TTY
start_fake z $WORK/pz 802154; TZ=$TTY
start_fake b $WORK/pb BLE; TB=$TTY
mkdir -p $WORK/logs
start_kismet -T kismet -p $WORK/logs -c "esp32c5-$TW:name=c6-w,channel=6,channel_hop=false" \
    -c "esp32c5zigbee-$TZ:name=c6-z,channel=15,channel_hop=false" -c "esp32c5btle-$TB:name=c6-b" || exit 1
sleep 12
kill $KPID; wait $KPID 2>/dev/null
DB=$(ls $WORK/logs/*.kismet | head -1)
echo "kismetdb: $DB"
echo "--- packets: phyname, frequency (kHz), count"
sqlite3 $DB "SELECT phyname, frequency, count(*) FROM packets GROUP BY phyname, frequency;"
echo "--- packets: signal by phy (dBm, count)"
sqlite3 $DB "SELECT phyname, signal, count(*) FROM packets GROUP BY phyname, signal ORDER BY phyname LIMIT 20;"
echo "--- devices: phyname, frequency, channel (from the device record)"
sqlite3 $DB "SELECT phyname, json_extract(device, \"$.\"\"kismet.device.base.frequency\"\"\"), json_extract(device, \"$.\"\"kismet.device.base.channel\"\"\"), json_extract(device, \"$.\"\"kismet.device.base.macaddr\"\"\") FROM devices ORDER BY phyname;"
cp $DB $LOG/b7.kismet
stop_all
rm -rf $WORK
