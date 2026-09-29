#!/bin/bash
# hw3 common helpers, sourced by every check script. Kills only PIDs recorded here.
E=$HOME/e2e/hw3
T=$E/tools
KBIN=$HOME/kismet-install/bin/kismet
CAP=$HOME/kismet-install/bin/kismet_cap_esp32c5
PY=$HOME/esp32c5-venv/bin/python
REPO=$HOME/esp32c5-kismet-wifi-interface
KUSER=${KUSER:-admin}
KPASS=${KPASS:-hw3-Pass-99}
export HW3_AUTH="$KUSER:$KPASS"
MAC_A=10:BD:A3:CF:05:40
MAC_B=38:44:BE:BF:C9:10
MAC_C=38:44:BE:BF:D8:0C
MAC_D=10:BD:A3:C8:7D:54

byid() { echo /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_$1-if00; }
tty_of() { basename "$(readlink -f "$(byid $1)")"; }
now() { date +%s.%N; }
mapping() { for m in $MAC_A $MAC_B $MAC_C $MAC_D; do printf "%s=%s " $m "$(tty_of $m)"; done; echo; }

# kstart CASE DIR [kismet args...]: Kismet with home /tmp/hw3/CASE, output timestamped into DIR/kismet.log,
# pid in DIR/kismet.pid. LOGGING=1 keeps kismetdb logging on (log prefix /tmp/hw3/CASE).
kstart() {
    local CASE=$1 DIR=$2; shift 2
    local H=/tmp/hw3/$CASE
    rm -rf "$H"; mkdir -p "$H/.kismet" "$DIR"
    printf 'httpd_username=%s\nhttpd_password=%s\n' "$KUSER" "$KPASS" > "$H/.kismet/kismet_httpd.conf"
    local EXTRA="--no-logging"
    [ -n "$LOGGING" ] && EXTRA="-p $H -t $CASE"
    rm -f "$DIR/kismet.pid"
    now > "$DIR/kismet.t0"
    echo "kismet args: --homedir $H --no-ncurses $EXTRA $*" >> "$DIR/kismet.cmd"
    ( cd "$H" && setsid sh -c 'echo $$ > "$0"; exec stdbuf -oL -eL "$@" < /dev/null 2>&1' "$DIR/kismet.pid" \
        "$KBIN" --homedir "$H" --no-ncurses $EXTRA "$@" | python3 -u "$T/ts.py" >> "$DIR/kismet.log" ) > /dev/null 2>&1 &
    for i in $(seq 1 240); do
        # any HTTP answer counts: a login with ':' in the user name cannot pass Basic auth, so it gets 401
        local code=$(curl -s -o /dev/null -w '%{http_code}' -u "$KUSER:$KPASS" http://127.0.0.1:2501/system/status.json)
        if [ -s "$DIR/kismet.pid" ] && [ "$code" != "000" ]; then
            echo "kismet up after $(awk -v a=$(now) -v b=$(cat $DIR/kismet.t0) 'BEGIN{printf "%.2f", a-b}') s, pid $(cat $DIR/kismet.pid), home $H, status.json HTTP $code"
            return 0
        fi
        sleep 0.25
    done
    echo "kismet did not come up"; tail -30 "$DIR/kismet.log"; return 1
}

# kstop DIR: SIGTERM the Kismet whose pid is in DIR/kismet.pid, wait for it (SIGKILL after 30 s, same pid)
kstop() {
    local DIR=$1 P
    P=$(cat "$DIR/kismet.pid" 2>/dev/null) || return 0
    [ -n "$P" ] || return 0
    kill -TERM "$P" 2>/dev/null
    for i in $(seq 1 60); do [ -d /proc/$P ] || break; sleep 0.5; done
    if [ -d /proc/$P ]; then echo "SIGKILL kismet $P"; kill -KILL "$P"; fi
    sleep 1
    echo "kismet $P stopped"
}

# locks: flock holders on the boards' ports (and on anything given)
locks() {
    python3 "$T/lockcheck.py" --holders-only /dev/ttyACM* "$@"
}
