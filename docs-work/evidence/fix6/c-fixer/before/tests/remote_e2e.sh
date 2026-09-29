#!/bin/sh
# End to end for the Python remote helper: a fake board (tools/fake_board.py) -> python3 -m esp32c5_kismet.remote
# -> a real Kismet server, over its websocket and over its legacy TCP remote capture port, checking what Kismet
# reports through its REST API. Linux, no hardware needed. The helper needs pyserial, msgpack and
# websocket-client (on the PYTHONPATH, say); the repository is put in front of it. The script's own checks
# need python3, curl and ss. Kismet has to be installed with kismet_cap_esp32c5 next to it, for the case
# where Kismet starts the C helper.
#
#     tests/remote_e2e.sh                 Kismet on the PATH, patched with kismet/add-to-kismet.sh
#     KISMET=~/kismet-install/bin/kismet PYTHON="$PWD/.venv/bin/python" tests/remote_e2e.sh
#
# PYTHON (default python3) is a command on the PATH or an absolute path, as the helper is started from a
# temporary directory. It starts its own Kismet with --homedir in a temporary directory, logging off, its
# web port on 2511 and its remote capture port on 3511 (HTTP_PORT and TCP_PORT change them), so a Kismet on
# 2501/3501 is left alone; it stops at once when either port is taken, and it only ever stops the processes
# it started. Prints PASS or FAIL for each check and ALL OK at the end; on a failure it keeps the logs in
# /tmp/esp32c5-remote-e2e.*, says where, and exits with 1. More on the wiki page Development-and-Testing.
#
# The cases: Wi-Fi over the websocket, with a login whose password holds '&' (the helper sends it in an
# Authorization header, which Kismet takes as it is; every websocket case logs in with it), and over --tcp;
# 802.15.4 as esp32c5zigbee-<port>, with the board rebooting in place (its port stays open, as the real
# board's does); BTLE, with the login from
# KISMET_CAP_USER and KISMET_CAP_PASSWORD, and a channel set to 38 that Kismet shows as 37; BTLE from older
# firmware, with the login from KISMET_CAP_APIKEY; frames whose payload holds the whole restart signature; a
# board that restarts its stream in place; channel=36,channel_hop=false on a source Kismet knows as hopping,
# and a second source on that board: from another helper, on another radio or as the very same source,
# which must not be offered to Kismet at all (and so not make Kismet close the running one), from
# kismet_cap_esp32c5 and from the same helper (which has to refuse to start, exit 2); a board another
# process holds the lock of, not offered until it is free while the helper's other source captures, and
# taken within about 5 s of its release; Kismet killed and started again, after which the helper has to
# come back under the same uuid. The helper is stopped with SIGTERM or SIGINT every time and has to exit 0,
# within 10 s. A login from the environment must not show on the helper's command line, and nothing may be
# left running at the end.

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
KISMET=${KISMET:-kismet}
PYTHON=${PYTHON:-python3}
HTTP_PORT=${HTTP_PORT:-2511}
TCP_PORT=${TCP_PORT:-3511}
# The password holds '&', where Kismet would cut a login in the websocket's address, and %41, which nothing
# may decode: the helper sends a login in an Authorization header, as it is
USER_PASS='e2e:e2e&pass%41word'
API=http://127.0.0.1:$HTTP_PORT
WORK=$(mktemp -d /tmp/esp32c5-remote-e2e.XXXXXX)
FAILED=0
KPID= FPID= F2PID= HPID= H2PID= H3PID= HOLDPID=
STARTED=  # every pid this script started, to check at the end that none is left

export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
unset KISMET_CAP_APIKEY KISMET_CAP_USER KISMET_CAP_PASSWORD

