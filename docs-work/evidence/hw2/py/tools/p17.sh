#!/bin/bash
# p17: the helper under Python 3.9-3.12 (uv-managed interpreters, no sudo): requirements install, both test files,
# a 12 s real-board capture. 3.9 also with websocket-client 1.8.0, since 1.9.1+ needs 3.10.
D=~/e2e/py; S=$D/src; cd $D
U=/tmp/py/uvenv; export UV_PYTHON_INSTALL_DIR=/tmp/py/uvpy UV_CACHE_DIR=/tmp/py/uvcache
[ -x $U/bin/uv ] || { python3 -m venv $U && $U/bin/pip install -q uv; }
UV=$U/bin/uv; echo "$($UV --version)"
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
./k.sh start p17 > /dev/null || exit 1
for v in 3.9 3.10 3.11 3.12; do
  echo "########## Python $v"
  V=/tmp/py/v$v; rm -rf $V
  $UV python install -q $v 2>&1 | tail -1
  $UV venv -q -p $v $V 2>&1 | tail -1
  echo "interpreter: $($V/bin/python --version 2>&1)"
  $UV pip install -q -p $V/bin/python -r $S/requirements.txt 2>&1 | tail -3; echo "requirements exit=${PIPESTATUS[0]}"
  if ! $V/bin/python -c 'import websocket' 2>/dev/null; then
    echo "(websocket-client from requirements not installed; trying 1.8.0)"
    $UV pip install -q -p $V/bin/python 'pyserial>=3.5' 'msgpack>=1.0' 'websocket-client==1.8.0' 2>&1 | tail -2
  fi
  $V/bin/python -c 'import serial, msgpack, websocket; print("pyserial", serial.__version__, "msgpack", msgpack.version, "websocket-client", websocket.__version__)' 2>&1 | tail -1
  (cd $S; $V/bin/python tests/test_board.py 2>&1 | tail -1 | cut -c1-120; $V/bin/python tests/test_kismet_v3.py 2>&1 | tail -1 | cut -c1-120)
  PYBIN=$V/bin/python ./pyh.sh $D/p17.$v.py.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source esp32c5-ttyACM0 &
  P=$(pidof_log $D/p17.$v.py.log)
  for i in $(seq 1 60); do grep -q "capturing$\|PY_EXIT\|Error\|error" $D/p17.$v.py.log && break; sleep 0.2; done; sleep 10
  echo "capture: $(python3 kq.py src | grep ttyACM0 | awk '{print $1,$2,$3,$5}')"
  kill -TERM $P 2>/dev/null; for i in $(seq 1 50); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
  grep -v "INFO" $D/p17.$v.py.log | sed 's/^[0-9.]* //' | head -5 | cut -c1-200
done
./k.sh stop > /dev/null
rm -rf /tmp/py/v3.* /tmp/py/uvpy /tmp/py/uvcache $U
