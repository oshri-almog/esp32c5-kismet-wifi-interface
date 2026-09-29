#!/bin/sh
# Logins Kismet's query variables cannot carry, against a real Kismet on 2711/3711, with the Python helper
# from the code in $1. Each case starts its own Kismet with that login and stops it by pid.
#   amp_check.sh CODE-DIR
set -u
CODE=$1
PY=/root/esp32c5-venv/bin/python
KISMET=/root/kismet-install/bin/kismet
W=/tmp/pyfix2/amp
export PYTHONDONTWRITEBYTECODE=1
unset KISMET_CAP_APIKEY KISMET_CAP_USER KISMET_CAP_PASSWORD

one() {  # one LABEL USER PASSWORD
    label=$1 user=$2 pass=$3
    rm -rf "$W"; mkdir -p "$W/home/.kismet"
    printf 'httpd_username=%s\nhttpd_password=%s\n' "$user" "$pass" > "$W/home/.kismet/kismet_httpd.conf"
    printf 'httpd_port=2711\nremote_capture_listen=127.0.0.1\nremote_capture_port=3711\n' > "$W/override.conf"
    (cd "$W" && exec "$KISMET" --homedir "$W/home" --no-ncurses --no-logging --override "$W/override.conf") \
        > "$W/kismet.log" 2>&1 &
    KPID=$!
    q=$("$PY" -c 'import sys; from urllib.parse import quote; print("user=%s&password=%s" % (quote(sys.argv[1], safe=""), quote(sys.argv[2], safe="")))' "$user" "$pass")
    up=0
    for i in $(seq 1 120); do
        c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:2711/system/status.json?$q")
        [ "$c" = 200 ] && { up=1; break; }
        # Kismet up but the query login refused ('&'): the Basic one decides
        c=$(curl -s -o /dev/null -w '%{http_code}' -u "$user:$pass" "http://127.0.0.1:2711/system/status.json")
        [ "$c" = 200 ] && { up=1; break; }
        [ "$c" = 401 ] && { up=1; break; }
        sleep 0.5
    done
    echo "== $label: Kismet login user=$(printf %s "$user" | od -An -c | tr -s ' ') (up=$up)"
    echo "   REST, query login: HTTP $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:2711/system/status.json?$q")"
    echo "   REST, Basic (curl -u, split at the first ':'): HTTP $(curl -s -o /dev/null -w '%{http_code}' -u "$user:$pass" "http://127.0.0.1:2711/system/status.json")"
    (cd /tmp && exec timeout -s TERM 9 env PYTHONPATH="$CODE" "$PY" -m esp32c5_kismet.remote --debug \
        --connect 127.0.0.1:2711 --user "$user" --password "$pass" \
        --source "esp32c5:device=$W/nothere,name=amp,uuid=E5C50001-0000-0000-0000-00000000A4A6") > "$W/helper.log" 2>&1
    echo "   helper exit status: $?"
    grep -E "WARNING|<- KDS_OPENREQ|refused the websocket|connected, offering" "$W/helper.log" | cut -c1-260 | sort -u -k3 | head -6 | sed 's/^/   /'
    kill -TERM "$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null
}

one "password with '&'" "amp" "pa&ss"
one "user name with '&'" "a&mp" "pass"
one "password with space and %41" "amp" "pa ss%41x"
one "user name with ':'" "co:lon" "pw"
one "user name with ':' and a password with '&'" "co:lon" "p&w"
rm -rf "$W"
