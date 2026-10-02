#!/bin/sh
# End to end: a fake board (tools/fake_board.py) -> kismet_cap_esp32c5 -> a real Kismet server,
# checking what Kismet reports through its REST API. Linux, no hardware needed; python3 (standard
# library only) and curl, and openssl for the TLS cases.
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
# request: the login, from KISMET_CAP_USER and KISMET_CAP_PASSWORD, whose password holds '&', a
# space and %41, in an Authorization header and nowhere in the request line, the Host and Origin
# headers with the port, the first packet within 3 s and more every second after, a channel set
# without an empty "INFO: " line, no libwebsockets notices, SIGHUP ignored, a second remote helper
# on the same board refused, close_source.cmd followed by a reconnect, and kill -TERM ending the
# capture process with the helper; an API key, in Kismet's session cookie and not in the request
# line; a login and an API key too long for the request's headers, each refused with a reason
# instead of cut short; a websocket answered with a redirect -- to another host, to another port,
# to https://, to a path on the same server, with no Location, echoing the request's query with the
# login in it, with control bytes, and over TLS -- which must not be followed, nor where it points
# connected to (the login would go along), said with the status and where it points, up to its
# query and with control bytes percent-encoded; over TLS through a relay of its own with only
# --ssl-certificate, which implies --ssl, the login in the Basic header, the Host header with the
# port and TLS's server name without it (TLS needs openssl, and is skipped without it); no
# libwebsockets queue warnings on a connection in a network namespace of its own with 200 routes
# (as root, or where user namespaces are allowed; skipped otherwise); a bare esp32c5 with no board
# plugged in, which Kismet has to hand to the helper (and retry) rather than give up on with
# "Unable to find driver" -- skipped when an Espressif USB-Serial-JTAG device is plugged in.

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
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
    [ -n "${TPID:-}" ] && kill "$TPID" 2>/dev/null
    [ -n "${XPID:-}" ] && kill "$XPID" 2>/dev/null
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
# passes on -- request line and headers, after a line "== connection N" -- to LOG, and then
# passes everything on as it is. It takes a free port of 127.0.0.1, and the same one of ::1 where
# there is one (localhost may be either), and writes it to PORTFILE. Given a certificate and its
# key, it speaks TLS, and the "== connection" line names the server name (SNI) the client sent.
relay() {  # relay LOG PORTFILE [CERTIFICATE KEY]
    python3 -c '
import socket, ssl, sys, threading
log, portfile = sys.argv[1], sys.argv[2]
ctx = None
names = {}  # the server name each TLS connection asked for, by its socket
if len(sys.argv) > 4:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[3], sys.argv[4])
    ctx.sni_callback = lambda s, name, c: names.__setitem__(id(s), name)
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
    if ctx:
        try:
            client = ctx.wrap_socket(client, server_side=True)
        except OSError as e:
            with open(log, "ab") as f:
                f.write(b"== a TLS handshake that failed: %s\n" % repr(e).encode())
            return client.close()
    head = b""
    while b"\r\n\r\n" not in head:
        data = client.recv(65536)
        if not data:
            return client.close()
        head += data
    count[0] += 1
    tls = b" (TLS, server name %r)" % (names.pop(id(client), None),) if ctx else b""
    with open(log, "ab") as f:
        f.write(b"== connection %d%s\n" % (count[0], tls) + head.split(b"\r\n\r\n")[0].replace(b"\r", b"") + b"\n")
    upstream = socket.create_connection(("127.0.0.1", 2501))
    upstream.sendall(head)
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
    pipe(client, upstream)
def accept(server):
    while True:
        threading.Thread(target=serve, args=(server.accept()[0],), daemon=True).start()
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(16)
port = server.getsockname()[1]
try:
    server6 = socket.socket(socket.AF_INET6)
    server6.bind(("::1", port))
    server6.listen(16)
    threading.Thread(target=accept, args=(server6,), daemon=True).start()
except OSError:
    pass
open(portfile, "w").write(str(port))
accept(server)
' "$@" > "$1.out" 2>&1 &
    RELAY_PID=$!
    for i in $(seq 1 50); do [ -s "$2" ] && break; sleep 0.1; done
}

