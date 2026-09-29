#!/bin/sh
# P5: what Kismet stores as a packet's frequency (kismetdb packets.frequency) and a device's, for the three
# radios, from the Python remote helper and (802.15.4 and BTLE) from the C remote helper, with fake boards.
# Ports 2711/3711. Kills only the pids it starts.
set -u
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
KISMET=/root/kismet-install/bin/kismet
CAP=/root/kismet-install/bin/kismet_cap_esp32c5
PY=/root/esp32c5-venv/bin/python
HTTP_PORT=2711 TCP_PORT=3711
W=$(mktemp -d /tmp/py-fix6-freq.XXXXXX)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT
export PYTHONPATH=$REPO PYTHONDONTWRITEBYTECODE=1
unset KISMET_CAP_APIKEY KISMET_CAP_USER KISMET_CAP_PASSWORD

mkdir -p "$W/home/.kismet" "$W/logs"
printf 'httpd_username=f6\nhttpd_password=f6-password\n' > "$W/home/.kismet/kismet_httpd.conf"
printf 'httpd_port=%s\nremote_capture_listen=127.0.0.1\nremote_capture_port=%s\n' $HTTP_PORT $TCP_PORT > "$W/override.conf"

run_kismet() {  # run_kismet TITLE
    (cd "$W" && exec "$KISMET" --homedir "$W/home" --no-ncurses --override "$W/override.conf" \
        --log-types kismet --log-prefix "$W/logs" --log-title "$1") > "$W/kismet-$1.log" 2>&1 &
    KPID=$!
    PIDS="$PIDS $KPID"
    for i in $(seq 1 120); do
        curl -sf -o /dev/null -u f6:f6-password "http://127.0.0.1:$HTTP_PORT/system/status.json" && return 0
        sleep 0.5
    done
    echo "Kismet did not come up"; exit 1
}

fake() {  # fake NAME MODE
    "$PY" "$REPO/tools/fake_board.py" "$W/$1" "$2" > "$W/fake-$1.log" 2>&1 &
    PIDS="$PIDS $!"
    for i in $(seq 1 50); do grep -q booted "$W/fake-$1.log" 2>/dev/null && break; sleep 0.1; done
}

stop() {  # stop PID
    kill -TERM "$1" 2>/dev/null
    for i in $(seq 1 100); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

query() {  # query TITLE
    db=$(ls "$W"/logs/*"$1"*.kismet | head -1)
    echo "--- $1: $db"
    python3 - "$db" <<'EOF'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
names = {r[0]: r[1] for r in db.execute("SELECT uuid, name FROM datasources")}
print("packets: datasource, phyname, dlt, frequency, count")
for row in db.execute("SELECT datasource, phyname, dlt, frequency, count(*) FROM packets "
                      "GROUP BY datasource, phyname, dlt, frequency ORDER BY datasource, phyname, frequency"):
    print("   ", names.get(row[0], row[0]), row[1:])
print("devices: phyname, devmac, kismet.device.base.frequency, channel")
for phy, mac, dev in db.execute("SELECT phyname, devmac, device FROM devices ORDER BY phyname, devmac"):
    d = json.loads(dev)
    print("   ", phy, mac, d.get("kismet.device.base.frequency"), d.get("kismet.device.base.channel"))
EOF
}

# 1. The Python remote helper, the three radios on three fake boards
run_kismet python
fake wifi WIFI
fake zigbee 802154
fake ble BLE
(cd "$W" && exec "$PY" -u -m esp32c5_kismet.remote --connect 127.0.0.1:$HTTP_PORT --user f6 --password f6-password \
    --source "esp32c5:device=$W/wifi,name=py-wifi" --source "esp32c5:device=$W/zigbee,mode=zigbee,name=py-zigbee" \
    --source "esp32c5:device=$W/ble,mode=btle,name=py-btle") > "$W/helper-python.log" 2>&1 &
HP=$!
PIDS="$PIDS $HP"
sleep 30
stop $HP
stop $KPID
query python

# 2. The C remote helper (as installed now), 802.15.4 and BTLE, one process each
run_kismet c
"$CAP" --disable-retry --connect 127.0.0.1:$HTTP_PORT --user f6 --password f6-password --source "esp32c5:device=$W/zigbee,mode=zigbee,name=c-zigbee" \
    > "$W/helper-c-zigbee.log" 2>&1 &
C1=$!
"$CAP" --disable-retry --connect 127.0.0.1:$HTTP_PORT --user f6 --password f6-password --source "esp32c5:device=$W/ble,mode=btle,name=c-btle" \
    > "$W/helper-c-btle.log" 2>&1 &
C2=$!
PIDS="$PIDS $C1 $C2"
sleep 30
stop $C1
stop $C2
stop $KPID
query c
echo "C helper: $(stat -c '%y' "$CAP")"
echo "left running: $(pgrep -f "$W" | tr '\n' ' ')"
echo "work dir: $W"
