#!/bin/bash
D=~/e2e/hw2; cd $D
./k.sh start n8t || exit 1
python3 - <<PY
import sys; sys.path.insert(0, "$D"); import kq, json
code, body = kq.req("/auth/apikey/generate.cmd", {"name": "hw2-ds", "role": "datasource", "duration": 0})
print("generate.cmd HTTP", code, "len", len(body) if isinstance(body, str) else body)
open("$D/apikey", "w").write(body.strip() if isinstance(body, str) else "")
code, body = kq.req("/auth/apikey/list.json")
print("list.json", code, json.dumps(body)[:400])
PY
U=E5C50001-0000-0000-0000-3844BEBFC910
for k in ws-env ws-key tcp py; do echo "##### $k"; python3 rtime.py $k 5 esp32c5-ttyACM1 n8t 12 $U; done
python3 kq.py src | cut -c1-200
./k.sh stop
