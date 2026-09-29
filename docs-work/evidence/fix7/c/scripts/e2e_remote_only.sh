#!/bin/sh
# End to end: a fake board (tools/fake_board.py) -> kismet_cap_esp32c5 -> a real Kismet server,
# checking what Kismet reports through its REST API. Linux, no hardware needed; python3 (standard
# library only) and curl.
#
#     tests/kismet_e2e.sh                 Kismet on the PATH, patched with kismet/add-to-kismet.sh
#     KISMET=~/kismet-install/bin/kismet tests/kismet_e2e.sh
#
# KISMET has to be an installed kismet, with kismet_cap_esp32c5 next to it: Kismet starts its
# helpers from the bin directory it was configured with, not from the one it runs from. The remote
# case runs the kismet_cap_esp32c5 next to KISMET too, or the one HELPER names, and the remote
# helpers reach Kismet through a relay of its own on a free port of 127.0.0.1. It starts its own
# Kismet on port 2501, with a login in a temporary --homedir and logging off, so stop any other
# Kismet first. Prints PASS or FAIL for each check and ALL OK at the end; on a failure it keeps the
# logs, says where, and exits with 1. More on the wiki page Development-and-Testing.
#
# The cases: each radio, and each device's frequency; a damaged record every 50; frames whose
# payload holds the whole restart signature (anyone on the air can send one); a board that restarts
# its stream in place; a radio switch that reboots the board with the port staying open (as the
# real board does) and one where the port goes away (--vanish); an 802.15.4 source named
# esp32c5zigbee-<port>; channel= with channel_hop=false; a second source on a board in use; BTLE,
# set to channel 38 and reported on 37, and refused channel 40; BTLE from older firmware; firmware
# without the radio asked for (--lacks), which has to be said once, never "capturing", and end in
# the helper's 15 s reason in Kismet's log; remote capture over the websocket (--connect, with
# retry, started with SIGHUP ignored as nohup does), through a relay that logs the head of every
# request: the login, whose password holds '&', a space and %41, in an Authorization header and
# nowhere in the request line, the first packet within 3 s and more every second after, a channel
# set without an empty "INFO: " line, no libwebsockets notices or queue warnings, SIGHUP ignored, a
# second remote helper on the same board refused, close_source.cmd followed by a reconnect, and kill
# -TERM ending the capture process with the helper; an API key, in Kismet's session cookie and not
# in the request line; a login too long for the request's headers, refused with a reason instead of
# cut short; a bare esp32c5 with no board plugged in, which Kismet has to hand to the helper (and
# retry) rather than give up on with "Unable to find driver" -- skipped when an Espressif
# USB-Serial-JTAG device is plugged in.

set -u

