#!/bin/bash
# p19: --tcp through SSH tunnels: Pi 127.0.0.1:13502 -(ssh -R)-> Windows 127.0.0.1:3502 -(ssh -L)-> Pi 127.0.0.1:3501
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
echo "listening: $(ss -ltn | grep -E ':13502|:3501' | awk '{print $4}' | tr '\n' ' ')"
./k.sh start p19 > /dev/null || exit 1
echo "listening: $(ss -ltn | grep -E ':13502|:3501' | awk '{print $4}' | tr '\n' ' ')"
./pyh.sh $D/p19.py.log --connect 127.0.0.1:13502 --tcp --source esp32c5-ttyACM0 &
P=$(pidof_log $D/p19.py.log)
python3 kq.py waitrun esp32c5-ttyACM0 20; sleep 5
echo "python: $(python3 kq.py src | grep ttyACM0 | awk '{print $1,$2,$3,$5}')"
echo "helper TCP: $(ss -tnp 2>/dev/null | grep "pid=$P," | awk '{print $4, "->", $5}')"
kill -TERM $P; for i in $(seq 1 50); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
sed 's/^[0-9.]* //' p19.py.log | cut -c1-200
timeout 12 $C --connect 127.0.0.1:13502 --tcp --source esp32c5-ttyACM1 > p19.c.log 2>&1 &
CP=$!
sleep 9; echo "C: $(python3 kq.py src | grep ttyACM1 | awk '{print $1,$2,$3,$5}')"
wait $CP; echo "C exit=$?"; grep -v "lws_\|__lws\|_lws" p19.c.log | head -4 | cut -c1-200
./k.sh stop > /dev/null
