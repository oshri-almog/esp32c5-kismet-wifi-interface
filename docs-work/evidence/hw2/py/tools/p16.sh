#!/bin/bash
# p16: the offline test files on Linux, the two end-to-end scripts, the fake board with the Python helper in btle
# mode; the Remote-Capture install lines verbatim in a fresh folder (python3-venv is installed already, no sudo);
# python3-serial from apt for "from esp32c5_kismet import board".
D=~/e2e/py; S=$D/src; cd $S
PY=~/esp32c5-venv/bin/python
echo "### test_board.py"; $PY tests/test_board.py > $D/p16.tb.out 2>&1; echo "exit=$?"; grep -i "skip\|ALL OK\|FAIL\|checks\|passed\|failed" $D/p16.tb.out | tail -8
echo "### test_kismet_v3.py (openssl: $(command -v openssl))"; $PY tests/test_kismet_v3.py > $D/p16.tk.out 2>&1; echo "exit=$?"; grep -i "skip\|ALL OK\|FAIL\|checks\|passed\|failed" $D/p16.tk.out | tail -8
grep -i "wss\|tls\|certificate" $D/p16.tk.out | head -5
echo "### the same without openssl on the PATH"
mkdir -p /tmp/py/noossl; for b in /usr/bin/*; do n=$(basename $b); [ "$n" = openssl ] || ln -sf $b /tmp/py/noossl/$n; done
PATH=/tmp/py/noossl $PY tests/test_kismet_v3.py > $D/p16.tk2.out 2>&1; echo "exit=$?"; grep -i "skip\|ALL OK\|FAIL" $D/p16.tk2.out | tail -4
rm -rf /tmp/py/noossl
echo "### remote_e2e.sh"; KISMET=~/kismet-install/bin/kismet PYTHON=$PY sh tests/remote_e2e.sh > $D/p16.re.out 2>&1; echo "exit=$?"; tail -4 $D/p16.re.out; grep -c "^ok\|OK" $D/p16.re.out
echo "### kismet_e2e.sh"; KISMET=~/kismet-install/bin/kismet sh tests/kismet_e2e.sh > $D/p16.ke.out 2>&1; echo "exit=$?"; tail -3 $D/p16.ke.out
echo "### fake board, Python helper in btle mode"
cd $D; ./k.sh start p16 > /dev/null || exit 1
python3 -u $S/tools/fake_board.py /tmp/py/fake > $D/p16.fake.log 2>&1 &
FK=$!; sleep 1
./pyh.sh $D/p16.fake.py.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source esp32c5btle:device=/tmp/py/fake &
sleep 1; P=$(cat $D/p16.fake.py.log.pid)
python3 kq.py waitrun esp32c5btle 20; sleep 5
python3 kq.py src | cut -c1-200; python3 kq.py devs | head -1
kill -TERM $P; sleep 2; kill $FK
./k.sh stop > /dev/null
echo "--- fake board log"; cat p16.fake.log | cut -c1-200 | head -20
echo "--- helper log"; sed 's/^[0-9.]* //' p16.fake.py.log | cut -c1-200
echo "### Remote-Capture install lines, verbatim, in a fresh copy of the project folder"
R=/tmp/py/inst; rm -rf $R; mkdir -p $R; cp -r $S/esp32c5_kismet $S/requirements.txt $R/; cd $R
echo "python3-venv: $(dpkg-query -W -f='${Status} ${Version}' python3-venv 2>&1)"
python3 -m venv .venv; echo "venv exit=$?"
.venv/bin/pip install -r requirements.txt 2>&1 | tail -2; echo "pip exit=${PIPESTATUS[0]}"
.venv/bin/python -c 'import sys, serial, msgpack, websocket; print(sys.version.split()[0], "pyserial", serial.__version__, "msgpack", msgpack.version, "websocket-client", websocket.__version__)'
.venv/bin/python -m esp32c5_kismet.remote --list | head -2
cd $D; ./k.sh start p16i > /dev/null
(cd $R; KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=py-Pass-77 exec .venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source esp32c5btle-ttyACM3) > p16.inst.py.log 2>&1 &
P=$!
python3 kq.py waitrun esp32c5btle-ttyACM3 20; sleep 28
python3 kq.py src | cut -c1-130; python3 kq.py devs | head -1
kill -TERM $P; wait $P; echo "helper exit=$?"
./k.sh stop > /dev/null
echo "### apt python3-serial: /usr/bin/python3 -c 'from esp32c5_kismet import board'"
dpkg-query -W -f='${Package} ${Version}\n' python3-serial python3-msgpack python3-websocket 2>&1
(cd $S; /usr/bin/python3 -c 'from esp32c5_kismet import board; print("board imports:", board.__file__)'; /usr/bin/python3 -c 'from esp32c5_kismet import remote' 2>&1 | tail -1)
rm -rf $R