start_relay() {  # the plain relay, on port RELAY
    relay "$WORK/requests.log" "$WORK/relay.port"
    RPID=$RELAY_PID
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
# Before add-to-kismet.sh's fix the Host header had no port, "Host: 127.0.0.1"; Kismet, which
# took the upgrade above, reads neither header
sed -n '/^== connection 1$/,/^== connection 2$/p' "$WORK/requests.log" > "$WORK/request-1.txt"
grep -i "^host: \|^origin: " "$WORK/request-1.txt" | sed 's/^/   /'
grep -qx "Host: 127.0.0.1:$RELAY" "$WORK/request-1.txt" && grep -qx "Origin: http://127.0.0.1:$RELAY" "$WORK/request-1.txt"
check "the Host and Origin headers name the port too, which is not ws://'s 80" $?
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

echo "== remote capture with a login, and then an API key, too long for the request's headers"
too_long() {  # too_long NAME WHAT-IT-SAYS LOGIN-VARIABLE...
    name=$1 said=$2
    shift 2
    heads=$(grep -c "^== connection" "$WORK/requests.log")
    timeout 20 env "$@" "$HELPER" --connect "127.0.0.1:$RELAY" --disable-retry \
        --source "esp32c5-$TTY:name=fake-long" > "$WORK/helper-long-$name.log" 2>&1
    status=$?
    grep "FATAL" "$WORK/helper-long-$name.log" | sed 's/^/   helper: /'
    grep -qF "$said" "$WORK/helper-long-$name.log"
    check "a $name of 5000 characters is refused with a reason that names it, rather than sent cut short" $?
    [ "$status" -ne 124 ] && [ "$(grep -c "^== connection" "$WORK/requests.log")" = "$heads" ]
    check "... nothing is sent, and the helper ends (--disable-retry; exit status $status) rather than wait" $?
}
long=$(printf '%5000s' | tr ' ' x)
too_long password "FATAL: The login does not fit in the websocket request's headers" \
    "KISMET_CAP_USER=${USER_PASS%%:*}" "KISMET_CAP_PASSWORD=$long"
too_long key "FATAL: The API key does not fit in the websocket request's headers" "KISMET_CAP_APIKEY=$long"

# A CA, and a certificate for localhost and 127.0.0.1 that it signed, for the TLS cases: what a TLS
# reverse proxy in front of Kismet with a private CA would have
TLS=
if command -v openssl > /dev/null 2>&1; then
    mkdir -p "$WORK/tls"
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$WORK/tls/ext.cnf"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=kismet_e2e test CA" \
            -keyout "$WORK/tls/ca.key" -out "$WORK/tls/ca.crt" > "$WORK/tls/openssl.log" 2>&1 &&
        openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout "$WORK/tls/server.key" \
            -out "$WORK/tls/server.csr" >> "$WORK/tls/openssl.log" 2>&1 &&
        openssl x509 -req -in "$WORK/tls/server.csr" -CA "$WORK/tls/ca.crt" -CAkey "$WORK/tls/ca.key" \
            -CAcreateserial -days 2 -extfile "$WORK/tls/ext.cnf" -out "$WORK/tls/server.crt" \
            >> "$WORK/tls/openssl.log" 2>&1 &&
        TLS=1
fi

echo "== remote capture answered with a redirect: not followed, and where it points not connected to"
# A server that answers the websocket with the status and Location in $WORK/redirect.answer, plain
# and (with a certificate) over TLS, and two listeners where the redirects point, which log every
# connection and every byte it is sent: another host, 127.0.0.2, and another port of 127.0.0.1.
# libwebsockets follows a redirect with the same headers: before add-to-kismet.sh's fix the other
# host got the login. As the fix first was, libwebsockets still connected there, and over TLS made
# the handshake, and only the request was refused; and a redirect from ws:// to https:// failed
# with "SSL_new failed", and nothing that said why.
python3 -c '
import socket, ssl, sys, threading
log, portfile, answer = sys.argv[1], sys.argv[2], sys.argv[3]
lock = threading.Lock()
def note(text):
    with lock:
        with open(log, "ab") as f:
            f.write(text)
def listen(host):
    s = socket.socket()
    s.bind((host, 0))
    s.listen(8)
    return s
def sent(c, where):  # all a listener where a redirect points is sent, until it closes or 3 s pass
    data = b""
    c.settimeout(3)
    try:
        while True:
            more = c.recv(65536)
            if not more:
                break
            data += more
    except OSError:
        pass
    note(b"== a connection to %s, %d bytes\n" % (where, len(data)) + data + b"\n")
    c.close()
def redirect(c, tls):  # {uri} in the Location is the URI of the request, query and all
    try:
        if tls:
            c = tls.wrap_socket(c, server_side=True)
        head = b""
        while b"\r\n\r\n" not in head:
            more = c.recv(65536)
            if not more:
                break
            head += more
        request = head.split(b"\r\n")[0]
        status, location = open(answer, "rb").read().split(b"\n")[:2]
        location = location.replace(b"{uri}", (request.split(b" ") + [b"", b""])[1])
        note(b"== a request to the redirecting server%s: %s\n" % (b" (TLS)" if tls else b"", request))
        c.sendall(b"HTTP/1.1 %s\r\n%sContent-Length: 0\r\n\r\n"
                  % (status, b"Location: %s\r\n" % location if location else b""))
    except OSError as e:
        note(b"== the redirecting server: %s\n" % repr(e).encode())
    c.close()
def accept(server, handle, *args):
    while True:
        threading.Thread(target=handle, args=(server.accept()[0],) + args, daemon=True).start()
tls = None
if len(sys.argv) > 5:
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(sys.argv[4], sys.argv[5])
plain, secure = listen("127.0.0.1"), listen("127.0.0.1")
other_host, other_port = listen("127.0.0.2"), listen("127.0.0.1")
threading.Thread(target=accept, args=(other_host, sent, b"the other host"), daemon=True).start()
threading.Thread(target=accept, args=(other_port, sent, b"another port"), daemon=True).start()
threading.Thread(target=accept, args=(secure, redirect, tls), daemon=True).start()
open(portfile, "w").write("%d %d %d %d\n" % tuple(s.getsockname()[1] for s in (plain, secure, other_host, other_port)))
accept(plain, redirect, None)
' "$WORK/redirected.log" "$WORK/redirect.ports" "$WORK/redirect.answer" \
    ${TLS:+"$WORK/tls/server.crt" "$WORK/tls/server.key"} > "$WORK/redirect-server.log" 2>&1 &
XPID=$!
for i in $(seq 1 50); do [ -s "$WORK/redirect.ports" ] && break; sleep 0.1; done
read -r REDIRECT REDIRECT_TLS OTHER_HOST OTHER_PORT < "$WORK/redirect.ports"

# redirect_case ID NAME STATUS LOCATION HELPER-OPTION...   (LOCATION "" for none). The helper must say
# the redirect points to SHOWN when that is set, else to LOCATION; its login is LOGIN_USER and
# LOGIN_PASSWORD when they are set, else the web login.
redirect_case() {
    id=$1 name=$2 status=$3 location=$4
    shift 4
    shown=${SHOWN-$location}
    printf '%s\n%s\n' "$status" "$location" > "$WORK/redirect.answer"
    : > "$WORK/redirected.log"
    # cat -v: what a server could send a terminal is shown, not sent to this one
    echo "   $name: HTTP/1.1 $status${location:+, Location: $location}" | cat -v
    timeout 20 env "KISMET_CAP_USER=${LOGIN_USER:-${USER_PASS%%:*}}" \
        "KISMET_CAP_PASSWORD=${LOGIN_PASSWORD:-${USER_PASS#*:}}" "$HELPER" "$@" \
        --disable-retry --source "esp32c5-$TTY:name=fake-redirect" > "$WORK/helper-redirect-$id.log" 2>&1
    rc=$?
    sleep 1
    grep "FATAL\|\] E: " "$WORK/helper-redirect-$id.log" | cat -v | sed 's/^/   helper: /'
    sed -n 's/^== /   /p' "$WORK/redirected.log"
    grep -qxF "FATAL: The websocket was answered with a redirect (HTTP ${status%% *}${shown:+ to $shown}), which is not followed: Kismet never redirects it, and the login would go along to wherever it points; check --connect, --endpoint and --ssl" \
        "$WORK/helper-redirect-$id.log"
    check "$name: not followed, and the helper says so, with the status and where it points" $?
    [ "$(grep -c "^== a request to the redirecting server" "$WORK/redirected.log")" = 1 ] &&
        ! grep -q "^== a connection to " "$WORK/redirected.log"
    check "$name: nothing connects to where it points, the login least of all, and no second request is made" $?
    [ "$rc" -ne 124 ]; check "$name: the helper ends (--disable-retry; exit status $rc) rather than wait" $?
}
redirect_case host "to another host" "302 Found" "http://127.0.0.2:$OTHER_HOST/elsewhere" \
    --connect "127.0.0.1:$REDIRECT"
redirect_case port "to another port" "307 Temporary Redirect" "http://127.0.0.1:$OTHER_PORT/elsewhere" \
    --connect "127.0.0.1:$REDIRECT"
redirect_case https "to https://" "302 Found" "https://127.0.0.2:$OTHER_HOST/elsewhere" \
    --connect "127.0.0.1:$REDIRECT"
redirect_case path "to a path on the same server" "301 Moved Permanently" "/elsewhere" \
    --connect "127.0.0.1:$REDIRECT"
redirect_case none "with no Location" "300 Multiple Choices" "" --connect "127.0.0.1:$REDIRECT"
# A server that sends every request elsewhere (nginx: return 301 https://$host$request_uri) gives the
# request's own query back in the Location, and a user name with ':' puts the login in that query:
# the helper says where the redirect points only up to its query
SHOWN="https://127.0.0.2:$OTHER_HOST/datasource/remote/remotesource.ws?..."
LOGIN_USER=e2e:colon LOGIN_PASSWORD=e2e-redirect-pass
redirect_case query "echoing the request's query, which holds the login" "301 Moved Permanently" \
    "https://127.0.0.2:$OTHER_HOST{uri}" --connect "127.0.0.1:$REDIRECT"
grep -q "^== a request to the redirecting server: GET [^ ]*&password=e2e-redirect-pass " "$WORK/redirected.log" &&
    ! grep -qF "e2e-redirect-pass" "$WORK/helper-redirect-query.log"
check "echoing the request's query: the Location held the password, and the helper does not print it" $?
unset LOGIN_USER LOGIN_PASSWORD
# Control bytes, which a terminal could take for part of a control sequence: ESC [2J (clear the
# screen), and U+009B (CSI) in UTF-8, which some terminals take as ESC [, and a space
SHOWN="http://127.0.0.2:$OTHER_HOST/%1B[2J%C2%9Bx%20y"
redirect_case control "with control bytes in the Location" "302 Found" \
    "http://127.0.0.2:$OTHER_HOST/$(printf '\033[2J\302\233x y')" --connect "127.0.0.1:$REDIRECT"
! LC_ALL=C grep -q "$(printf '[\033\233]')" "$WORK/helper-redirect-control.log"
check "with control bytes in the Location: the helper writes none of them, percent-encoded instead" $?
unset SHOWN
if [ -n "$TLS" ]; then
    # 127.0.0.1, which the certificate names too: lws checks it against the Host header's value up to
    # its ':', which leaves the address
    redirect_case tls "over TLS, to https:// on another host" "308 Permanent Redirect" \
        "https://127.0.0.2:$OTHER_HOST/elsewhere" \
        --connect "127.0.0.1:$REDIRECT_TLS" --ssl --ssl-certificate "$WORK/tls/ca.crt"
else
    echo "   SKIP: a redirect over TLS (no openssl to make a certificate with)"
fi
kill "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null; XPID=

echo "== remote capture over TLS, with --ssl-certificate and no --ssl"
if [ -z "$TLS" ]; then
    echo "   SKIP: no openssl to make a certificate with"
else
    # A TLS relay in front of Kismet, as a TLS reverse proxy with a private CA would be. The
    # framework takes --ssl-certificate as the CA to check the server with, but speaks TLS only with
    # --ssl: it spoke plain ws:// to the TLS port and said no more than "Datasource could not connect
    # websocket client". kismet_cap_esp32c5 adds --ssl for a certificate now.
    relay "$WORK/requests-tls.log" "$WORK/tls-relay.port" "$WORK/tls/server.crt" "$WORK/tls/server.key"
    TPID=$RELAY_PID
    TLS_RELAY=$(cat "$WORK/tls-relay.port")
    echo "   $HELPER --connect localhost:$TLS_RELAY --ssl-certificate ca.crt --source esp32c5-$TTY:name=fake-tls,..."
    (KISMET_CAP_USER=${USER_PASS%%:*} KISMET_CAP_PASSWORD=${USER_PASS#*:} exec "$HELPER" \
        --connect "localhost:$TLS_RELAY" --ssl-certificate "$WORK/tls/ca.crt" \
        --source "esp32c5-$TTY:name=fake-tls,uuid=E2E0E2E0-0000-0000-0000-00000000000B") \
        > "$WORK/helper-tls.log" 2>&1 &
    HPID=$!
    for i in $(seq 1 50); do
        [ "$(src fake-tls kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null && break
        sleep 0.2
    done
    [ "$(src fake-tls kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null
    check "the helper speaks TLS, checks the relay's certificate against that CA, and captures" $?
    sed -n '1,/^== connection 2/p' "$WORK/requests-tls.log" > "$WORK/request-tls-1.txt"
    grep "^== \|^GET \|^Host: \|^Origin: " "$WORK/request-tls-1.txt" | sed 's/^/   /'
    grep -q "^== connection 1 (TLS, server name 'localhost')$" "$WORK/request-tls-1.txt"
    check "TLS's server name is the bare host, localhost" $?
    # Origin's scheme is libwebsockets' own choice: https:// over TLS from 4.3 on, http:// before
    grep -qx "Host: localhost:$TLS_RELAY" "$WORK/request-tls-1.txt" &&
        grep -qxE "Origin: https?://localhost:$TLS_RELAY" "$WORK/request-tls-1.txt"
    check "the Host and Origin headers name the port, which is not wss://'s 443" $?
    [ "$(basic_login "$WORK/request-tls-1.txt")" = "$USER_PASS" ]
    check "the login goes in the Basic header over TLS as well" $?
    CPID=$(children_of "$HPID")
    kill -TERM "$HPID"
    sleep 1
    for p in $HPID $CPID; do alive "$p" && kill "$p"; done
    wait "$HPID" 2>/dev/null
    HPID= CPID=
    kill "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null; TPID=
fi

echo "== libwebsockets' queue, on a machine with many routes"
# libwebsockets reports each of the machine's routes to its own listeners as a connection starts,
# and its queue used to drop those past 40, with a warning each, on every connection. Not every
# machine has that many, so a helper connects in a network namespace of its own that has 200, to a
# server there that takes the connection and never answers, and is stopped after 3 s.
cat > "$WORK/routes.sh" <<'EOF'
# in the namespace: HELPER SOURCE LOG
ip link set lo up || exit 2
i=0
while [ $i -lt 200 ]; do echo "route add 10.$i.0.0/16 dev lo"; i=$((i + 1)); done | ip -batch - || exit 2
echo "   routes in the namespace: $(ip route show table all | wc -l) IPv4, $(ip -6 route show table all | wc -l) IPv6"
python3 -c 'import socket, time; s = socket.socket(); s.bind(("127.0.0.1", 2501)); s.listen(8); time.sleep(10)' &
sleep 0.5
KISMET_CAP_APIKEY=0123456789abcdef0123456789abcdef timeout 3 "$1" --connect 127.0.0.1:2501 --disable-retry \
    --source "$2" > "$3" 2>&1
echo "   the helper's exit status: $? (124: still waiting for an answer when it was stopped)"
kill $!
exit 0
EOF
if [ "$(id -u)" = 0 ]; then ns="unshare -n"; else ns="unshare -rn"; fi
if $ns sh "$WORK/routes.sh" "$HELPER" "esp32c5-$TTY:name=fake-routes" "$WORK/helper-routes.log" \
        > "$WORK/routes.out" 2>&1; then
    cat "$WORK/routes.out"
    n=$(grep -c "rejecting message on queue depth" "$WORK/helper-routes.log")
    echo "   'rejecting message on queue depth' said $n time(s)"
    grep -q "status: 124 " "$WORK/routes.out" && [ "$n" -eq 0 ]
    check "a helper connecting there prints no libwebsockets \"rejecting message on queue depth\" warnings" $?
else
    echo "   SKIP: no network namespace of its own here ($ns: $(head -1 "$WORK/routes.out"))"
fi
finish_case remote
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; RPID=
report remote
sed 's/^/   helper: /' "$WORK/helper-remote.log"

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
