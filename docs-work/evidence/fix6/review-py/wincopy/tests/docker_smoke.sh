#!/bin/sh
# Smoke test for the Docker image, no hardware needed: the demo image's fake board feeds Kismet in
# each radio, then the "helper" role feeds a Kismet in a second container over remote capture.
# Also checked: kismet_cap_esp32c5 is in the image, and Kismet's list of interfaces (the web UI's
# Data Sources window) answers, which it never does when one of Kismet's own capture helpers crashes
# on start. Every container runs with Docker's default capabilities only.
#
#     docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
#     tests/docker_smoke.sh esp32c5-kismet:demo
#     PYTHON=python sh tests/docker_smoke.sh esp32c5-kismet:demo     (Windows, Git Bash)
#
# Needs docker, curl and a Python on the host (PYTHON, default python3), which only reads Kismet's
# JSON; with sudo where the user is not in the docker group. Uses host port 2599 and containers and
# a network named esp32c5-smoke*, and removes them after, with their volumes. SMOKE_PORT and
# SMOKE_NAME change those, to run beside another copy. Prints PASS or FAIL for each check and ALL OK
# at the end, and exits with 0 when every check passed, 1 otherwise. CI runs it on the demo image of
# each architecture (.github/workflows/docker.yml). More on the wiki page Development-and-Testing.

set -u

# Git Bash on Windows rewrites arguments that look like POSIX paths into Windows ones, so the
# helper's "device=/tmp/esp32c5-fake" would reach the container as "device=C:/Users/.../Temp/...".
# No argument here is a path on this machine, so that is switched off (no effect anywhere else).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

IMAGE=${1:-esp32c5-kismet:demo}
PYTHON=${PYTHON:-python3}  # on Windows Git Bash: PYTHON=python
PORT=${SMOKE_PORT:-2599}
NAME=${SMOKE_NAME:-esp32c5-smoke}
AUTH=smoke:smoke-password
NET=$NAME-net
# Every container gets Docker's default capabilities and no more (NET_ADMIN is not among them): a
# capture helper that needed another one would fail the demo and helper checks, and one of Kismet's
# own that kismet_site.conf does not mask would fail "interface list answers".
FAILED=0
WORK=$(mktemp -d)

cleanup() {
    # -v: the image declares /data and /root/.kismet as volumes, and every container would
    # otherwise leave two anonymous volumes behind
    docker rm -f -v "$NAME" "$NAME-version" "$NAME-server" "$NAME-helper" > /dev/null 2>&1
    docker network rm "$NET" > /dev/null 2>&1
}
trap 'cleanup; rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM
cleanup

check() {  # check NAME STATUS
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi
}

