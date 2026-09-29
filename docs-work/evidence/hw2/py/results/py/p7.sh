#!/bin/bash
# p7: the Python helper across Kismet restarts (SIGTERM, then SIGKILL mid-stream), with websocket-client 1.9.2
# (the venv), 1.8.0 and 1.7.0 (fresh venvs). Timings from Kismet up to 'connected' and 'capturing'; same UUID.
D=~/e2e/py; cd $D
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
for v in 1.8.0 1.7.0; do
  V=/tmp/py/venv-ws$v
  if [ ! -x $V/bin/python ]; then
    python3 -m venv $V && $V/bin/pip install -q pyserial==3.5 msgpack websocket-client==$v 2>&1 | tail -2
  fi
  echo "$V: $($V/bin/python -c 'import websocket, serial, msgpack; print("websocket-client", websocket.__version__, "pyserial", serial.__version__)')"
done
up() {  # wait for Kismet's HTTP port; print epoch
  for i in $(seq 1 300); do curl -s -o /dev/null http://127.0.0.1:2501/ && break; sleep 0.05; done; date +%s.%N; }
nsrc() { python3 kq.py src | awk '{print $1, $2, $3, $5, substr($0, index($0,"uuid="), 41)}' | tr '\n' ';'; }
for PYB in ~/esp32c5-venv/bin/python /tmp/py/venv-ws1.8.0/bin/python /tmp/py/venv-ws1.7.0/bin/python; do
  VER=$($PYB -c 'import websocket; print(websocket.__version__)')
  TAG=p7-$VER
  echo "########## websocket-client $VER"
  KEEPHOME=1 KHOME=/tmp/py/p7home ./k.sh start $TAG-a > /dev/null || exit 1
  PYBIN=$PYB ./pyh.sh $D/$TAG.py.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source esp32c5-ttyACM0 &
  P=$(pidof_log $D/$TAG.py.log)
  python3 kq.py waitrun esp32c5-ttyACM0 20 > /dev/null; sleep 3
  echo "before: $(nsrc)"
  if [ "$VER" = "1.9.2" ]; then
    echo "--- (a) SIGTERM Kismet at $(date +%s.%N), restart 10 s later"
    ./k.sh stop > /dev/null; sleep 10
    KEEPHOME=1 KHOME=/tmp/py/p7home ./k.sh start $TAG-b > /dev/null; T=$(up); echo "kismet up at $T"
    python3 kq.py waitrun esp32c5-ttyACM0 30 > /dev/null; sleep 1
    echo "after: $(nsrc)"
    grep "connected, offering\|capturing" $D/$TAG.py.log | tail -2 | awk -v t=$T '{printf "  %+.2f s after Kismet up: %s\n", $1-t, substr($0, index($0,"INFO"))}'
  fi
  echo "--- (b) SIGKILL Kismet mid-stream at $(date +%s.%N), restart 3 s later"
  ./k.sh kill9 > /dev/null; sleep 3
  echo "helper alive: $(kill -0 $P 2>/dev/null && echo yes || echo no)"
  KEEPHOME=1 KHOME=/tmp/py/p7home ./k.sh start $TAG-c > /dev/null; T=$(up); echo "kismet up at $T"
  python3 kq.py waitrun esp32c5-ttyACM0 30 > /dev/null; sleep 1
  echo "after: $(nsrc)"
  grep "connected, offering\|capturing" $D/$TAG.py.log | tail -2 | awk -v t=$T '{printf "  %+.2f s after Kismet up: %s\n", $1-t, substr($0, index($0,"INFO"))}'
  echo "--- (b2) SIGKILL again, restart at once"
  ./k.sh kill9 > /dev/null
  KEEPHOME=1 KHOME=/tmp/py/p7home ./k.sh start $TAG-d > /dev/null; T=$(up); echo "kismet up at $T"
  python3 kq.py waitrun esp32c5-ttyACM0 30 > /dev/null; sleep 1
  echo "after: $(nsrc)"
  grep "connected, offering\|capturing" $D/$TAG.py.log | tail -2 | awk -v t=$T '{printf "  %+.2f s after Kismet up: %s\n", $1-t, substr($0, index($0,"INFO"))}'
  kill -TERM $P; for i in $(seq 1 60); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
  ./k.sh stop > /dev/null
  echo "--- helper log"; sed 's/^[0-9.]* //' $D/$TAG.py.log | cut -c1-200
  echo "tracebacks: $(grep -c Traceback $D/$TAG.py.log)"
done
./locks.sh
pkill -TERM -f "esp32c5_kismet.remote"; sleep 1; ./k.sh stop >/dev/null
