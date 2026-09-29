#!/bin/sh
# Is the e2e's "frames decoded as 802.11 over TCP" failure Kismet's duplicate filter (the fake board sends the
# same frames each time it is started, and Kismet drops a frame it has had, from any source, within its last
# 1024), or the Wi-Fi frequency now in the signal block? Runs the e2e's first two cases in one Kismet, with
# the signal block (MODE=freq) or with the frequency left out of it (MODE=nofreq), and counts the Wi-Fi
# packets Kismet credits to the second source. Ports 2711/3711. Kills only the pids it starts.
set -u
MODE=${1:-freq}
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
KISMET=/root/kismet-install/bin/kismet
PY=/root/esp32c5-venv/bin/python
HTTP_PORT=2711 TCP_PORT=3711
W=$(mktemp -d /tmp/py-fix6-dup.XXXXXX)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT
export PYTHONPATH=$REPO PYTHONDONTWRITEBYTECODE=1
mkdir -p "$W/home/.kismet"
printf 'httpd_username=d6\nhttpd_password=d6-password\n' > "$W/home/.kismet/kismet_httpd.conf"
printf 'httpd_port=%s\nremote_capture_listen=127.0.0.1\nremote_capture_port=%s\n' $HTTP_PORT $TCP_PORT > "$W/override.conf"
cat > "$W/helper.py" <<EOF
import sys
from esp32c5_kismet import remote
if "$MODE" == "nofreq":
    remote.radiotap_freq_khz = lambda record: 0
sys.exit(remote.main())
EOF
(cd "$W" && exec "$KISMET" --homedir "$W/home" --no-ncurses --no-logging --override "$W/override.conf") > "$W/kismet.log" 2>&1 &
KPID=$!; PIDS="$PIDS $KPID"
for i in $(seq 1 120); do curl -sf -o /dev/null -u d6:d6-password "http://127.0.0.1:$HTTP_PORT/system/status.json" && break; sleep 0.5; done

stop() { kill -TERM "$1" 2>/dev/null; for i in $(seq 1 100); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done; kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
case_run() {  # case_run NAME SECONDS HELPER-ARGS...
    name=$1 secs=$2; shift 2
    "$PY" "$REPO/tools/fake_board.py" "$W/port-$name" WIFI > "$W/fake-$name.log" 2>&1 &
    F=$!; PIDS="$PIDS $F"
    for i in $(seq 1 50); do grep -q booted "$W/fake-$name.log" && break; sleep 0.1; done
    (cd "$W" && exec "$PY" -u "$W/helper.py" "$@") > "$W/helper-$name.log" 2>&1 &
    H=$!; PIDS="$PIDS $H"
    sleep "$secs"
    stop $H; stop $F
}
case_run a 25 --connect 127.0.0.1:$HTTP_PORT --user d6 --password d6-password --source "esp32c5:device=$W/port-a,name=src-a"
case_run b 20 --tcp --connect 127.0.0.1:$TCP_PORT --source "esp32c5:device=$W/port-b,name=src-b"
curl -s -u d6:d6-password "http://127.0.0.1:$HTTP_PORT/datasource/all_sources.json" > "$W/sources.json"
curl -s -u d6:d6-password "http://127.0.0.1:$HTTP_PORT/devices/views/all/devices.json" > "$W/devices.json"
stop $KPID
python3 - "$W" "$MODE" <<'EOF'
import json, sys
w, mode = sys.argv[1:]
src = {s["kismet.datasource.uuid"]: (s["kismet.datasource.name"], s["kismet.datasource.num_packets"])
       for s in json.load(open(w + "/sources.json"))}
credit = {}
for d in json.load(open(w + "/devices.json")):
    if d.get("kismet.device.base.phyname") != "IEEE802.11":
        continue
    sb = d.get("kismet.device.base.seenby") or []
    for s in (sb.values() if isinstance(sb, dict) else sb):
        name = src.get(s["kismet.common.seenby.uuid"], ("?",))[0]
        credit[name] = credit.get(name, 0) + s["kismet.common.seenby.num_packets"]
print("%s: packets per source %s; Wi-Fi device packets credited per source %s" %
      (mode, {n: p for n, p in src.values()}, credit))
EOF
echo "left running: $(pgrep -f "$W" | tr '\n' ' ')"
rm -rf "$W"
