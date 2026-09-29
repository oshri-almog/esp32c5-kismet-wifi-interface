#!/bin/sh
# End to end: a fake board (tools/fake_board.py) -> kismet_cap_esp32c5 -> a real Kismet server,
# checking what Kismet reports through its REST API. Linux, no hardware needed; python3 (standard
# library only) and curl.
#
#     tests/kismet_e2e.sh                 Kismet on the PATH, patched with kismet/add-to-kismet.sh
#     KISMET=~/kismet-install/bin/kismet tests/kismet_e2e.sh
#
# KISMET has to be an installed kismet, with kismet_cap_esp32c5 next to it: Kismet starts its
# helpers from the bin directory it was configured with, not from the one it runs from. It starts
# its own Kismet on port 2501, with a login in a temporary --homedir and logging off, so stop any
# other Kismet first. Prints PASS or FAIL for each check and ALL OK at the end; on a failure it keeps
# the logs, says where, and exits with 1. More on the wiki page Development-and-Testing.
#
# The cases: each radio, and each device's frequency; a damaged record every 50; frames whose
# payload holds the whole restart signature (anyone on the air can send one); a board that restarts
# its stream in place; a radio switch that reboots the board with the port staying open (as the
# real board does) and one where the port goes away (--vanish); an 802.15.4 source named
# esp32c5zigbee-<port>; channel= with channel_hop=false; a second source on a board in use; BTLE,
# set to channel 38 and reported on 37; BTLE from older firmware; firmware without the radio asked
# for (--lacks), which has to be said once, never "capturing", and end in the helper's 15 s reason
# in Kismet's log; a bare esp32c5 with no board plugged in, which Kismet has to hand to the helper
# (and retry) rather than give up on with "Unable to find driver" -- skipped when an Espressif
# USB-Serial-JTAG device is plugged in.

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
KISMET=${KISMET:-kismet}
PORT=/tmp/esp32c5-e2e
USER_PASS=e2e:e2e-password
API=http://localhost:2501
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null
    [ -n "${FPID:-}" ] && kill "$FPID" 2>/dev/null
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

start_kismet() {  # start_kismet CASE DEFINITION
    echo "   source $2"
    HOME="$WORK/home" "$KISMET" --homedir "$WORK/home" --no-ncurses --no-logging \
        -c "$2" > "$WORK/kismet-$1.log" 2>&1 &
    KPID=$!
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

echo "== BTLE, set to channel 38: the board scans 37-39 together, and it is reported as 37"
start_case btle "esp32c5:device=$PORT,mode=btle,name=fake-btle" BLE
sleep 10
uuid=$(api /datasource/all_sources.json | python3 -c '
import json, sys
print(" ".join(s["kismet.datasource.uuid"] for s in json.load(sys.stdin) if s.get("kismet.datasource.name") == "fake-btle"))')
code=$(curl -s -o "$WORK/set38.json" -w '%{http_code}' -u "$USER_PASS" \
    --data-urlencode 'json={"channel": "38"}' "$API/datasource/by-uuid/$uuid/set_channel.cmd")
echo "   set_channel 38: HTTP $code"
sleep 10
finish_case btle
report btle
has btle 's.get("kismet.datasource.running") == 1'; check "btle source running" $?
has btle '"BTLE" in phys'; check "packets decoded as BTLE (CRC accepted)" $?
has btle 'any("ESP32C5-FAKE" in n for n in names)'; check "advertiser name decoded" $?
! logged btle "does not mark BTLE packets as CRC checked"; check "current firmware's records need no fix-up" $?
[ "$code" = 200 ]; check "a set to channel 38 is taken" $?
has btle 's.get("kismet.datasource.channel") == "37" and s.get("kismet.datasource.hopping") == 0'; check "... and reported as 37" $?
has btle 'freqs.get("BTLE") == {2402000}'; check "BTLE devices on 2402000 kHz, channel 37's" $?

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

echo "== a bare esp32c5 (no type=) with no board plugged in"
if [ -n "$(espressif_ttys)" ]; then
    echo "   SKIP: an Espressif USB-Serial-JTAG device is plugged in here ($(espressif_ttys | tr '\n' ' ')), which a bare esp32c5 would open"
else
    # Kismet probes a definition without type= and gives up for good when no helper claims it
    start_kismet noboard "esp32c5:name=fake-noboard"
    sleep 15
    finish_case noboard
    report noboard
    ! logged noboard "Unable to find driver"; check "the helper claims it: no 'Unable to find driver'" $?
    logged noboard "no Espressif USB-Serial-JTAG device"; check "Kismet shows the helper's reason" $?
    has noboard '"no Espressif USB-Serial-JTAG device" in (s.get("kismet.datasource.error_reason") or "")'; check "... as the source's error" $?
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
