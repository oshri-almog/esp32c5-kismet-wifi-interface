#!/bin/bash
# k.sh start TAG [kismet args...]   (env: LOGGING=1 keeps logging on; KEEPHOME=1 keeps /tmp/hw2/TAG)
# k.sh stop
# k.sh term  (SIGTERM only, no cleanup of home)
PASS=hw2-Pass-99
KUSER=admin
D=$HOME/e2e/hw2
KBIN=${KBIN:-$HOME/kismet-install/bin/kismet}
case "$1" in
start)
  TAG=$2; shift 2
  if pgrep -x kismet >/dev/null; then echo "kismet already running"; exit 1; fi
  H=/tmp/hw2/$TAG
  [ -z "$KEEPHOME" ] && rm -rf $H
  mkdir -p $H/.kismet
  [ -f $H/.kismet/kismet_httpd.conf ] || printf "httpd_username=$KUSER\nhttpd_password=$PASS\n" > $H/.kismet/kismet_httpd.conf
  echo $H > $D/current_home
  cd $H
  EXTRA="--no-logging"
  [ -n "$LOGGING" ] && EXTRA=""
  date +%s.%N > $D/$TAG.t0
  ( (stdbuf -oL -eL $KBIN --homedir $H --no-ncurses $EXTRA "$@" 2>&1 < /dev/null; echo "KISMET_EXIT=$?") | python3 -u $D/ts.py >> $D/$TAG.log) > /dev/null 2>&1 &
  sleep 0.3; pgrep -x kismet > $D/kismet.pid
  for i in $(seq 1 240); do
    if curl -s -f -u $KUSER:$PASS http://127.0.0.1:2501/system/status.json >/dev/null 2>&1; then
      echo "kismet up after $(awk -v a=$(date +%s.%N) -v b=$(cat $D/$TAG.t0) 'BEGIN{printf "%.2f", a-b}') s pid $(cat $D/kismet.pid) home $H"; exit 0; fi
    sleep 0.25
  done
  echo "kismet did not come up"; tail -30 $D/$TAG.log; exit 1;;
stop)
  pkill -TERM -x kismet
  for i in $(seq 1 60); do pgrep -x kismet >/dev/null || break; sleep 0.5; done
  pgrep -x kismet >/dev/null && { echo "SIGKILL kismet"; pkill -KILL -x kismet; }
  sleep 1
  pgrep -a kismet_cap && echo "^^ leftover helpers"
  echo stopped;;
esac