HERE=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
KISMET=${KISMET:-kismet}
HELPER=${HELPER:-$(dirname "$(command -v "$KISMET")")/kismet_cap_esp32c5}
PORT=/tmp/esp32c5-e2e
# The web login. Its password holds what a websocket login in the URI's query could not: '&', which
# Kismet splits the decoded query at, a space, and %41, which it decodes to "A"
USER_PASS='e2e:e2e &pass%41word'
API=http://localhost:2501
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null
    [ -n "${FPID:-}" ] && kill "$FPID" 2>/dev/null
    [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null
    [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
    [ -n "${RPID:-}" ] && kill "$RPID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK" "$PORT"
}
trap cleanup EXIT INT TERM

check() {  # check NAME CONDITION-EXIT-STATUS
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi
}

# Kismet asks for a login on first start unless one is configured. It finds kismet_httpd.conf under
# %h/.kismet, and %h is the passwd entry's home, not $HOME, so it is pointed here with --homedir.
mkdir -p "$WORK/home/.kismet"
printf 'httpd_username=%s\nhttpd_password=%s\n' "${USER_PASS%%:*}" "${USER_PASS#*:}" \
    > "$WORK/home/.kismet/kismet_httpd.conf"

api() {  # api PATH [JSON-FILTER]
    if [ $# -gt 1 ]; then
        curl -s -u "$USER_PASS" --data-urlencode "json=$2" "$API$1"
    else
        curl -s -u "$USER_PASS" "$API$1"
    fi
}

# The pseudo-terminal behind $PORT, as a name under /dev (pts/3): esp32c5-<that> names the port
tty_name() {
    readlink -f "$PORT" | sed 's|^/dev/||'
}

start_kismet() {  # start_kismet CASE [DEFINITION]   without one Kismet has no source of its own
    if [ $# -gt 1 ]; then
        echo "   source $2"
        HOME="$WORK/home" "$KISMET" --homedir "$WORK/home" --no-ncurses --no-logging \
            -c "$2" > "$WORK/kismet-$1.log" 2>&1 &
    else
        HOME="$WORK/home" "$KISMET" --homedir "$WORK/home" --no-ncurses --no-logging \
            > "$WORK/kismet-$1.log" 2>&1 &
    fi
    KPID=$!
}

wait_kismet() {  # until Kismet answers, at most a minute
    for i in $(seq 1 120); do
        curl -sf -o /dev/null -u "$USER_PASS" "$API/system/status.json" && return 0
        sleep 0.5
    done
    return 1
}

start_case() {  # start_case CASE DEFINITION [FAKE-OPTIONS]   @TTY@ in DEFINITION is the port's name
    case=$1 definition=$2
    shift 2
    python3 "$HERE/tools/fake_board.py" "$PORT" "$@" > "$WORK/fake-$case.log" 2>&1 &
    FPID=$!
    sleep 1
    TTY=$(tty_name)
    start_kismet "$case" "$(echo "$definition" | sed "s|@TTY@|$TTY|g")"
}

finish_case() {  # finish_case CASE
    api /datasource/all_sources.json > "$WORK/sources-$1.json"
    api /devices/views/all/devices.json \
        '{"fields": ["kismet.device.base.phyname", "kismet.device.base.name", "kismet.device.base.commonname", "kismet.device.base.macaddr", "kismet.device.base.channel", "kismet.device.base.frequency"]}' \
        > "$WORK/devices-$1.json"

    kill "$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null; KPID=
    if [ -n "${FPID:-}" ]; then kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null; FPID=; fi
    sleep 2
}

# The Espressif USB-Serial-JTAG devices plugged into this machine, which a bare esp32c5 would open
espressif_ttys() {
    for d in /sys/class/tty/ttyACM* /sys/class/tty/ttyUSB*; do
        [ -e "$d/device" ] || continue
        usb=$(readlink -f "$d/device")/..
        if [ "$(cat "$usb/idVendor" 2>/dev/null)" = 303a ] && [ "$(cat "$usb/idProduct" 2>/dev/null)" = 1001 ]; then
            echo "${d##*/}"
        fi
    done
}

run_case() {  # run_case CASE SECONDS DEFINITION [FAKE-OPTIONS]
    case=$1 seconds=$2 definition=$3
    shift 3
    start_case "$case" "$definition" "$@"
    sleep "$seconds"
    finish_case "$case"
}

# The Python below sees: s, the source named fake-CASE; sources, devices, names, phys, macs; and
# freqs, each phy's device frequencies in kHz
PYLOAD='
import json, sys
def load(path):  # a refused login or a Kismet that is not up answers with something else
    try:
        return json.load(open(path))
    except ValueError:
        return None
sources = load(sys.argv[1])
devices = load(sys.argv[2]) or []
if sources is None:
    print("   no JSON from Kismet in %s" % sys.argv[1])
    sources = []
src = [s for s in sources if s.get("kismet.datasource.name") == "fake-" + sys.argv[3]]
s = src[0] if src else {}
names = {d.get("kismet.device.base.commonname") or d.get("kismet.device.base.name") or "" for d in devices}
phys = {d.get("kismet.device.base.phyname") for d in devices}
macs = {d.get("kismet.device.base.macaddr") for d in devices}
freqs = {}
for d in devices:
    freqs.setdefault(d.get("kismet.device.base.phyname"), set()).add(d.get("kismet.device.base.frequency"))
'

report() {  # report CASE
    python3 -c "$PYLOAD"'
print("   source: running=%s error=%r packets=%s hopping=%s channel=%r interface=%r capif=%r" % (
    s.get("kismet.datasource.running"), s.get("kismet.datasource.error_reason"),
    s.get("kismet.datasource.num_packets"), s.get("kismet.datasource.hopping"),
    s.get("kismet.datasource.channel"), s.get("kismet.datasource.interface"),
    s.get("kismet.datasource.capture_interface")))
print("   phys: %s" % ", ".join(str(p) for p in sorted(phys, key=str)))
print("   names: %s" % ", ".join(repr(n) for n in sorted(names) if n))
print("   device frequencies (kHz): %s" % "; ".join("%s %s" % (p, sorted(f, key=str)) for p, f in sorted(freqs.items(), key=str)))
' "$WORK/sources-$1.json" "$WORK/devices-$1.json" "$1"
}

has() {  # has CASE PYTHON-EXPRESSION
    python3 -c "$PYLOAD"'
sys.exit(0 if eval(sys.argv[4]) else 1)
' "$WORK/sources-$1.json" "$WORK/devices-$1.json" "$1" "$2"
}

logged() {  # logged CASE TEXT   (in Kismet's output)
    grep -qF -- "$2" "$WORK/kismet-$1.log"
}

faked() {  # faked CASE TEXT     (in the fake board's output)
    grep -qF -- "$2" "$WORK/fake-$1.log"
}

src() {  # src NAME FIELD    one field of the source called NAME, now
    api /datasource/all_sources.json | python3 -c '
import json, sys
try:
    sources = json.load(sys.stdin)
except ValueError:
    sources = []
print(next((s.get(sys.argv[2]) for s in sources if s.get("kismet.datasource.name") == sys.argv[1]), ""))
' "$1" "$2"
}

children_of() {  # children_of PID
    python3 -c '
import os, sys
for p in os.listdir("/proc"):
    try:
        if p.isdigit() and open("/proc/%s/stat" % p).read().rsplit(")", 1)[1].split()[1] == sys.argv[1]:
            print(p)
    except (OSError, IndexError):
        pass
' "$1"
}

lock_holders() {  # lock_holders PATH   the pids holding a flock on the node PATH leads to
    python3 -c '
import os, sys
st = os.stat(sys.argv[1])
want = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
for line in open("/proc/locks"):
    f = line.split()
    if len(f) > 5 and f[1] == "FLOCK" and f[5] == want:
        print(f[4])
' "$1" | tr '\n' ' '
}

alive() {  # alive PID...   every one of them is running; not a zombie, which kill -0 would count
    [ $# -gt 0 ] || return 1
    for p in "$@"; do
        state=$(sed 's/.*) \(.\).*/\1/' "/proc/$p/stat" 2>/dev/null) || return 1
        [ -n "$state" ] && [ "$state" != Z ] || return 1
    done
}

ms_since() {  # ms_since NANOSECONDS   from date +%s%N
    echo $(( ($(date +%s%N) - $1) / 1000000 ))
}

# A relay between the remote helpers and Kismet (2501) that writes the head of every request it
# passes on -- request line and headers, after a line "== connection N" -- to $WORK/requests.log,
# and then passes everything on as it is. It takes a free port, RELAY.
start_relay() {
    python3 -c '
import socket, sys, threading
log, portfile = sys.argv[1], sys.argv[2]
count = [0]
def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
def serve(client):
    head = b""
    while b"\r\n\r\n" not in head:
        data = client.recv(65536)
        if not data:
            return client.close()
        head += data
    count[0] += 1
    with open(log, "ab") as f:
        f.write(b"== connection %d\n" % count[0] + head.split(b"\r\n\r\n")[0].replace(b"\r", b"") + b"\n")
    upstream = socket.create_connection(("127.0.0.1", 2501))
    upstream.sendall(head)
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
    pipe(client, upstream)
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(16)
open(portfile, "w").write(str(server.getsockname()[1]))
while True:
    threading.Thread(target=serve, args=(server.accept()[0],), daemon=True).start()
' "$WORK/requests.log" "$WORK/relay.port" > "$WORK/relay.log" 2>&1 &
    RPID=$!
    for i in $(seq 1 50); do [ -s "$WORK/relay.port" ] && break; sleep 0.1; done
    RELAY=$(cat "$WORK/relay.port")
}

# The value of the Basic Authorization header in the request heads FILE, decoded
basic_login() {  # basic_login FILE
    python3 -c '
import base64, sys
for line in open(sys.argv[1], encoding="latin-1"):
    name, _, value = line.rstrip("\n").partition(": ")
    if name.lower() == "authorization" and value.startswith("Basic "):
        print(base64.b64decode(value[6:]).decode("utf-8", "replace"))
        break
' "$1"
}

echo "== remote capture: kismet_cap_esp32c5 --connect over the websocket, with retry, started with SIGHUP ignored (nohup)"
python3 "$HERE/tools/fake_board.py" "$PORT" WIFI > "$WORK/fake-remote.log" 2>&1 &
FPID=$!
sleep 1
TTY=$(tty_name)
start_kismet remote
wait_kismet
# Every remote helper goes through the relay, which logs each request's head
start_relay
echo "   $HELPER --connect 127.0.0.1:$RELAY (the relay to 2501) --source esp32c5-$TTY:name=fake-remote,channel=6,channel_hop=false"
T0=$(date +%s%N)
# The login from the environment (login_from_env), which the process list does not show
(trap '' HUP; KISMET_CAP_USER=${USER_PASS%%:*} KISMET_CAP_PASSWORD=${USER_PASS#*:} exec "$HELPER" \
    --connect "127.0.0.1:$RELAY" --source "esp32c5-$TTY:name=fake-remote,channel=6,channel_hop=false") \
    > "$WORK/helper-remote.log" 2>&1 &
HPID=$!
first=
for i in $(seq 1 50); do
    if [ "$(src fake-remote kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null; then first=$(ms_since "$T0"); break; fi
    sleep 0.2
done
echo "   first packet in Kismet ${first:-never} ms after the helper started"
# Before add-to-kismet.sh's fix libwebsockets sent what was queued only when Kismet's PING woke it,
# every 5 seconds: the first packet came after 5 s, and the others in bursts
[ -n "$first" ] && [ "$first" -lt 3000 ]; check "the first packet reaches Kismet within 3 s" $?
# Before add-to-kismet.sh's fix the login went in the request line's query, which a reverse
# proxy's access log keeps, and this one, with '&' in it, could not log in at all
echo "   $(grep -m1 "^GET " "$WORK/requests.log")"
grep "^GET " "$WORK/requests.log" > "$WORK/request-lines.txt"
[ -s "$WORK/request-lines.txt" ] && ! grep -q "[?]" "$WORK/request-lines.txt" && \
    ! grep -qiF "pass" "$WORK/request-lines.txt"
check "the request line holds no login: no query at all" $?
[ "$(basic_login "$WORK/requests.log")" = "$USER_PASS" ]
check "the login is in an Authorization header, Basic, exactly user:password with its '&', space and %41" $?
grew=0 before=$(src fake-remote kismet.datasource.num_packets)
for i in 1 2 3 4 5; do
    sleep 1
    now=$(src fake-remote kismet.datasource.num_packets)
    [ "$now" -gt "$before" ] 2>/dev/null && grew=$((grew + 1))
    before=$now
done
echo "   packets arrived in $grew of 5 seconds"
[ "$grew" -eq 5 ]; check "... and more every second, not in bursts" $?
! grep -q "\] N: " "$WORK/helper-remote.log"; check "no libwebsockets notices on the helper's stderr" $?
# A channel set the helper takes: the framework used to print an empty "INFO: " line for each
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_PASS" --data-urlencode 'json={"channel": "6"}' \
    "$API/datasource/by-uuid/$(src fake-remote kismet.datasource.uuid)/set_channel.cmd")
sleep 1
echo "   set_channel 6: HTTP $code"
[ "$code" = 200 ] && ! grep -qx "INFO: " "$WORK/helper-remote.log"
check "a channel set is taken, and leaves no empty \"INFO: \" line on the helper's stderr" $?

CPID=$(children_of "$HPID")
echo "   helper $HPID, capture process ${CPID:-none}; flock on the port held by: $(lock_holders "$PORT")"
# SigCgt, the signals a handler catches: SIGTERM is bit 14. On a pseudo-terminal the exclusive mode
# it ends is not used, so only this shows that the handler is there
caught=$(sed -n 's/^SigCgt:[[:space:]]*//p' "/proc/${CPID:-0}/status" 2>/dev/null)
[ -n "$caught" ] && [ $(( 0x$caught >> 14 & 1 )) -eq 1 ]
check "the capture process catches SIGTERM, to end the port's exclusive mode before it ends" $?
kill -HUP "$HPID" $CPID
sleep 2
before=$(src fake-remote kismet.datasource.num_packets)
sleep 1
[ -n "$CPID" ] && alive "$HPID" $CPID && [ "$(src fake-remote kismet.datasource.num_packets)" -gt "$before" ] 2>/dev/null
check "SIGHUP, which it was started ignoring, leaves the helper and its capture process capturing" $?

# The same board and radio have the same uuid, and Kismet would close the running source for the
# newcomer: a remote helper does not offer a port that another process holds
timeout 20 env "KISMET_CAP_USER=${USER_PASS%%:*}" "KISMET_CAP_PASSWORD=${USER_PASS#*:}" "$HELPER" \
    --connect "127.0.0.1:$RELAY" --disable-retry --source "esp32c5-$TTY:name=fake-remote2" \
    > "$WORK/helper-remote2.log" 2>&1
grep -qF "fake-remote2: /dev/$TTY is already in use by another capture; not offering it to Kismet" \
    "$WORK/helper-remote2.log"; check "a second remote helper on the same board is refused before it connects" $?
before=$(src fake-remote kismet.datasource.num_packets)
sleep 1
! logged remote "matches existing source" && [ "$(src fake-remote kismet.datasource.num_packets)" -gt "$before" ] 2>/dev/null
check "... and the first goes on capturing" $?

api "/datasource/by-uuid/$(src fake-remote kismet.datasource.uuid)/close_source.cmd" > /dev/null
sleep 2
[ -n "$CPID" ] && ! alive $CPID && [ -z "$(lock_holders "$PORT")" ]
check "close_source.cmd: the capture process ends, and the port is free" $?
for i in $(seq 1 30); do
    [ "$(src fake-remote kismet.datasource.running)" = 1 ] && [ -n "$(children_of "$HPID")" ] && break
    sleep 0.5
done
CPID=$(children_of "$HPID")
echo "   capture process now ${CPID:-none}"
[ "$(src fake-remote kismet.datasource.running)" = 1 ] && [ -n "$CPID" ]
check "... and the helper connects again 5 s later, and captures" $?

kill -TERM "$HPID"
sleep 1
[ -n "$CPID" ] && ! alive "$HPID" && ! alive $CPID && [ -z "$(lock_holders "$PORT")" ]
check "kill -TERM of the helper ends its capture process with it, and frees the port within 1 s" $?
for p in $HPID $CPID; do alive "$p" && kill "$p"; done
wait "$HPID" 2>/dev/null
HPID= CPID=
# libwebsockets reports each of the machine's routes to its own listeners as a connection starts,
# and its queue used to drop those past 40, with a warning each, on every connection
echo "   routes here, all tables: $(ip route show table all 2>/dev/null | wc -l) IPv4, $(ip -6 route show table all 2>/dev/null | wc -l) IPv6 (the warnings came with more than 40)"
! grep -q "rejecting message on queue depth" "$WORK/helper-remote.log"
check "no libwebsockets \"rejecting message on queue depth\" warnings, through two connections" $?

echo "== remote capture with an API key (KISMET_CAP_APIKEY)"
KEY=$(curl -s -u "$USER_PASS" --data-urlencode 'json={"name": "e2e", "role": "datasource", "duration": 0}' \
    "$API/auth/apikey/generate.cmd")
echo "   a datasource key from Kismet: ${KEY:-none}"
heads=$(grep -c "^== connection" "$WORK/requests.log")
(KISMET_CAP_APIKEY=$KEY exec "$HELPER" --connect "127.0.0.1:$RELAY" \
    --source "esp32c5-$TTY:name=fake-remotekey,uuid=E2E0E2E0-0000-0000-0000-00000000000A") \
    > "$WORK/helper-remotekey.log" 2>&1 &
HPID=$!
for i in $(seq 1 50); do
    [ "$(src fake-remotekey kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null && break
    sleep 0.2
done
[ "$(src fake-remotekey kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null; check "the helper logs in with it, and captures" $?
sed -n "/^== connection $((heads + 1))\$/,\$p" "$WORK/requests.log" > "$WORK/requests-key.txt"
echo "   $(grep -m1 "^GET " "$WORK/requests-key.txt")"
[ -n "$KEY" ] && grep -q "^GET " "$WORK/requests-key.txt" && ! grep "^GET " "$WORK/requests-key.txt" | grep -q "[?]"
check "the request line holds no key" $?
grep -qix "cookie: KISMET=$KEY" "$WORK/requests-key.txt"; check "the key is in Kismet's session cookie, KISMET" $?
CPID=$(children_of "$HPID")
kill -TERM "$HPID"
sleep 1
for p in $HPID $CPID; do alive "$p" && kill "$p"; done
wait "$HPID" 2>/dev/null
HPID= CPID=

echo "== remote capture with a login too long for the request's headers"
heads=$(grep -c "^== connection" "$WORK/requests.log")
timeout 20 env "KISMET_CAP_USER=${USER_PASS%%:*}" "KISMET_CAP_PASSWORD=$(printf '%5000s' | tr ' ' x)" "$HELPER" \
    --connect "127.0.0.1:$RELAY" --disable-retry --source "esp32c5-$TTY:name=fake-long" \
    > "$WORK/helper-long.log" 2>&1
status=$?
grep "FATAL" "$WORK/helper-long.log" | sed 's/^/   helper: /'
grep -qF "FATAL: The login does not fit in the websocket request's headers" "$WORK/helper-long.log"
check "it is refused with a reason, rather than sent cut short" $?
[ "$status" -ne 124 ] && [ "$(grep -c "^== connection" "$WORK/requests.log")" = "$heads" ]
check "... nothing is sent, and the helper ends (--disable-retry; exit status $status) rather than wait" $?
finish_case remote
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; RPID=
report remote
sed 's/^/   helper: /' "$WORK/helper-remote.log"

if [ "$FAILED" -ne 0 ]; then
    echo "--- logs kept in $WORK"
    trap - EXIT
    [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null
    [ -n "${FPID:-}" ] && kill "$FPID" 2>/dev/null
    for f in "$WORK"/kismet-*.log; do echo "--- $f"; grep -i "esp32c5\|error\|fake" "$f" | tail -20; done
    exit 1
fi
echo "ALL OK"