api() {  # api PATH [JSON-FIELDS]
    if [ $# -gt 1 ]; then
        curl -s -u "$AUTH" --data-urlencode "json=$2" "http://127.0.0.1:$PORT$1"
    else
        curl -s -u "$AUTH" "http://127.0.0.1:$PORT$1"
    fi
}

wait_up() {  # the REST API answers once Kismet is up
    i=0
    while [ $i -lt 60 ]; do
        api /system/status.json 2>/dev/null | grep -q kismet.system.timestamp && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# The JSON reaches Python on stdin, not in files: a Windows Python reads "/tmp/..." as C:\tmp\...
# It writes bytes, so the lines end in \n on Windows too.
SUMMARY=$(cat <<'EOF'
import json
import sys
sources, devices = (json.loads(part) for part in
                    sys.stdin.buffer.read().decode("utf-8", "replace").split("\n%%\n"))
ours = [s for s in sources
        if s.get("kismet.datasource.type_driver", {}).get("kismet.datasource.driver.type") == "esp32c5"]
running = sum(1 for s in ours if s.get("kismet.datasource.running") == 1)
packets = sum(s.get("kismet.datasource.num_packets", 0) for s in ours)
phys = sorted({d.get("kismet.device.base.phyname") or "" for d in devices})
names = sorted({d.get("kismet.device.base.commonname") or d.get("kismet.device.base.name") or "" for d in devices})
out = "running=%d packets=%d\nphys=%s\nnames=%s\n" % (
    running, packets, "|".join(phys), "|".join(n for n in names if n))
sys.stdout.buffer.write(out.encode("utf-8", "replace"))
EOF
)

# Everything Kismet reports about the esp32c5 sources and the devices, reduced to what is checked
summary() {
    {
        api /datasource/all_sources.json
        printf '\n%%%%\n'
        api /devices/views/all/devices.json \
            '{"fields": ["kismet.device.base.phyname", "kismet.device.base.commonname", "kismet.device.base.name"]}'
    } | "$PYTHON" -c "$SUMMARY"
}

demo() {  # demo MODE SECONDS
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:2501" \
        -e KISMET_USER="${AUTH%%:*}" -e KISMET_PASSWORD="${AUTH#*:}" -e ESP32C5_DEMO="$1" \
        "$IMAGE" kismet --no-logging > /dev/null
    wait_up
    check "$1: Kismet answers" $?
    # What the web UI's Data Sources window shows. Kismet asks every capture helper it has and
    # waits for them all, so one that crashes on start, as Kismet's own do without NET_ADMIN unless
    # kismet_site.conf masks them, keeps the answer from ever coming. The answer is a JSON list,
    # "[]" with no board plugged in (the fake board is not a USB port).
    curl -s -m 10 -u "$AUTH" "http://127.0.0.1:$PORT/datasource/list_interfaces.json" | grep -q '^\['
    check "$1: interface list answers" $?
    sleep "$2"
    summary > "$WORK/$1.txt"
    sed 's/^/   /' "$WORK/$1.txt"
    grep -q "^running=1 " "$WORK/$1.txt"
    check "$1: esp32c5 source running" $?
    # a positive count, so that a summary that failed altogether does not pass
    grep -q " packets=[1-9]" "$WORK/$1.txt"
    check "$1: packets received" $?
}

finish_demo() {
    [ "$FAILED" -ne 0 ] && docker logs "$NAME" 2>&1 | tail -30
    docker rm -f -v "$NAME" > /dev/null 2>&1
}

echo "== image $IMAGE"
# --version: the capture helpers exit with 255 after --help
docker run --rm --name "$NAME-version" --entrypoint kismet_cap_esp32c5 "$IMAGE" --version > /dev/null 2>&1
check "kismet_cap_esp32c5 is in the image" $?

echo "== Wi-Fi demo (Kismet hops the fake board over both bands)"
demo wifi 35
grep -q "phys=.*IEEE802.11" "$WORK/wifi.txt"; check "wifi: decoded as 802.11" $?
grep -q "ESP32C5-FAKE-24" "$WORK/wifi.txt"; check "wifi: 2.4 GHz access point" $?
grep -q "ESP32C5-FAKE-5LOW" "$WORK/wifi.txt" && grep -q "ESP32C5-FAKE-5HIGH" "$WORK/wifi.txt"
check "wifi: 5 GHz access points" $?
finish_demo

echo "== 802.15.4 demo"
demo zigbee 25
grep -q "phys=.*802.15.4" "$WORK/zigbee.txt"; check "zigbee: decoded as 802.15.4" $?
finish_demo

echo "== BTLE demo"
demo btle 20
grep -q "phys=.*BTLE" "$WORK/btle.txt"; check "btle: decoded as BTLE" $?
grep -q "ESP32C5-FAKE" "$WORK/btle.txt"; check "btle: advertiser name" $?
finish_demo

echo "== helper role: a board in one container feeds Kismet in another"
docker network create "$NET" > /dev/null
# No board to wait for (ESP32C5_WAIT=0): the default 30 s would come out of wait_up's minute
docker run -d --name "$NAME-server" --network "$NET" -p "127.0.0.1:$PORT:2501" \
    -e KISMET_USER="${AUTH%%:*}" -e KISMET_PASSWORD="${AUTH#*:}" -e ESP32C5_DEMO= -e ESP32C5_WAIT=0 \
    "$IMAGE" kismet --no-logging > /dev/null
wait_up
check "helper: Kismet server answers" $?
docker run -d --name "$NAME-helper" --network "$NET" \
    -e KISMET_SERVER="$NAME-server:2501" \
    -e KISMET_USER="${AUTH%%:*}" -e KISMET_PASSWORD="${AUTH#*:}" \
    -e KISMET_SOURCES="esp32c5:device=/tmp/esp32c5-fake,mode=wifi,name=remote" \
    --entrypoint sh "$IMAGE" -c \
    'python3 /opt/esp32c5/fake_board.py /tmp/esp32c5-fake WIFI > /tmp/fake.log 2>&1 & sleep 1; exec esp32c5-kismet helper' \
    > /dev/null
sleep 35
summary > "$WORK/helper.txt"
sed 's/^/   /' "$WORK/helper.txt"
grep -q "^running=1 " "$WORK/helper.txt"; check "helper: remote source running" $?
grep -q "ESP32C5-FAKE-24" "$WORK/helper.txt"; check "helper: access point seen through remote capture" $?
if [ "$FAILED" -ne 0 ]; then
    echo "--- server"; docker logs "$NAME-server" 2>&1 | tail -20
    echo "--- helper"; docker logs "$NAME-helper" 2>&1 | tail -20
fi

[ "$FAILED" -eq 0 ] && echo "ALL OK"
exit "$FAILED"
