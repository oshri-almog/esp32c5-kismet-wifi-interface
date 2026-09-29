# Helpers for fix7's C proofs (sourced). Kismet on 2601/3601, the logging proxy on 2602;
# logs under $OUT/$CASE, work files under /root/fix7c.
OUT=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/outputs/proofs
SCRIPTS=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/scripts
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
KISMET=/root/kismet-install/bin/kismet
HTTP_PORT=2601
TCP_PORT=3601
PROXY_PORT=2602
KUSER=${KUSER:-fx}
KPASS=${KPASS:-fx-password}
API=http://127.0.0.1:$HTTP_PORT
STARTED=""
mkdir -p /root/fix7c/w "$OUT"

setup_case() {
    CASE=$1
    WORK=$(mktemp -d /root/fix7c/w/$CASE.XXXXXX)
    LOG=$OUT/$CASE
    rm -rf "$LOG"; mkdir -p "$LOG"
    mkdir -p "$WORK/home/.kismet"
    printf "httpd_username=%s\nhttpd_password=%s\n" "$KUSER" "$KPASS" > "$WORK/home/.kismet/kismet_httpd.conf"
    printf "httpd_port=%s\nremote_capture_listen=127.0.0.1\nremote_capture_port=%s\n" "$HTTP_PORT" "$TCP_PORT" > "$WORK/override.conf"
}
api() {
    if [ $# -gt 1 ]; then curl -s -u "$KUSER:$KPASS" --data-urlencode "json=$2" "$API$1"
    else curl -s -u "$KUSER:$KPASS" "$API$1"; fi
}
start_kismet() {
    (cd "$WORK" && exec "$KISMET" --homedir "$WORK/home" --no-ncurses --no-logging --override "$WORK/override.conf" "$@") > "$LOG/kismet.log" 2>&1 &
    KPID=$!; STARTED="$STARTED $KPID"
    for i in $(seq 1 120); do
        api /system/status.json | grep -q kismet.system.timestamp && { echo "kismet up (pid $KPID)"; return 0; }
        sleep 0.5
    done
    echo "kismet did not come up"; return 1
}
start_proxy() {  # the logging relay, PROXY_PORT -> HTTP_PORT, into $LOG/requests.txt
    python3 "$SCRIPTS/logproxy.py" "$PROXY_PORT" "$HTTP_PORT" "$LOG/requests.txt" > "$LOG/proxy.log" 2>&1 &
    PXPID=$!; STARTED="$STARTED $PXPID"
    sleep 0.5
}
start_fake() {  # start_fake NAME PORT [options]  -> TTY FPID
    fname=$1 fport=$2; shift 2
    rm -f "$fport"
    python3 "$REPO/tools/fake_board.py" "$fport" "$@" > "$LOG/fake-$fname.log" 2>&1 &
    FPID=$!; STARTED="$STARTED $FPID"
    for i in $(seq 1 50); do grep -q booted "$LOG/fake-$fname.log" 2>/dev/null && break; sleep 0.1; done
    TTY=$(readlink -f "$fport" | sed "s|^/dev/||")
    echo "fake $fname on $TTY (pid $FPID)"
}
new_apikey() {  # an API key with the datasource role
    api /auth/apikey/generate.cmd '{"name": "fix7-'"$1"'", "role": "datasource", "duration": 0}'
}
src_field() {  # src_field NAME FIELD
    api /datasource/all_sources.json | python3 -c "
import json,sys
try:
    srcs = json.load(sys.stdin)
except ValueError:
    srcs = []
for s in srcs:
    if s.get(\"kismet.datasource.name\") == sys.argv[1]: print(s.get(sys.argv[2]))" "$1" "$2"
}
children_of() {
    for p in /proc/[0-9]*; do
        [ "$(awk '{print $4}' "$p/stat" 2>/dev/null)" = "$1" ] && echo "${p#/proc/}"
    done
}
stop_pids() {  # stop_pids PID...   by pid only, TERM then KILL
    for p in "$@"; do kill "$p" 2>/dev/null; done
    sleep 1
    for p in "$@"; do kill -9 "$p" 2>/dev/null; done
}
stop_all() {
    stop_pids $STARTED
    wait 2>/dev/null
    STARTED=""
}
