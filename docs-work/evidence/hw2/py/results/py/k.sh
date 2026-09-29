#!/bin/bash
# k.sh start TAG [kismet args...]   (env: LOGGING=1 keeps logging on; KEEPHOME=1 keeps /tmp/py/TAG; CONFDIR=dir)
# k.sh stop     SIGTERM, then SIGKILL after 30 s
# k.sh kill9    SIGKILL at once
PASS=${KPASS:-py-Pass-77}
KUSER=admin
D=$HOME/e2e/py
KBIN=${KBIN:-$HOME/kismet-install/bin/kismet}
case "$1" in
start)
  TAG=$2; shift 2
  if pgrep -x kismet >/dev/null; then echo "kismet already running"; exit 1; fi
  H=${KHOME:-/tmp/py/$TAG}
  [ -z "$KEEPHOME" ] && rm -rf $H
  mkdir -p $H/.kismet
  [ -f $H/.kismet/kismet_httpd.conf ] || printf "httpd_username=$KUSER\nhttpd_password=$PASS\n" > $H/.kismet/kismet_httpd.conf
  echo $H > $D/current_home
  cd $H
  EXTRA="--no-logging"
  [ -n "$LOGGING" ] && EXTRA=""
  [ -n "$CONFDIR" ] && EXTRA="$EXTRA --confdir $CONFDIR"
  date +%s.%N > $D/$TAG.t0
  ( (stdbuf -oL -eL $KBIN --homedir $H --no-ncurses $EXTRA "$@" 2>&1 < /dev/null; echo "KISMET_EXIT=$?") | python3 -u $D/ts.py >> $D/$TAG.log) > /dev/null 2>&1 &
  sleep 0.3; pgrep -x kismet > $D/kismet.pid
  for i in $(seq 1 240); do
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:2501/system/status.json 2>/dev/null | grep -q "200\|401"; then
      echo "kismet up after $(awk -v a=$(date +%s.%N) -v b=$(cat $D/$TAG.t0) 'BEGIN{printf "%.2f", a-b}') s pid $(cat $D/kismet.pid) home $H"; exit 0; fi
    sleep 0.1
  done
  echo "kismet did not come up"; tail -30 $D/$TAG.log; exit 1;;
stop)
  pkill -TERM -x kismet
  for i in $(seq 1 60); do pgrep -x kismet >/dev/null || break; sleep 0.5; done
  pgrep -x kismet >/dev/null && { echo "SIGKILL kismet"; pkill -KILL -x kismet; }
  sleep 0.5
  pgrep -a kismet_cap && echo "^^ leftover helpers"
  echo stopped;;
kill9)
  pkill -KILL -x kismet; sleep 0.5; echo killed;;
esac
