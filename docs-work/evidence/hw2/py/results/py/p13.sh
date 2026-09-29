#!/bin/bash
# p13: the wiki's Python helper unit, approximated as transient systemd --user units (no sudo, no User=):
# stop -> exit status; restart policy after a kill and after status 2; a missing by-id board; Kismet as a user unit.
D=~/e2e/py; cd $D
export XDG_RUNTIME_DIR=/run/user/$(id -u)
echo "user manager: $(systemctl --user is-system-running 2>&1)"
H=/tmp/py/p13; rm -rf $H; mkdir -p $H/.kismet; printf 'httpd_username=admin\nhttpd_password=py-Pass-77\n' > $H/.kismet/kismet_httpd.conf
systemctl --user reset-failed 2>/dev/null
echo "### Kismet as a user unit (logging on, cwd $H)"
systemd-run --user --unit=p13-kismet -p WorkingDirectory=$H ~/kismet-install/bin/kismet --homedir $H --no-ncurses-wrapper
for i in $(seq 1 100); do curl -s -o /dev/null http://127.0.0.1:2501/ && break; sleep 0.1; done
KEY=$(python3 -c "
import sys; sys.path.insert(0, '.'); import kq
code, body = kq.req('/auth/apikey/generate.cmd', {'name': 'svc', 'role': 'datasource', 'duration': 0}); print(body.strip())")
printf 'KISMET_CAP_APIKEY=%s\n' "$KEY" > /tmp/py/helper.env; chmod 600 /tmp/py/helper.env
B=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_
unit() {  # unit NAME ARGS... : the wiki's [Service] settings minus User/Group/SupplementaryGroups
  local n=$1; shift
  systemd-run --user --unit=$n -p Restart=on-failure -p RestartSec=5 -p RestartPreventExitStatus=2 \
    -p EnvironmentFile=/tmp/py/helper.env -p WorkingDirectory=$D/src \
    ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote "$@"; }
st() { systemctl --user show $1 -p ActiveState -p SubState -p ExecMainStatus -p ExecMainCode -p NRestarts -p MainPID | tr '\n' ' '; echo; }
echo "### 1: the wiki's ExecStart (two boards by by-id link, Wi-Fi and BTLE)"
unit p13-helper --connect 127.0.0.1:2501 --source esp32c5:device=${B}10:BD:A3:CF:05:40-if00,mode=wifi,name=pi-wifi --source esp32c5:device=${B}10:BD:A3:C8:7D:54-if00,mode=btle,name=pi-btle
python3 kq.py waitrun pi-wifi 20; python3 kq.py waitrun pi-btle 20; sleep 2
python3 kq.py src | cut -c1-110; st p13-helper
echo "--- Kismet restarted under the helper (systemctl --user restart p13-kismet at $(date +%s.%N))"
systemctl --user restart p13-kismet
for i in $(seq 1 100); do curl -s -o /dev/null http://127.0.0.1:2501/ && break; sleep 0.1; done; echo "kismet up $(date +%s.%N)"
python3 kq.py waitrun pi-wifi 20; python3 kq.py src | cut -c1-110
echo "--- SIGKILL to the helper's main process (on-failure restart expected after 5 s)"
MP=$(systemctl --user show p13-helper -p MainPID --value); kill -KILL $MP; sleep 1; st p13-helper; sleep 6; st p13-helper
python3 kq.py waitrun pi-wifi 20; python3 kq.py src | cut -c1-110
echo "--- systemctl --user stop ($(date +%s.%N))"
systemctl --user stop p13-helper; echo "stopped $(date +%s.%N)"; st p13-helper
journalctl --user -u p13-helper --no-pager -o short-precise 2>/dev/null | tail -12 | cut -c1-200
[ "$(journalctl --user -u p13-helper --no-pager 2>/dev/null | wc -l)" -lt 3 ] && journalctl _SYSTEMD_USER_UNIT=p13-helper.service --no-pager -o short-precise | tail -12 | cut -c1-200
~/e2e/py/locks.sh
echo "### 2: status 2 (a definition with an unknown mode): no restart"
unit p13-bad --connect 127.0.0.1:2501 --source esp32c5-ttyACM0:mode=lora
sleep 8; st p13-bad
journalctl --user -u p13-bad --no-pager 2>/dev/null | tail -3 | cut -c1-200
echo "### 3: a by-id link for a missing MAC, 15 s"
unit p13-missing --connect 127.0.0.1:2501 --source esp32c5:device=${B}AA:BB:CC:DD:EE:FF-if00,mode=wifi,name=missing
sleep 15; st p13-missing
echo "sources in Kismet: $(python3 kq.py src | awk '{print $1}' | tr '\n' ' ')"
journalctl --user -u p13-missing --no-pager 2>/dev/null | tail -4 | cut -c1-200
systemctl --user stop p13-missing; st p13-missing
echo "### Kismet's journal"
systemctl --user stop p13-kismet; st p13-kismet
(journalctl --user -u p13-kismet --no-pager 2>/dev/null; journalctl _SYSTEMD_USER_UNIT=p13-kismet.service --no-pager 2>/dev/null) | grep -i "Loading config override\|capturing\|Opened kismetdb\|pi-wifi\|pi-btle" | sort -u | head -12 | cut -c1-200
systemctl --user reset-failed p13-helper p13-bad p13-missing p13-kismet 2>/dev/null
systemctl --user list-units --all 'p13-*' --no-pager | head -5
rm -f /tmp/py/helper.env
