#!/bin/sh
# P2 end to end: fake board A's pseudo-terminal flock-held by another process; one helper with a source on A
# and one on fake board B. The helper must not offer A while it is held, B must capture meanwhile, and A must be
# taken within about 5 s of the lock's release. Ports 2711/3711. Kills only the pids it starts. The logs are
# copied next to this script.
set -u
OUT=$(cd "$(dirname "$0")" && pwd)/p2
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
KISMET=/root/kismet-install/bin/kismet
PY=/root/esp32c5-venv/bin/python
HTTP_PORT=2711 TCP_PORT=3711
W=$(mktemp -d /tmp/py-fix6-p2.XXXXXX)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT
export PYTHONPATH=$REPO PYTHONDONTWRITEBYTECODE=1
unset KISMET_CAP_APIKEY KISMET_CAP_USER KISMET_CAP_PASSWORD
mkdir -p "$OUT" "$W/home/.kismet"
printf 'httpd_username=p2\nhttpd_password=p2-password\n' > "$W/home/.kismet/kismet_httpd.conf"
printf 'httpd_port=%s\nremote_capture_listen=127.0.0.1\nremote_capture_port=%s\n' $HTTP_PORT $TCP_PORT > "$W/override.conf"
(cd "$W" && exec "$KISMET" --homedir "$W/home" --no-ncurses --no-logging --override "$W/override.conf") > "$W/kismet.log" 2>&1 &
KPID=$!; PIDS="$PIDS $KPID"
for i in $(seq 1 120); do curl -sf -o /dev/null -u p2:p2-password "http://127.0.0.1:$HTTP_PORT/system/status.json" && break; sleep 0.5; done

"$PY" "$REPO/tools/fake_board.py" "$W/board-a" WIFI > "$W/fake-a.log" 2>&1 &
PIDS="$PIDS $!"
"$PY" "$REPO/tools/fake_board.py" "$W/board-b" 802154 > "$W/fake-b.log" 2>&1 &
PIDS="$PIDS $!"
sleep 1
"$PY" -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("pid %d holds the flock on %s" % (os.getpid(), os.path.realpath(sys.argv[1])), flush=True)
time.sleep(300)' "$W/board-a" > "$W/holder.log" 2>&1 &
HOLDER=$!; PIDS="$PIDS $HOLDER"
sleep 1
st=$(stat -L -c '%d %i' "$W/board-a")
echo "holder: $(cat "$W/holder.log")" > "$W/timeline.txt"
echo "/proc/locks for $(readlink -f "$W/board-a") (st_dev, inode: $st):" >> "$W/timeline.txt"
python3 - "$W/board-a" >> "$W/timeline.txt" <<'EOF'
import os, sys
st = os.stat(sys.argv[1])
want = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
for line in open("/proc/locks"):
    if want in line.split():
        print("   " + line.rstrip())
EOF

T0=$(date +%s%N)
now() { echo "$(( ($(date +%s%N) - T0) / 1000000 ))"; }
(cd "$W" && exec "$PY" -u -m esp32c5_kismet.remote --connect 127.0.0.1:$HTTP_PORT --user p2 --password p2-password \
    --source "esp32c5:device=$W/board-a,name=held-a" --source "esp32c5:device=$W/board-b,mode=zigbee,name=free-b") \
    > "$W/helper.log" 2>&1 &
HP=$!; PIDS="$PIDS $HP"
echo "t=0 ms: helper started (pid $HP)" >> "$W/timeline.txt"

poll() {  # one line: which sources Kismet has, and their packets
    curl -s -u p2:p2-password "http://127.0.0.1:$HTTP_PORT/datasource/all_sources.json" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except ValueError:
    s = []
print(", ".join("%s running=%s packets=%s" % (x["kismet.datasource.name"], x["kismet.datasource.running"],
                                              x["kismet.datasource.num_packets"]) for x in s) or "no sources")'
}
for i in $(seq 1 12); do
    sleep 1
    echo "t=$(now) ms: Kismet: $(poll)" >> "$W/timeline.txt"
done
kill -TERM "$HOLDER"; wait "$HOLDER" 2>/dev/null
REL=$(now)
echo "t=$REL ms: the holder is gone, the lock released" >> "$W/timeline.txt"
SEEN=
for i in $(seq 1 80); do
    sleep 0.1
    line=$(poll)
    case "$line" in
        *held-a*) ;;
        *) continue ;;
    esac
    if [ -z "$SEEN" ]; then
        SEEN=$(now)
        echo "t=$SEEN ms: Kismet: $line" >> "$W/timeline.txt"
    fi
    case "$line" in
        *"held-a running=1 packets=0"*|*"held-a running=0"*) ;;
        *) echo "t=$(now) ms: Kismet: $line" >> "$W/timeline.txt"; break ;;
    esac
done
T1=$(now)
echo "released -> held-a a source in Kismet: $((SEEN - REL)) ms; with packets: $((T1 - REL)) ms" >> "$W/timeline.txt"
grep -n "" "$W/helper.log" | grep -E "held-a" | head -3 >> "$W/timeline.txt"
sleep 3
echo "t=$(now) ms: Kismet: $(poll)" >> "$W/timeline.txt"
kill -TERM "$HP"
for i in $(seq 1 100); do kill -0 "$HP" 2>/dev/null || break; sleep 0.1; done
wait "$HP"; echo "helper exit status $?" >> "$W/timeline.txt"
kill -TERM "$KPID"; wait "$KPID" 2>/dev/null
grep -E "held-a|free-b" "$W/kismet.log" > "$W/kismet-sources.log"
cp "$W/timeline.txt" "$W/helper.log" "$W/kismet-sources.log" "$W/fake-a.log" "$OUT/"
cat "$W/timeline.txt"
echo "--- helper log"
cat "$W/helper.log"
