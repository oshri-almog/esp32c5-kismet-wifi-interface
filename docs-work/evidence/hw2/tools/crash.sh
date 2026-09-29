#!/bin/bash
# crash.sh TAG SRC FIRST CONFLICT SECOND [gdb]
#  FIRST/SECOND: py | c  (remote helper that offers SRC before / after)
#  CONFLICT: add (add_source.cmd SRC while the remote source is closed) | none
D=~/e2e/hw2; cd $D
TAG=$1; SRC=$2; FIRST=$3; CONFLICT=$4; SECOND=$5; GDB=$6
C=~/kismet-install/bin/kismet_cap_esp32c5
H=/tmp/hw2/$TAG; rm -rf $H; mkdir -p $H/.kismet; printf "httpd_username=admin\nhttpd_password=hw2-Pass-99\n" > $H/.kismet/kismet_httpd.conf
cd $H
if [ -n "$GDB" ]; then
  (gdb -q -batch -ex "handle SIGPIPE nostop noprint pass" -ex "handle SIGTERM nostop pass" -ex "handle SIGINT nostop pass" -ex run -ex "bt 30" -ex "info threads" --args ~/kismet-install/bin/kismet --homedir $H --no-ncurses --no-logging < /dev/null 2>&1; echo "GDB_EXIT=$?") | python3 -u $D/ts.py > $D/$TAG.log 2>&1 &
else
  ((stdbuf -oL -eL ~/kismet-install/bin/kismet --homedir $H --no-ncurses --no-logging < /dev/null 2>&1; echo "KISMET_EXIT=$?") | python3 -u $D/ts.py > $D/$TAG.log) > /dev/null 2>&1 &
fi
cd $D
for i in $(seq 1 120); do curl -s -f -u admin:hw2-Pass-99 http://127.0.0.1:2501/system/status.json >/dev/null 2>&1 && break; sleep 0.25; done
echo "kismet up"
helper() {  # helper KIND LOG
  if [ $1 = c ]; then KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 setsid $C --connect 127.0.0.1:2501 --source "$SRC" > $2 2>&1 & HP=$!
  else (cd ~/esp32c5-kismet-wifi-interface; exec ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source "$SRC" > $2 2>&1) & HP=$!; fi
}
stop_helper() { if [ $1 = c ]; then kill -TERM -$HP; else kill -TERM $HP; fi; wait $HP 2>/dev/null; }
helper $FIRST $D/$TAG.h1.log
sleep 15
python3 kq.py src | cut -c1-160
stop_helper $FIRST
sleep 3
if [ $CONFLICT = add ]; then
  echo "### add_source.cmd $SRC"
  python3 kq.py post /datasource/add_source.cmd "{\"definition\":\"$SRC\"}" | cut -c1-300
  sleep 5
  python3 kq.py src | cut -c1-200
  pgrep -af kismet_cap_esp32c5
fi
echo "### second helper $SECOND"
helper $SECOND $D/$TAG.h2.log
sleep 15
python3 kq.py src | cut -c1-200 || true
stop_helper $SECOND
sleep 1
pkill -TERM -x kismet; for i in $(seq 1 40); do pgrep -x kismet > /dev/null || break; sleep 0.5; done; pkill -KILL -x kismet 2>/dev/null
sleep 2; pkill -f "gdb -q -batch" 2>/dev/null
grep -v "Detected new\|advertising\|^[0-9.]* *$" $D/$TAG.log | grep -i "esp32c5\|conflict\|EXIT\|SIGSEGV\|signal\|#[0-9]\|Thread\|error" | cut -c1-300 | head -80
pgrep -af "kismet|esp32c5" | grep -v avahi
