#!/bin/bash
# p20: the Windows-Boards guide's curl lines with Python remote sources on the Pi; which key roles the websocket
# takes; Wi-Fi device frequency units.
D=~/e2e/py; cd $D
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
./k.sh start p20 > /dev/null || exit 1
echo "### generate.cmd, as the guide writes it"
curl -u admin:py-Pass-77 --data-urlencode 'json={"name": "windows-laptop", "role": "datasource", "duration": 0}' http://localhost:2501/auth/apikey/generate.cmd > /tmp/py/key.txt; echo " (exit=$?)"
KEY=$(cat /tmp/py/key.txt); echo "key: ${#KEY} chars, hex: $(echo $KEY | grep -cE '^[0-9A-F]{32}$')"
echo "same name again: $(curl -s -u admin:py-Pass-77 --data-urlencode 'json={"name": "windows-laptop", "role": "datasource", "duration": 0}' -w ' HTTP %{http_code}' http://localhost:2501/auth/apikey/generate.cmd)"
KISMET_CAP_APIKEY=$KEY ./pyh.sh $D/p20.py.log --connect 127.0.0.1:2501 --source esp32c5-ttyACM0:name=win-wifi --source esp32c5btle-ttyACM3:name=win-ble &
P=$(pidof_log $D/p20.py.log)
python3 kq.py waitrun win-wifi 20 > /dev/null; python3 kq.py waitrun win-ble 20 > /dev/null; sleep 10
echo "### the guide's all_sources one-liner"
curl -s -u admin:py-Pass-77 http://localhost:2501/datasource/all_sources.json \
  | python3 -c 'import json,sys; [print(s["kismet.datasource.name"], "remote" if s["kismet.datasource.remote"] else "local", "running" if s["kismet.datasource.running"] else "stopped", s["kismet.datasource.num_packets"]) for s in json.load(sys.stdin)]'
echo "### device frequencies (kHz?) by phy"
python3 - <<'PY'
import sys, collections; sys.path.insert(0, "."); import kq
c = collections.defaultdict(collections.Counter)
for d in kq.devices():
    c[d.get("phyname")][d.get("frequency")] += 1
for p, v in c.items(): print(p, dict(v.most_common(6)))
PY
echo "### key roles on the websocket"
for role in readonly admin logon scanreport; do
  K=$(curl -s -u admin:py-Pass-77 --data-urlencode "json={\"name\": \"r-$role\", \"role\": \"$role\", \"duration\": 0}" http://localhost:2501/auth/apikey/generate.cmd)
  timeout 6 ~/esp32c5-venv/bin/python -c "
import websocket, sys
try:
    ws = websocket.create_connection('ws://127.0.0.1:2501/datasource/remote/remotesource.ws?KISMET=$K', timeout=5, header=['Sec-WebSocket-Protocol: kismet-remote']); print('$role key: websocket accepted'); ws.close()
except Exception as e: print('$role key:', str(e)[:60])"
done
kill -TERM $P; sleep 2
./k.sh stop > /dev/null
rm -f /tmp/py/key.txt
