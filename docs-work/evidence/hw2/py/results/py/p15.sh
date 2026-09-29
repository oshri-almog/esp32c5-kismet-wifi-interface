#!/bin/bash
# p15: passwords with '&', ' ' and '%41' (and a plain one) for the websocket login: Python helper (--password and
# KISMET_CAP_PASSWORD) and the C helper (KISMET_CAP_PASSWORD); an API key in the same setup.
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
k=0
for PW in 'plainPass1' 'ab&cd12' 'ab cd12' 'ab%41cd12'; do
  k=$((k+1)); echo "########## password [$PW]"
  H=/tmp/py/p15-$k; rm -rf $H; mkdir -p $H/.kismet
  printf 'httpd_username=admin\nhttpd_password=%s\n' "$PW" > $H/.kismet/kismet_httpd.conf
  KEEPHOME=1 KHOME=$H ./k.sh start p15-$k > /dev/null || exit 1
  echo "REST with basic auth: HTTP $(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW" http://127.0.0.1:2501/system/status.json)"
  export KQ_AUTH="admin:$PW"
  KEY=$(python3 -c "
import sys; sys.path.insert(0, '.'); import kq
code, body = kq.req('/auth/apikey/generate.cmd', {'name': 'p15', 'role': 'datasource', 'duration': 0}); print(body.strip() if code == 200 else 'none')")
  for mode in args env key; do
    case $mode in
      args) ./pyh.sh $D/p15-$k.$mode.py.log --connect 127.0.0.1:2501 --user admin --password "$PW" --source esp32c5-ttyACM0 & ;;
      env) KISMET_CAP_USER=admin KISMET_CAP_PASSWORD="$PW" ./pyh.sh $D/p15-$k.$mode.py.log --connect 127.0.0.1:2501 --source esp32c5-ttyACM0 & ;;
      key) ./pyh.sh $D/p15-$k.$mode.py.log --connect 127.0.0.1:2501 --apikey "$KEY" --source esp32c5-ttyACM0 & ;;
    esac
    P=$(pidof_log $D/p15-$k.$mode.py.log)
    for i in $(seq 1 50); do grep -qi "capturing$\|error" $D/p15-$k.$mode.py.log && break; sleep 0.2; done; sleep 0.5
    kill -TERM $P; for i in $(seq 1 50); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
    echo "  python $mode: $(grep -o 'capturing$\|ERROR: .*' $D/p15-$k.$mode.py.log | head -1 | cut -c1-160)"
  done
  KISMET_CAP_USER=admin KISMET_CAP_PASSWORD="$PW" timeout 10 $C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > p15-$k.c.log 2>&1 &
  sleep 8; echo "  C env: $(python3 kq.py src | grep ttyACM1 | awk '{print $1,$2,$3,$5}') | $(grep -v 'lws_\|__lws\|_lws' p15-$k.c.log | grep -i 'fatal\|error\|401\|refused' | head -2 | tr '\n' ' ' | cut -c1-200)"
  wait; pkill -KILL -f "kismet_cap_esp32c5 --connect" 2>/dev/null
  ./k.sh stop > /dev/null
  grep -i "login\|auth\|password" p15-$k.log | grep -v "Including\|Loading config\|WEP" | head -3 | cut -c1-200
done
unset KQ_AUTH
