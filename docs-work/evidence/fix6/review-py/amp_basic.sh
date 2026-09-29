#!/bin/sh
# Kismet with a password holding '&': the query login (what the helper sends) vs HTTP Basic auth on the
# same websocket upgrade. Ports 2731/3731; only the Kismet started here is stopped, by pid.
set -u
W=/tmp/rvpy/amp
rm -rf "$W"; mkdir -p "$W/home/.kismet"
printf 'httpd_username=amp\nhttpd_password=pa&ss\n' > "$W/home/.kismet/kismet_httpd.conf"
printf 'httpd_port=2731\nremote_capture_listen=127.0.0.1\nremote_capture_port=3731\n' > "$W/override.conf"
(cd "$W" && exec /root/kismet-install/bin/kismet --homedir "$W/home" --no-ncurses --no-logging --override "$W/override.conf") > "$W/kismet.log" 2>&1 &
KPID=$!
for i in $(seq 1 120); do curl -sf -o /dev/null -u 'amp:pa&ss' http://127.0.0.1:2731/system/status.json && break; sleep 0.5; done
echo "REST with curl -u 'amp:pa&ss' (Basic): HTTP $(curl -s -o /dev/null -w '%{http_code}' -u 'amp:pa&ss' http://127.0.0.1:2731/system/status.json)"
cd /tmp/rvpy/base
/root/esp32c5-venv/bin/python - <<'PY'
import base64, time, websocket
from urllib.parse import quote
from esp32c5_kismet import kismet_v3 as kv3
base = "ws://127.0.0.1:2731/datasource/remote/remotesource.ws"
proto = "Sec-WebSocket-Protocol: kismet-remote"
url = "%s?user=%s&password=%s" % (base, quote("amp", safe=""), quote("pa&ss", safe=""))
try:
    websocket.create_connection(url, timeout=10, header=[proto]).close()
    print("query login (the helper's way, %s): connected" % url.split("?")[1])
except Exception as e:
    print("query login (the helper's way, %s): %s" % (url.split("?")[1], e))
auth = "Authorization: Basic " + base64.b64encode(b"amp:pa&ss").decode()
ws = websocket.create_connection(base, timeout=10, header=[proto, auth])
print("Basic auth header, same user and password: connected, status %s" % ws.getstatus())
ws.send_binary(kv3.newsource(2, "esp32c5:device=/dev/null-amp,name=amp-basic", "esp32c5", "E5C50001-0000-0000-0000-00000000A4A5"))
end = time.time() + 10
while time.time() < end:
    op, data = ws.recv_data()
    fr = kv3.decode(data)
    print("   <- %s" % kv3.PACKET_NAMES.get(fr.pkt_type, fr.pkt_type))
    if fr.pkt_type in (kv3.KDS_OPENREQ, kv3.KDS_PROBEREQ):
        break
ws.close()
PY
cd /tmp/rvpy/base && timeout 12 /root/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2731 --user amp --password 'pa&ss' --source 'esp32c5:device=/tmp/rvpy/amp/nothere,uuid=E5C50001-0000-0000-0000-00000000A4A6' 2>&1 | head -6
kill -TERM "$KPID"; wait "$KPID" 2>/dev/null
grep -i "amp-basic\|esp32c5" "$W/kismet.log" | head -5
