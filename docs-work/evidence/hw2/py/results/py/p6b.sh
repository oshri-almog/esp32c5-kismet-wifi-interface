#!/bin/bash
# p6: where the Python helper takes its Kismet login from (check 7 and ids 57...), with --debug
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
unset KISMET_CAP_USER KISMET_CAP_PASSWORD KISMET_CAP_APIKEY
./k.sh start p6b || exit 1
KEY=$(python3 - <<'PY'
import sys; sys.path.insert(0, "."); import kq
code, body = kq.req("/auth/apikey/generate.cmd", {"name": "py-ds", "role": "datasource", "duration": 0})
print(body.strip() if isinstance(body, str) else "")
PY
)
ADMKEY=$(python3 - <<'PY'
import sys; sys.path.insert(0, "."); import kq
code, body = kq.req("/auth/apikey/generate.cmd", {"name": "py-admin", "role": "admin", "duration": 0})
print(body.strip() if isinstance(body, str) else "")
PY
)
echo "datasource key: ${KEY:0:6}... (${#KEY} chars); admin key ${#ADMKEY} chars"
python3 kq.py get /auth/apikey/list.json | cut -c1-400
run() {  # run NAME "env assignments" args...
  local name=$1 envs=$2; shift 2
  echo "=== $name: env [$envs] args [$*]"
  env -u KISMET_CAP_USER -u KISMET_CAP_PASSWORD -u KISMET_CAP_APIKEY $envs ./pyh.sh $D/p6b.$name.py.log --debug "$@" &
  local P=$(pidof_log $D/p6b.$name.py.log)
  for i in $(seq 1 40); do grep -qi "capturing\|PY_EXIT\|refused\|error" $D/p6b.$name.py.log 2>/dev/null && break; sleep 0.2; done
  sleep 1
  if kill -0 $P 2>/dev/null; then
    echo "  cmdline: $(tr '\0' ' ' < /proc/$P/cmdline | sed 's/--source.*//')"
    echo "  environ has: $(tr '\0' '\n' < /proc/$P/environ | grep -o '^KISMET_CAP_[A-Z]*' | tr '\n' ' ')"
    kill -TERM $P; for i in $(seq 1 40); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
  fi
  sleep 0.5
  grep -v "DEBUG: [<-]" $D/p6b.$name.py.log | grep -v "^\S* *$" | sed 's/^[0-9.]* //' | grep -iv "usage:\|^ *\[" | cut -c1-260
}
A="--connect 127.0.0.1:2501 --source esp32c5-ttyACM0"
run envkey "KISMET_CAP_APIKEY=$KEY" $A
run adminkey "" --apikey $ADMKEY $A
run tcp_args "" --connect 127.0.0.1:3501 --tcp --user admin --password py-Pass-77 --source esp32c5-ttyACM0
echo "### listening sockets"; ss -ltn | grep -E "2501|3501"
./k.sh stop
grep -i "login\|auth\|apikey\|refus\|401\|remote source" p6b.log | grep -v Detected | cut -c1-220 | head -30
