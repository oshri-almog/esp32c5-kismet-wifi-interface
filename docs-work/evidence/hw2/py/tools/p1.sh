#!/bin/bash
# p1: --list of both helpers, idle; with ttyACM0 held by a C local source; with ttyACM1 also held by the Python helper
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
PY=~/esp32c5-venv/bin/python
pylist() { (cd $D/src; $PY -m esp32c5_kismet.remote --list; echo "exit=$?"); }
clist() { $C --list > /tmp/py/cl.out 2> /tmp/py/cl.err; e=$?; echo "[stdout: $(wc -c < /tmp/py/cl.out) bytes]"; cat /tmp/py/cl.out; echo "[stderr:]"; cat /tmp/py/cl.err; echo "exit=$e"; }
echo "### version"; $C --version; echo "exit=$?"
echo "### idle: C --list"; clist
echo "### idle: Python --list"; pylist
echo "### Python --help (head)"; (cd $D/src; $PY -m esp32c5_kismet.remote --help | head -5; echo "exit=${PIPESTATUS[0]}")
./k.sh start p1 -c esp32c5-ttyACM0 || exit 1
python3 kq.py waitrun esp32c5-ttyACM0 20
echo "### locks with C local on ttyACM0"; ./locks.sh
echo "### C --list, ttyACM0 held by C local"; clist
echo "### Python --list, ttyACM0 held by C local"; pylist
./pyh.sh $D/p1.py1.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source esp32c5-ttyACM1 &
python3 kq.py waitrun esp32c5-ttyACM1 20
echo "### locks with C local on ttyACM0 and Python on ttyACM1"; ./locks.sh
echo "### C --list, ttyACM0 C local, ttyACM1 Python"; clist
echo "### Python --list, same"; pylist
python3 kq.py src | cut -c1-260
kill -TERM $(cat $D/p1.py1.log.pid); sleep 2
./k.sh stop
echo "### python log"; cat p1.py1.log
echo "### locks at end"; ./locks.sh