cleanup() {
    for p in $HOLDPID $H3PID $H2PID $HPID $F2PID $FPID $KPID; do
        kill -9 "$p" 2>/dev/null
    done
    wait 2>/dev/null
    if [ "$FAILED" -eq 0 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

check() {  # check NAME CONDITION-EXIT-STATUS
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi
}

# Stops a process this script started and waits for it, but not for ever: a helper that ignores the signal
# (sh starts background jobs with SIGINT ignored, so one that relies on KeyboardInterrupt would) must fail
# the run, not hang it. The sleep between the checks also has the shell collect a child that has exited,
# so that kill -0 does not find it as a zombie.
stop_pid() {  # stop_pid SIGNAL PID   waits up to 10 s; the exit status in PCODE, 124 after a kill -9
    PCODE=0
    [ -n "$2" ] || return 0
    kill "-$1" "$2" 2>/dev/null
    i=0
    while kill -0 "$2" 2>/dev/null && [ $i -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$2" 2>/dev/null; then
        echo "   pid $2 still running 10 s after SIG$1; killed"
        kill -9 "$2" 2>/dev/null
        wait "$2" 2>/dev/null
        PCODE=124
    else
        wait "$2"
        PCODE=$?
    fi
}

if ! "$PYTHON" -c "import serial, msgpack, websocket" 2>/dev/null; then
    echo "the helper needs pyserial, msgpack and websocket-client for $PYTHON (PYTHONPATH=$PYTHONPATH)"
    exit 1
fi
if ss -ltn 2>/dev/null | grep -qE ":($HTTP_PORT|$TCP_PORT) "; then
    echo "something already listens on $HTTP_PORT or $TCP_PORT; set HTTP_PORT and TCP_PORT to free ones"
    exit 1
fi

# Kismet asks for a login on first start unless one is configured. It finds kismet_httpd.conf under %h/.kismet,
# and %h is the passwd entry's home, not $HOME, so it is pointed here with --homedir.
mkdir -p "$WORK/home/.kismet"
printf 'httpd_username=%s\nhttpd_password=%s\n' "${USER_PASS%%:*}" "${USER_PASS#*:}" > "$WORK/home/.kismet/kismet_httpd.conf"
printf 'httpd_port=%s\nremote_capture_listen=127.0.0.1\nremote_capture_port=%s\n' "$HTTP_PORT" "$TCP_PORT" \
    > "$WORK/override.conf"

api() {  # api PATH [JSON]
    if [ $# -gt 1 ]; then
        curl -s -u "$USER_PASS" --data-urlencode "json=$2" "$API$1"
    else
        curl -s -u "$USER_PASS" "$API$1"
    fi
}

start_kismet() {  # start_kismet NAME   its output in KLOG
    KLOG=$WORK/kismet-$1.log
    (cd "$WORK" && exec "$KISMET" --homedir "$WORK/home" --no-ncurses --no-logging \
        --override "$WORK/override.conf") > "$KLOG" 2>&1 &
    KPID=$!
    STARTED="$STARTED $KPID"
    for i in $(seq 1 120); do
        curl -sf -o /dev/null -u "$USER_PASS" "$API/system/status.json" && return 0
        sleep 0.5
    done
    echo "   Kismet did not come up on $HTTP_PORT"
    return 1
}

stop_kismet() {  # stop_kismet [SIGNAL]
    stop_pid "${1:-TERM}" "$KPID"
    KPID=
}

start_fake() {  # start_fake CASE PORT [FAKE-OPTIONS]   sets TTY, the port's name under /dev (pts/3)
    fcase=$1 fport=$2
    shift 2
    rm -f "$fport"
    "$PYTHON" "$HERE/tools/fake_board.py" "$fport" "$@" > "$WORK/fake-$fcase.log" 2>&1 &
    FPID=$!
    STARTED="$STARTED $FPID"
    for i in $(seq 1 50); do
        grep -q "booted" "$WORK/fake-$fcase.log" 2>/dev/null && break
        sleep 0.1
    done
    TTY=$(readlink -f "$fport" | sed 's|^/dev/||')
}

stop_fake() {
    stop_pid TERM "$FPID"
    FPID=
}

start_helper() {  # start_helper NAME ARGS...   the helper's pid in HPID, its log in helper-NAME.log;
                  # HENV holds NAME=VALUE words for its environment, for this one helper
    hname=$1
    shift
    (cd "$WORK" && exec env ${HENV:-} "$PYTHON" -u -m esp32c5_kismet.remote --debug "$@") \
        > "$WORK/helper-$hname.log" 2>&1 &
    HPID=$!
    STARTED="$STARTED $HPID"
    echo "   helper: ${HENV:+$(echo "$HENV" | sed 's/=[^ ]*/=.../g') }$*"
    HENV=
}

stop_helper() {  # stop_helper SIGNAL   the exit status in HCODE (124: it had to be killed)
    stop_pid "$1" "$HPID"
    HCODE=$PCODE
    HPID=
}

ws() {  # the websocket connection with the e2e login
    echo --connect "127.0.0.1:$HTTP_PORT" --user "${USER_PASS%%:*}" --password "${USER_PASS#*:}"
}

snapshot() {  # snapshot CASE   what Kismet has now: sources, and devices with who saw them
    api /datasource/all_sources.json > "$WORK/sources-$1.json"
    api /devices/views/all/devices.json \
        '{"fields": ["kismet.device.base.phyname", "kismet.device.base.name", "kismet.device.base.commonname", "kismet.device.base.macaddr", "kismet.device.base.seenby"]}' \
        > "$WORK/devices-$1.json"
}

# The Python below sees: s, the source named fake-SOURCE; the devices it has seen, with their names, phys, macs
PYLOAD='
import json, sys
def load(path):  # a refused login or a Kismet that is not up answers with something else
    try:
        return json.load(open(path))
    except ValueError:
        return None
sources = load(sys.argv[1])
if sources is None:
    print("   no JSON from Kismet in %s" % sys.argv[1])
    sources = []
alldev = load(sys.argv[2]) or []
src = [s for s in sources if s.get("kismet.datasource.name") == "fake-" + sys.argv[3]]
s = src[0] if src else {}
uuid = s.get("kismet.datasource.uuid")
def seenby(d):
    seen = d.get("kismet.device.base.seenby") or []
    return seen.values() if isinstance(seen, dict) else seen
devices = [d for d in alldev if any(x.get("kismet.common.seenby.uuid") == uuid for x in seenby(d))]
names = {d.get("kismet.device.base.commonname") or d.get("kismet.device.base.name") or "" for d in devices}
phys = {d.get("kismet.device.base.phyname") for d in devices}
macs = {d.get("kismet.device.base.macaddr") for d in devices}
'

report() {  # report SNAPSHOT SOURCE
    python3 -c "$PYLOAD"'
print("   fake-%s: running=%s error=%r packets=%s hopping=%s channel=%r interface=%r uuid=%s hardware=%r" % (
    sys.argv[3], s.get("kismet.datasource.running"), s.get("kismet.datasource.error_reason"),
    s.get("kismet.datasource.num_packets"), s.get("kismet.datasource.hopping"), s.get("kismet.datasource.channel"),
    s.get("kismet.datasource.interface"), uuid, s.get("kismet.datasource.hardware")))
print("   phys: %s; names: %s" % (", ".join(str(p) for p in sorted(phys, key=str)),
                                ", ".join(repr(n) for n in sorted(names) if n)))
' "$WORK/sources-$1.json" "$WORK/devices-$1.json" "$2"
}

has() {  # has SNAPSHOT SOURCE PYTHON-EXPRESSION
    python3 -c "$PYLOAD"'
sys.exit(0 if eval(sys.argv[4]) else 1)
' "$WORK/sources-$1.json" "$WORK/devices-$1.json" "$2" "$3"
}

said() {  # said NAME TEXT     (in the helper's log)
    grep -qF -- "$2" "$WORK/helper-$1.log"
}

faked() {  # faked CASE TEXT   (in the fake board's log)
    grep -qF -- "$2" "$WORK/fake-$1.log"
}

stopped_clean() {  # stopped_clean NAME SIGNAL   after stop_helper
    check "helper stopped by SIG$2 exits 0 (exit $HCODE)" $([ "$HCODE" -eq 0 ]; echo $?)
    said "$1" "stop signal SIG$2" && said "$1" "stopping"; check "... it says it got SIG$2 and stops" $?
    ! said "$1" "Traceback"; check "... and nothing in its log went wrong unexpectedly" $?
}

uuid_of() {  # uuid_of MODE DEVICE   what the helper (and kismet_cap_esp32c5) call a board without a MAC
    "$PYTHON" -c "from esp32c5_kismet import remote; print(remote.default_uuid('$1', None, '$2'))"
}

start_kismet main || exit 1

echo "== Wi-Fi over the websocket: 2.4 and 5 GHz, Kismet hopping; stopped with SIGTERM"
PORT=$WORK/port-wifi
start_fake wifi "$PORT" WIFI
start_helper wifi $(ws) --source "esp32c5:device=$PORT,name=fake-wifi"
sleep 25
snapshot wifi
stop_helper TERM
stop_fake
report wifi wifi
said wifi "connected, offering it to Kismet" && ! said wifi "refused the websocket"
check "the login passes over the websocket, its password holding '&' and %41" $?
has wifi wifi 's.get("kismet.datasource.running") == 1'; check "wifi source running" $?
has wifi wifi '"IEEE802.11" in phys'; check "frames decoded as 802.11" $?
has wifi wifi '"ESP32C5-FAKE-24" in names'; check "2.4 GHz access point seen" $?
has wifi wifi '"ESP32C5-FAKE-5LOW" in names and "ESP32C5-FAKE-5HIGH" in names'; check "5 GHz access points seen (hopping works)" $?
WIFI_UUID=$(uuid_of wifi "$PORT")
has wifi wifi "uuid == '$WIFI_UUID'"; check "uuid $WIFI_UUID, as kismet_cap_esp32c5 would give this board" $?
has wifi wifi 's.get("kismet.datasource.hardware") == "ESP32-C5"'; check "hardware ESP32-C5 for a port with no USB identity" $?
stopped_clean wifi TERM

echo "== Wi-Fi over legacy TCP (port $TCP_PORT) as esp32c5-<port>; stopped with SIGINT"
# A Kismet that has not seen the fake's frames. It drops a frame that matches one of the last 1024 it took,
# from any source, as a duplicate, and credits no device to the source that sent it; a fake board started
# again sends the same frames as before, at the same points of Kismet's hopping
stop_kismet TERM
start_kismet tcp || exit 1
PORT=$WORK/port-tcp
start_fake tcp "$PORT" WIFI
start_helper tcp --tcp --connect "127.0.0.1:$TCP_PORT" --source "esp32c5-$TTY:name=fake-tcp"
sleep 20
snapshot tcp
stop_helper INT
stop_fake
report tcp tcp
has tcp tcp 's.get("kismet.datasource.running") == 1'; check "tcp source running" $?
has tcp tcp '"IEEE802.11" in phys and s.get("kismet.datasource.num_packets", 0) > 20'; check "frames decoded as 802.11 over TCP" $?
has tcp tcp "s.get('kismet.datasource.interface') == 'esp32c5-$TTY'"; check "interface esp32c5-$TTY" $?
stopped_clean tcp INT

echo "== 802.15.4 as esp32c5zigbee-<port>: the board boots in Wi-Fi and reboots, its port staying open"
PORT=$WORK/port-zigbee
start_fake zigbee "$PORT" WIFI
start_helper zigbee $(ws) --source "esp32c5zigbee-$TTY:name=fake-zigbee"
sleep 25
snapshot zigbee
stop_helper TERM
stop_fake
report zigbee zigbee
faked zigbee "MODE 802154: rebooting"; check "the name asks for 802.15.4" $?
faked zigbee "rebooted in 802154 mode, the port stayed open"; check "board rebooted in place" $?
# Kismet's hops may land in the reboot and be lost, which the next hop makes good; the handshake may not
! faked zigbee "rebooting, lost: START" && ! faked zigbee "rebooting, lost: DWELL"
check "no START lost in the reboot (it waited for MODE to settle)" $?
has zigbee zigbee 's.get("kismet.datasource.running") == 1'; check "zigbee source running after the reboot" $?
has zigbee zigbee '"802.15.4" in phys'; check "frames decoded as 802.15.4" $?
has zigbee zigbee "s.get('kismet.datasource.interface') == 'esp32c5zigbee-$TTY'"; check "interface esp32c5zigbee-$TTY" $?
stopped_clean zigbee TERM

echo "== BTLE as esp32c5btle-<port>, the login from KISMET_CAP_USER and KISMET_CAP_PASSWORD; channel set to 38"
PORT=$WORK/port-btle
start_fake btle "$PORT" BLE
HENV="KISMET_CAP_USER=${USER_PASS%%:*} KISMET_CAP_PASSWORD=${USER_PASS#*:}"
start_helper btle --connect "127.0.0.1:$HTTP_PORT" --source "esp32c5btle-$TTY:name=fake-btle"
sleep 18
# The board scans 37, 38 and 39 together whatever it is asked: 38 is taken, and shown as 37
code=$(curl -s -o "$WORK/btle-set-channel.txt" -w '%{http_code}' -u "$USER_PASS" --data-urlencode 'json={"channel": "38"}' \
    "$API/datasource/by-uuid/$(uuid_of btle "/dev/$TTY")/set_channel.cmd")
sleep 2
snapshot btle
! tr '\0' ' ' < "/proc/$HPID/cmdline" | grep -qF "${USER_PASS#*:}"; check "the password is not on the helper's command line" $?
stop_helper INT
stop_fake
report btle btle
has btle btle 's.get("kismet.datasource.running") == 1'; check "btle source running with the login from the environment" $?
has btle btle '"BTLE" in phys'; check "packets decoded as BTLE (CRC accepted)" $?
has btle btle 'any("ESP32C5-FAKE" in n for n in names)'; check "advertiser name decoded" $?
! said btle "does not mark BTLE packets as CRC checked"; check "current firmware's records need no fix-up" $?
[ "$code" = 200 ] && has btle btle 's.get("kismet.datasource.channel") == "37" and s.get("kismet.datasource.hopping") == 0'
check "set_channel 38 on BTLE: accepted (HTTP $code), and Kismet shows channel 37, not hopping" $?
stopped_clean btle INT

echo "== BTLE from older firmware (no CRC flags, CRC zeroed), the login from KISMET_CAP_APIKEY"
# A Kismet that has not seen the fake's advertiser: it drops a frame it has had before, from any source,
# as a duplicate, so the one BTLE case before would leave nothing for this one to prove
stop_kismet TERM
start_kismet oldble || exit 1
KEY=$(api /auth/apikey/generate.cmd '{"name": "esp32c5-e2e", "role": "datasource", "duration": 0}')
echo "   API key with the datasource role: ${KEY:+made}"
PORT=$WORK/port-oldble
start_fake oldble "$PORT" BLE --old-firmware
HENV="KISMET_CAP_APIKEY=$KEY"
start_helper oldble --connect "127.0.0.1:$HTTP_PORT" --source "esp32c5:device=$PORT,mode=btle,name=fake-oldble"
sleep 20
snapshot oldble
! tr '\0' ' ' < "/proc/$HPID/cmdline" | grep -qF "$KEY"; check "the API key is not on the helper's command line" $?
stop_helper TERM
stop_fake
report oldble oldble
has oldble oldble 's.get("kismet.datasource.running") == 1'; check "btle source running with the API key from the environment" $?
[ "$(grep -c "does not mark BTLE packets as CRC checked" "$WORK/helper-oldble.log")" -eq 1 ]; check "the helper says once that it fills in the CRC" $?
has oldble oldble '"BTLE" in phys and any("ESP32C5-FAKE" in n for n in names)'; check "older firmware's packets decoded" $?
stopped_clean oldble TERM

echo "== Wi-Fi: every 7th frame holds the restart signature in its SSID and a vendor element"
PORT=$WORK/port-inject
start_fake inject "$PORT" WIFI --inject 7
start_helper inject $(ws) --source "esp32c5:device=$PORT,name=fake-inject"
sleep 25
snapshot inject
stop_helper TERM
stop_fake
report inject inject
faked inject "injected a frame holding the restart signature"; check "the fake sent injected frames" $?
! said inject "lost sync"; check "no sync lost to a frame's payload" $?
has inject inject 's.get("kismet.datasource.running") == 1'; check "source running with the injected frames" $?
has inject inject '"02:E5:C5:00:00:99" in macs'; check "the injected frame reached Kismet (its BSSID seen)" $?
has inject inject 'any(n.startswith("FAKE-INJECT") for n in names)'; check "the injected frame's SSID is seen" $?
has inject inject '"ESP32C5-FAKE-24" in names'; check "the other frames are seen too" $?
stopped_clean inject TERM

echo "== Wi-Fi: the board restarts its stream in place every 40 records"
PORT=$WORK/port-restart
start_fake restart "$PORT" WIFI --restart-every 40
start_helper restart $(ws) --source "esp32c5:device=$PORT,name=fake-restart"
sleep 30
snapshot restart
stop_helper INT
stop_fake
report restart restart
faked restart "after a record cut short"; check "the fake cut a record short" $?
said restart "lost sync (the board restarted the stream)"; check "a restart at a record boundary noticed" $?
has restart restart 's.get("kismet.datasource.running") == 1'; check "source running through the restarts" $?
has restart restart 's.get("kismet.datasource.num_packets", 0) > 100'; check "capture resumes after each restart" $?
stopped_clean restart INT

echo "== channel=36,channel_hop=false on a source Kismet knows as hopping; a second source on the same board"
PORT=$WORK/port-lock
start_fake lockhop "$PORT" WIFI
start_helper lockhop $(ws) --source "esp32c5:device=$PORT,name=fake-lock"
sleep 10
snapshot lockhop
stop_helper TERM
stop_fake
has lockhop lock 's.get("kismet.datasource.hopping") == 1'; check "the source hops first" $?
start_fake lock "$PORT" WIFI
start_helper lock $(ws) --source "esp32c5:device=$PORT,channel=36,channel_hop=false,name=fake-lock"
sleep 8
LOCKPID=$HPID
# another helper on the board: on another radio, and as the very same source (the same uuid)
start_helper second $(ws) --source "esp32c5zigbee-$TTY:name=fake-second"
H2PID=$HPID
start_helper same $(ws) --source "esp32c5:device=$PORT,channel=36,channel_hop=false,name=fake-lock"
H3PID=$HPID HPID=$LOCKPID
sleep 10
snapshot lock
stop_pid TERM "$H2PID"; H2CODE=$PCODE; H2PID=
stop_pid TERM "$H3PID"; H3CODE=$PCODE; H3PID=
KLINES=$(wc -l < "$KLOG")
# kismet_cap_esp32c5 as a source of Kismet's own, once: retry=false, or Kismet would keep starting it
code=$(curl -s -o "$WORK/c-helper.txt" -w '%{http_code}' -u "$USER_PASS" \
    --data-urlencode "json={\"definition\": \"esp32c5-$TTY:name=fake-c,retry=false\"}" "$API/datasource/add_source.cmd")
sleep 2
# refused at startup, so it ends at once; if it did not, the time limit fails it (exit 124) instead of the run
# waiting for it for ever
timeout 20 "$PYTHON" -m esp32c5_kismet.remote --tcp --connect "127.0.0.1:$TCP_PORT" --source "esp32c5:device=$PORT" \
    --source "esp32c5zigbee-$TTY" > "$WORK/helper-dup.log" 2>&1
DUPCODE=$?
sleep 2
stop_helper INT
stop_fake
report lock lock
has lock lock 's.get("kismet.datasource.running") == 1'; check "locked source running" $?
has lock lock 's.get("kismet.datasource.hopping") == 0 and s.get("kismet.datasource.channel") == "36"'; check "not hopping any more, on channel 36" $?
has lock lock "uuid == '$(uuid_of wifi "$PORT")'"; check "... the same source Kismet saw hopping (same uuid)" $?
has lock lock '"ESP32C5-FAKE-5LOW" in names'; check "the access point on 36 seen" $?
! grep "CHANNELS" "$WORK/fake-lock.log" | grep -qv "CHANNELS 36:"; check "the board was only ever tuned to 36" $?
said second "fake-second: /dev/$TTY is already in use by another capture; not offering it to Kismet"
check "a second helper on the board, on another radio, does not offer it: in use" $?
! grep -q "fake-second" "$KLOG"; check "... so Kismet never hears of it" $?
check "... that helper still stops with exit 0 (exit $H2CODE)" $([ "$H2CODE" -eq 0 ]; echo $?)
said same "fake-lock: $PORT is already in use by another capture; not offering it to Kismet"
check "another helper with the very same source does not offer it either" $?
! grep -q "The running instance will be closed" "$KLOG"
check "... so Kismet does not close the running source in its favour" $?
check "... that helper stops with exit 0 too (exit $H3CODE)" $([ "$H3CODE" -eq 0 ]; echo $?)
[ "$code" != 200 ] && tail -n "+$((KLINES + 1))" "$KLOG" | grep -v "fake-second" |
    grep -q "already in use by another capture"
check "kismet_cap_esp32c5 is refused the board the Python helper holds (HTTP $code)" $?
[ "$DUPCODE" -eq 2 ] && grep -q "both want" "$WORK/helper-dup.log"; check "one helper given the board twice refuses to start (exit $DUPCODE)" $?
stopped_clean lock INT

echo "== A board another process holds: not offered until it is free, while the helper's other source captures"
PORT=$WORK/port-held
start_fake free "$WORK/port-free" 802154
F2PID=$FPID
start_fake held "$PORT" WIFI
# the lock the helpers take (and picocom), held by a process that is neither: /proc/locks is all there is to see
"$PYTHON" -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("holding", os.path.realpath(sys.argv[1]), flush=True)
time.sleep(120)' "$PORT" > "$WORK/holder.log" 2>&1 &
HOLDPID=$!
STARTED="$STARTED $HOLDPID"
sleep 1
start_helper held $(ws) --source "esp32c5:device=$PORT,name=fake-held" \
    --source "esp32c5:device=$WORK/port-free,mode=zigbee,name=fake-free"
sleep 15
snapshot held1
cp "$KLOG" "$WORK/kismet-held1.log"
cp "$WORK/fake-held.log" "$WORK/fake-held1.log"
T0=$(date +%s%N)
stop_pid TERM "$HOLDPID"; HOLDPID=
# taken as soon as the next look finds it free, 5 s at most, and capturing a second or so after that
for i in $(seq 1 100); do
    said held "name=fake-held: connected, offering it to Kismet" && break
    sleep 0.1
done
OFFERED_MS=$((($(date +%s%N) - T0) / 1000000))
for i in $(seq 1 30); do
    snapshot held2
    has held2 held 's.get("kismet.datasource.running") == 1 and s.get("kismet.datasource.num_packets", 0) > 0' && break
    sleep 0.5
done
CAPTURING_MS=$((($(date +%s%N) - T0) / 1000000))
sleep 2
snapshot held2
stop_helper TERM
stop_fake
FPID=$F2PID F2PID=
stop_fake
echo "   $(cat "$WORK/holder.log"); released: offered after $OFFERED_MS ms, capturing in Kismet after $CAPTURING_MS ms"
report held1 held
report held1 free
report held2 held
report held2 free
grep -F "is already in use" "$WORK/helper-held.log" | sed 's/^/   helper: /'
has held1 held 's == {}' && ! grep -q "fake-held" "$WORK/kismet-held1.log"
check "the held board is not offered to Kismet while the lock is held" $?
[ "$(grep -cF "fake-held: $PORT is already in use by another capture; not offering it to Kismet until it is free (looked at again every 5 seconds)" \
    "$WORK/helper-held.log")" -eq 1 ]
check "... which the helper says once, and that it looks again every 5 s" $?
! faked held1 "START answered"; check "... and the board is left alone meanwhile: not asked to capture" $?
has held1 free 's.get("kismet.datasource.running") == 1 and s.get("kismet.datasource.num_packets", 0) > 0 and "802.15.4" in phys'
check "the helper's other source captures meanwhile" $?
[ "$OFFERED_MS" -le 5500 ]; check "the board is offered within 5 s of its release ($OFFERED_MS ms)" $?
has held2 held "s.get('kismet.datasource.running') == 1 and s.get('kismet.datasource.num_packets', 0) > 0 and uuid == '$(uuid_of wifi "$PORT")'"
check "... and captures, as the source it is (capturing after $CAPTURING_MS ms)" $?
has held2 free 's.get("kismet.datasource.running") == 1'; check "the other source is still running" $?
stopped_clean held TERM

echo "== Kismet killed and started again: the helper comes back with the same uuid"
PORT=$WORK/port-rk
start_fake rk "$PORT" WIFI
start_helper rk $(ws) --source "esp32c5:device=$PORT,name=fake-rk"
sleep 12
snapshot rk1
stop_kismet KILL
sleep 2
start_kismet again || true
for i in $(seq 1 60); do
    snapshot rk2
    has rk2 rk 's.get("kismet.datasource.running") == 1 and s.get("kismet.datasource.num_packets", 0) > 0' && break
    sleep 1
done
sleep 3
snapshot rk2
RK_UUID=$(uuid_of wifi "$PORT")
alive=$(kill -0 "$HPID" 2>/dev/null && echo 0 || echo 1)
stop_helper TERM
stop_fake
report rk1 rk
report rk2 rk
has rk1 rk "s.get('kismet.datasource.running') == 1 and uuid == '$RK_UUID'"; check "capturing before Kismet goes" $?
check "the helper outlived Kismet" "$alive"
said rk "connection ended"; check "it saw the connection end" $?
[ "$(grep -c "connected, offering it to Kismet as" "$WORK/helper-rk.log")" -ge 2 ] &&
    [ "$(grep "connected, offering it to Kismet as" "$WORK/helper-rk.log" | grep -vc "as $RK_UUID")" -eq 0 ]
check "it connected again, always as $RK_UUID" $?
has rk2 rk "s.get('kismet.datasource.running') == 1 and uuid == '$RK_UUID' and s.get('kismet.datasource.num_packets', 0) > 0"
check "the new Kismet has the source running, same uuid, packets coming" $?
stopped_clean rk TERM

stop_kismet TERM
sleep 1
# what was started by this script, by pid (a helper started as esp32c5-pts/N has nothing of $WORK in its
# command line), and anything else with $WORK in its command line
left=$(pgrep -f "$WORK" | tr '\n' ' ')
for p in $STARTED; do
    if kill -0 "$p" 2>/dev/null; then left="$left$p "; fi
done
! ss -ltn | grep -qE ":($HTTP_PORT|$TCP_PORT) " && [ -z "$left" ]; check "nothing left running ($left)" $?

if [ "$FAILED" -ne 0 ]; then
    echo "--- logs kept in $WORK"
    for f in "$WORK"/helper-*.log; do echo "--- $f"; grep -E "ERROR|WARNING|Traceback|stop|ended|refused" "$f" | tail -8; done
    exit 1
fi
echo "ALL OK"
