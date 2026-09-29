#!/bin/bash
# p14: --ssl / --ssl-certificate / --endpoint through a TLS proxy (Python helper, and the C helper for comparison)
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
T=/tmp/py/tls; rm -rf $T; mkdir -p $T
openssl req -x509 -newkey rsa:2048 -nodes -keyout $T/key.pem -out $T/cert.pem -days 1 -subj /CN=localhost \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null && echo "cert made"
./k.sh start p14 > /dev/null || exit 1
KEY=$(python3 -c "
import sys; sys.path.insert(0, '.'); import kq
code, body = kq.req('/auth/apikey/generate.cmd', {'name': 'tls', 'role': 'datasource', 'duration': 0}); print(body.strip())")
python3 -u tlsproxy.py 8443 $T/cert.pem $T/key.pem > p14.proxy.log 2>&1 &
PX=$!
python3 -u tlsproxy.py 8444 $T/cert.pem $T/key.pem /kismet > p14.proxy2.log 2>&1 &
PX2=$!
sleep 1
n=0
try() {  # try LABEL helper-args...
  n=$((n+1)); echo "=== $n: $1"; shift
  ./pyh.sh $D/p14.$n.py.log "$@" --source esp32c5-ttyACM0 &
  local P=$(pidof_log $D/p14.$n.py.log)
  for i in $(seq 1 60); do grep -qi "capturing$\|error\|PY_EXIT" $D/p14.$n.py.log && break; sleep 0.2; done; sleep 1
  kill -TERM $P 2>/dev/null; for i in $(seq 1 50); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
  grep -v "^\S* *$" $D/p14.$n.py.log | sed 's/^[0-9.]* //' | grep -v "usage:\|^  *\[" | head -6 | cut -c1-300
}
try "wss 127.0.0.1:8443 --ssl-certificate" --connect 127.0.0.1:8443 --ssl-certificate $T/cert.pem --apikey $KEY
try "wss localhost:8443 --ssl-certificate (dialled as 127.0.0.1)" --connect localhost:8443 --ssl-certificate $T/cert.pem --apikey $KEY
try "--ssl without the certificate (system CAs)" --connect 127.0.0.1:8443 --ssl --apikey $KEY
try "plain ws to the TLS port" --connect 127.0.0.1:8443 --apikey $KEY
try "--endpoint /kismet/... through the prefix proxy" --connect 127.0.0.1:8444 --ssl-certificate $T/cert.pem --endpoint /kismet/datasource/remote/remotesource.ws --apikey $KEY
try "prefix proxy without --endpoint" --connect 127.0.0.1:8444 --ssl-certificate $T/cert.pem --apikey $KEY
try "--ssl with --tcp" --connect 127.0.0.1:3501 --tcp --ssl
echo "=== C helper through the proxy"
for args in "--ssl --ssl-certificate $T/cert.pem" "--ssl --ssl-certificate $T/cert.pem --endpoint /kismet/datasource/remote/remotesource.ws"; do
  port=8443; echo "$args" | grep -q endpoint && port=8444
  echo "--- C: --connect 127.0.0.1:$port $args"
  KISMET_CAP_APIKEY=$KEY timeout 12 $C --connect 127.0.0.1:$port $args --source esp32c5-ttyACM1 > p14.c.log 2>&1 &
  sleep 9; python3 kq.py src | grep ttyACM1 | cut -c1-90; wait
  grep -v "lws_\|__lws\|_lws" p14.c.log | head -5 | cut -c1-200
  pkill -KILL -f "kismet_cap_esp32c5 --connect"; sleep 1
done
kill $PX $PX2
echo "### proxy logs"; cat p14.proxy.log p14.proxy2.log | cut -c1-150
./k.sh stop > /dev/null
rm -rf $T
