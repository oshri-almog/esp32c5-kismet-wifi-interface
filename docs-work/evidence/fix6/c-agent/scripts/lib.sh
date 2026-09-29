# Helpers for the manual proofs (sourced). Kismet on 2601/3601, logs under $OUT/$CASE.
OUT=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix6/c-agent
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
KISMET=/root/kismet-install/bin/kismet
HELPER=${HELPER:-/root/kismet-install/bin/kismet_cap_esp32c5}
HTTP_PORT=2601
TCP_PORT=3601
KUSER=${KUSER:-c6}
KPASS=${KPASS:-c6-password}
API=http://127.0.0.1:$HTTP_PORT
STARTED=""

setup_case() {  # setup_case NAME   WORK (Linux temp) and LOG (scratchpad) dirs
    CASE=$1
    WORK=$(mktemp -d /tmp/c-agent-$CASE.XXXXXX)
    LOG=$OUT/$CASE
    mkdir -p "$LOG"
    mkdir -p "$WORK/home/.kismet"
    printf "httpd_username=%s\nhttpd_password=%s\n" "$KUSER" "$KPASS" > "$WORK/home/.kismet/kismet_httpd.conf"
    printf "httpd_port=%s\nremote_capture_listen=127.0.0.1\nremote_capture_port=%s\n" "$HTTP_PORT" "$TCP_PORT" > "$WORK/override.conf"
}

api() {
    if [ $# -gt 1 ]; then curl -s -u "$KUSER:$KPASS" --data-urlencode "json=$2" "$API$1"
    else curl -s -u "$KUSER:$KPASS" "$API$1"; fi
}

start_kismet() {  # start_kismet [kismet args...]
    (cd "$WORK" && exec "$KISMET" --homedir "$WORK/home" --no-ncurses --override "$WORK/override.conf" "$@") > "$LOG/kismet.log" 2>&1 &
    KPID=$!; STARTED="$STARTED $KPID"
    for i in $(seq 1 120); do
        curl -sf -o /dev/null -u "$KUSER:$KPASS" "$API/system/status.json" && { echo "kismet up (pid $KPID)"; return 0; }
        sleep 0.5
    done
    echo "kismet did not come up"; return 1
}

start_fake() {  # start_fake NAME PORT [options]   sets TTY and FPID
    fname=$1 fport=$2; shift 2
    rm -f "$fport"
    python3 "$REPO/tools/fake_board.py" "$fport" "$@" > "$LOG/fake-$fname.log" 2>&1 &
    FPID=$!; STARTED="$STARTED $FPID"
    for i in $(seq 1 50); do grep -q booted "$LOG/fake-$fname.log" 2>/dev/null && break; sleep 0.1; done
    TTY=$(readlink -f "$fport" | sed "s|^/dev/||")
    echo "fake $fname on $TTY (pid $FPID)"
}

ts() { date +%H:%M:%S.%N | cut -c1-12; }

# the flock holders of a device node, from /proc/locks: pids
lock_pids() {
    st=$(stat -L -c "%Hd %Ld %i" "$1" 2>/dev/null) || return 0
    set -- $st
    want=$(printf "%02x:%02x:%s" "$1" "$2" "$3")
    awk -v w="$want" "\$2 == \"FLOCK\" && \$6 == w { print \$5 }" /proc/locks
}

stop_all() {
    for p in $STARTED; do kill "$p" 2>/dev/null; done
    sleep 1
    for p in $STARTED; do kill -9 "$p" 2>/dev/null; done
    wait 2>/dev/null
}
