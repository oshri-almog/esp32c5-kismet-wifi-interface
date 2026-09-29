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
# case runs the kismet_cap_esp32c5 next to KISMET too, or the one HELPER names. It starts its own
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
# retry, started with SIGHUP ignored as nohup does): the first packet within 3 s and more every
# second after, no libwebsockets notices, SIGHUP ignored, a second remote helper on the same board
# refused, close_source.cmd followed by a reconnect, and kill -TERM ending the capture process with
# the helper; a bare esp32c5 with no board plugged in, which Kismet has to hand to the helper (and
# retry) rather than give up on with "Unable to find driver" -- skipped when an Espressif
# USB-Serial-JTAG device is plugged in.

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
KISMET=${KISMET:-kismet}
HELPER=${HELPER:-$(dirname "$(command -v "$KISMET")")/kismet_cap_esp32c5}
PORT=/tmp/esp32c5-e2e
USER_PASS=e2e:e2e-password
API=http://localhost:2501
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null
    [ -n "${FPID:-}" ] && kill "$FPID" 2>/dev/null
    [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null
    [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
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

echo "== Wi-Fi: 2.4 and 5 GHz, Kismet hopping, a damaged record every 50"
run_case wifi 30 "esp32c5:device=$PORT,mode=wifi,name=fake-wifi" WIFI --garble 50
report wifi
has wifi 's.get("kismet.datasource.running") == 1'; check "wifi source running" $?
has wifi '"IEEE802.11" in phys'; check "wifi frames decoded as 802.11" $?
has wifi '"ESP32C5-FAKE-24" in names'; check "2.4 GHz access point seen" $?
has wifi '"ESP32C5-FAKE-5LOW" in names and "ESP32C5-FAKE-5HIGH" in names'; check "5 GHz access points seen (hopping works)" $?
has wifi 'freqs.get("IEEE802.11") == {2437000, 5180000, 5745000}'; check "their frequencies: 2437000, 5180000 and 5745000 kHz (channels 6, 36, 149)" $?
logged wifi "lost sync (damaged PCAP record)"; check "damaged record noticed" $?
has wifi 's.get("kismet.datasource.num_packets", 0) > 50'; check "capture continues after resync" $?

echo "== Wi-Fi: every 7th frame holds the restart signature in its SSID and a vendor element"
run_case inject 25 "esp32c5:device=$PORT,name=fake-inject" WIFI --inject 7
report inject
has inject 's.get("kismet.datasource.running") == 1'; check "source running with the injected frames" $?
faked inject "injected a frame holding the restart signature"; check "the fake sent injected frames" $?
! logged inject "lost sync"; check "no sync lost to a frame's payload" $?
! logged inject "restarted the stream"; check "no stream restart read from a frame's payload" $?
has inject '"02:E5:C5:00:00:99" in macs'; check "the injected frame reached Kismet (its BSSID seen)" $?
has inject 'any(n.startswith("FAKE-INJECT") for n in names)'; check "the injected frame's SSID is seen" $?
has inject '"ESP32C5-FAKE-24" in names'; check "the other frames are seen too" $?

echo "== Wi-Fi: the board restarts its stream in place every 40 records"
run_case restart 40 "esp32c5:device=$PORT,name=fake-restart" WIFI --restart-every 40
report restart
has restart 's.get("kismet.datasource.running") == 1'; check "source running through the restarts" $?
faked restart "after a record cut short"; check "the fake cut a record short" $?
logged restart "lost sync (the board restarted the stream)"; check "a restart at a record boundary noticed" $?
# Only a restart that cut a record short, seen by a helper in sync, gives this: the header read
# where the cut record claimed to end is misaligned, and never a valid one (its ts_usec comes
# from the radiotap header, 00 00 10 00, 1048576). The fake counts from each START, so the cut
# lands in a stream the helper is reading.
logged restart "lost sync (damaged PCAP record)"; check "a restart after a record cut short noticed" $?
has restart 's.get("kismet.datasource.num_packets", 0) > 100'; check "capture resumes after each restart" $?

echo "== 802.15.4 as esp32c5zigbee-<port>: the board boots in Wi-Fi and reboots, its port staying open"
run_case zigbee 30 "esp32c5zigbee-@TTY@:name=fake-zigbee" WIFI
report zigbee
faked zigbee "MODE 802154: rebooting"; check "the name asks for 802.15.4" $?
faked zigbee "rebooted in 802154 mode, the port stayed open"; check "board rebooted in place" $?
! faked zigbee "rebooting, lost: START"; check "no START lost in the reboot" $?
has zigbee 's.get("kismet.datasource.running") == 1'; check "zigbee source running after the reboot" $?
has zigbee '"802.15.4" in phys'; check "frames decoded as 802.15.4" $?
has zigbee 'freqs.get("802.15.4") == {2425000, 2475000}'; check "device frequencies 2425000 and 2475000 kHz (channels 15 and 25)" $?
has zigbee "s.get('kismet.datasource.interface') == 'esp32c5zigbee-$TTY'"; check "interface is esp32c5zigbee-$TTY" $?
has zigbee "s.get('kismet.datasource.capture_interface') == 'esp32c5-$TTY'"; check "capture interface is the port as --list names it (esp32c5-$TTY)" $?

echo "== 802.15.4 with --vanish: the port goes away in the reboot and comes back as another"
run_case vanish 30 "esp32c5:device=$PORT,mode=zigbee,name=fake-vanish" WIFI --vanish
report vanish
faked vanish "rebooting, the port goes away"; check "board rebooted and its port went away" $?
has vanish 's.get("kismet.datasource.running") == 1'; check "zigbee source running on the new port" $?
has vanish '"802.15.4" in phys'; check "frames decoded as 802.15.4 after the port came back" $?

echo "== Wi-Fi locked with channel=36,channel_hop=false; a second source on the same board"
start_case lock "esp32c5:device=$PORT,channel=36,channel_hop=false,name=fake-lock" WIFI
sleep 12
code=$(curl -s -o "$WORK/second.json" -w '%{http_code}' -u "$USER_PASS" \
    --data-urlencode "json={\"definition\": \"esp32c5-$TTY:name=fake-second\"}" "$API/datasource/add_source.cmd")
echo "   second source on esp32c5-$TTY: HTTP $code"
sleep 10
finish_case lock
report lock
has lock 's.get("kismet.datasource.running") == 1'; check "locked source running" $?
has lock 's.get("kismet.datasource.hopping") == 0 and s.get("kismet.datasource.channel") == "36"'; check "not hopping, on channel 36" $?
has lock '"ESP32C5-FAKE-5LOW" in names'; check "the access point on 36 seen" $?
has lock '"ESP32C5-FAKE-24" not in names and "ESP32C5-FAKE-5HIGH" not in names'; check "nothing from other channels" $?
! grep "CHANNELS" "$WORK/fake-lock.log" | grep -qv "CHANNELS 36:"; check "the board was only ever tuned to 36" $?
[ "$code" != 200 ]; check "the second source is refused" $?
logged lock "already in use"; check "... because the board is in use" $?

echo "== BTLE, set to channel 38: the board scans 37-39 together, and it is reported as 37; then to 40"
start_case btle "esp32c5:device=$PORT,mode=btle,name=fake-btle" BLE
sleep 10
uuid=$(src fake-btle kismet.datasource.uuid)
code=$(curl -s -o "$WORK/set38.json" -w '%{http_code}' -u "$USER_PASS" \
    --data-urlencode 'json={"channel": "38"}' "$API/datasource/by-uuid/$uuid/set_channel.cmd")
echo "   set_channel 38: HTTP $code"
sleep 5
# Refused the way Kismet's own helpers refuse a channel: the capture goes on where it was, and the
# reason goes to Kismet's log
code40=$(curl -s -o "$WORK/set40.json" -w '%{http_code}' -u "$USER_PASS" \
    --data-urlencode 'json={"channel": "40"}' "$API/datasource/by-uuid/$uuid/set_channel.cmd")
echo "   set_channel 40: HTTP $code40"
sleep 5
finish_case btle
report btle
has btle 's.get("kismet.datasource.running") == 1'; check "btle source running" $?
has btle '"BTLE" in phys'; check "packets decoded as BTLE (CRC accepted)" $?
has btle 'any("ESP32C5-FAKE" in n for n in names)'; check "advertiser name decoded" $?
! logged btle "does not mark BTLE packets as CRC checked"; check "current firmware's records need no fix-up" $?
[ "$code" = 200 ]; check "a set to channel 38 is taken" $?
has btle 's.get("kismet.datasource.channel") == "37" and s.get("kismet.datasource.hopping") == 0'; check "... and reported as 37" $?
has btle 'freqs.get("BTLE") == {2402000}'; check "BTLE devices on 2402000 kHz, channel 37's" $?
# the source was still running, on 37, after it: the checks above were made then
logged btle "fake-btle cannot tune to channel 40 in btle mode"; check "a set to channel 40 is refused, and Kismet logs why" $?

echo "== BTLE from older firmware: no CRC flags, CRC zeroed"
run_case oldble 20 "esp32c5btle-@TTY@:name=fake-oldble" BLE --old-firmware
report oldble
has oldble 's.get("kismet.datasource.running") == 1'; check "btle source running" $?
logged oldble "does not mark BTLE packets as CRC checked"; check "the helper says it fills in the CRC" $?
has oldble '"BTLE" in phys and any("ESP32C5-FAKE" in n for n in names)'; check "older firmware's packets decoded" $?

echo "== BTLE on firmware without it (the sibling's 1.0.0 and 1.1.0): MODE BLE ignored, Wi-Fi answers"
# The helper gives up 15 s after it opened; Kismet opens the source again 5 s after that, and a
# new helper says its lost sync once more, so two are fine and more are the old flood
run_case noradio 22 "esp32c5:device=$PORT,mode=btle,name=fake-noradio" WIFI --lacks BLE
report noradio
faked noradio "this firmware has no such radio, ignored"; check "the fake ignored MODE BLE" $?
n=$(grep -cF "fake-noradio: lost sync (the board sends link type 127, not 256)" "$WORK/kismet-noradio.log")
echo "   'lost sync (the board sends link type 127, not 256)' said $n time(s)"
[ "$n" -ge 1 ] && [ "$n" -le 2 ]; check "the wrong link type is said once per helper, not over and over" $?
! logged noradio "fake-noradio capturing"; check "never said to be capturing" $?
logged noradio "fake-noradio: no capture from the board on $PORT for 15 seconds"; check "the helper's 15 s reason reaches Kismet's log" $?

echo "== remote capture: kismet_cap_esp32c5 --connect over the websocket, with retry, started with SIGHUP ignored (nohup)"
python3 "$HERE/tools/fake_board.py" "$PORT" WIFI > "$WORK/fake-remote.log" 2>&1 &
FPID=$!
sleep 1
TTY=$(tty_name)
start_kismet remote
wait_kismet
echo "   $HELPER --connect localhost:2501 --source esp32c5-$TTY:name=fake-remote,channel=6,channel_hop=false"
T0=$(date +%s%N)
# The login from the environment (login_from_env), which the process list does not show
(trap '' HUP; KISMET_CAP_USER=${USER_PASS%%:*} KISMET_CAP_PASSWORD=${USER_PASS#*:} exec "$HELPER" \
    --connect localhost:2501 --source "esp32c5-$TTY:name=fake-remote,channel=6,channel_hop=false") \
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
timeout 20 env KISMET_CAP_USER=${USER_PASS%%:*} KISMET_CAP_PASSWORD=${USER_PASS#*:} "$HELPER" \
    --connect localhost:2501 --disable-retry --source "esp32c5-$TTY:name=fake-remote2" \
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
finish_case remote
report remote
grep -v "_lws_smd_msg_send" "$WORK/helper-remote.log" | sed 's/^/   helper: /'

echo "== a bare esp32c5 (no type=) with no board plugged in"
if [ -n "$(espressif_ttys)" ]; then
    echo "   SKIP: an Espressif USB-Serial-JTAG device is plugged in here ($(espressif_ttys | tr '\n' ' ')), which a bare esp32c5 would open"
else
    # Kismet probes a definition without type= and gives up for good when no helper claims it
    start_kismet noboard "esp32c5:name=fake-noboard"
    # Kismet (cfe427074) sometimes reopens a local source whose open failed twice at once, and one of
    # the two then ends with "IPC connection closed", which replaces the helper's reason as the
    # source's error until the next attempt: in about one run in four, with this helper as with the
    # one before it. So the reason has to be the source's error at some point, looked at every second.
    shown=1
    for i in $(seq 1 15); do
        sleep 1
        src fake-noboard kismet.datasource.error_reason | grep -q "no Espressif USB-Serial-JTAG device" && shown=0
    done
    finish_case noboard
    report noboard
    ! logged noboard "Unable to find driver"; check "the helper claims it: no 'Unable to find driver'" $?
    logged noboard "no Espressif USB-Serial-JTAG device"; check "Kismet shows the helper's reason" $?
    [ "$shown" -eq 0 ]; check "... as the source's error" $?
    logged noboard "Attempting to re-open source fake-noboard"; check "Kismet keeps trying, so a board plugged in later is found" $?
fi

if [ "$FAILED" -ne 0 ]; then
    echo "--- logs kept in $WORK"
    trap - EXIT
    [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null
    [ -n "${FPID:-}" ] && kill "$FPID" 2>/dev/null
    for f in "$WORK"/kismet-*.log; do echo "--- $f"; grep -i "esp32c5\|error\|fake" "$f" | tail -20; done
    exit 1
fi
echo "ALL OK"
