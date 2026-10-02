#!/bin/sh
# Container entrypoint for Kismet with the ESP32-C5 capture source, /usr/local/bin/esp32c5-kismet
# in the image. The first argument picks the role; the image's CMD makes it kismet.
#
#   kismet [ARGS]   (the default) Kismet, with one source per ESP32-C5 board found, or with the
#                   sources in KISMET_SOURCES, and always with a web login (see set_login). ARGS
#                   go to Kismet as they are, before the sources' -c options. With -v, --version,
#                   -h or --help among them, Kismet runs straight away: no login, boards or demo.
#   helper          no Kismet here: feed the boards to the Kismet at KISMET_SERVER over remote
#                   capture (the websocket on its web port, without TLS), one kismet_cap_esp32c5
#                   per source, which tries again by itself 5 s after its capture ends, and is
#                   started again 5 s after it exits.
#   anything else   run as a command, e.g. "kismet_cap_esp32c5 --list" or "sh", with the boards'
#                   device nodes kept up to date for it as for the other two.
#
# Options for Kismet go after the word kismet ("docker run ... IMAGE kismet --no-logging"): a first
# argument that is not a role is run as a command.
#
# The container needs no capability added: kismet_cap_esp32c5 drops every capability it has and
# needs none, and kismet_site.conf masks Kismet's other capture helpers, which crash without
# NET_ADMIN. Boards need only the device cgroup rules (see "Serial devices" below).
#
# Environment:
#   KISMET_SOURCES     source definitions separated by spaces (so none can contain one), e.g.
#                        "esp32c5-ttyACM0:mode=wifi esp32c5-ttyACM1:mode=zigbee"
#                      or by the board's /dev/serial/by-id link, the same one as on the host
#                      (its serial number is its MAC), which stays with it whatever ttyACM
#                      number it gets:
#                        "esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee"
#                      kismet role: a source whose board is not there yet is added all the same;
#                      Kismet shows the reason as its error and tries again every 5 s.
#                      Empty: every board found, each in the mode ESP32C5_MODE. Boards are found
#                      by Espressif's USB ID (303a:1001), which the ESP32-C3, C6, H2, S3 and P4
#                      share: with any of those plugged in too, list the sources instead, by
#                      their by-id links, as a ttyACM number can go to another board after a replug.
#   ESP32C5_MODE       wifi (the default), zigbee or btle, for boards found by themselves
#   ESP32C5_WAIT       for boards found by themselves (KISMET_SOURCES empty). kismet role: seconds
#                      to wait at start for one to be plugged in (default 30), and once there are
#                      some, until no more turn up (up to 10 s longer). helper role: only the
#                      second part; with no board at all it exits with status 1. 0: neither.
#                      compose.yaml passes it to the kismet and helper services (default 30).
#   KISMET_USER, KISMET_PASSWORD
#                      kismet role: the web login, written at every start. Without them, a login
#                      already kept in /root/.kismet is used, and failing that one is made up and
#                      printed in the log once. helper role: the remote capture login when
#                      KISMET_APIKEY is not set; any character goes, except that a KISMET_USER
#                      with ':' in it cannot have an '&' in either (see run_helper). They work
#                      only as a pair: one set alone is ignored, with a warning in the kismet role;
#                      the helper role then exits with status 2 unless KISMET_APIKEY is set.
#   KISMET_SERVER      helper: the Kismet to connect to, HOST:PORT (its web port, usually 2501)
#   KISMET_APIKEY      helper: an API key with the datasource role, instead of the login (it wins
#                      when both are set)
#   ESP32C5_DEMO       demo image only: the fake board's radio (wifi, zigbee or btle; 802154 and
#                      ble work too). The demo does not look for boards; sources in
#                      KISMET_SOURCES are still added. Empty: no fake board, and the demo image
#                      behaves like the Kismet image.
#
# The helper role hands the login to kismet_cap_esp32c5 as KISMET_CAP_APIKEY, or KISMET_CAP_USER
# and KISMET_CAP_PASSWORD, in its environment: on its command line every account on the host could
# read it in the process list.
#
# Every role, variable and message in detail:
# https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Docker-Reference

set -eu

log() {
    echo "[esp32c5-kismet] $*" >&2
}

# ------------------------------------------------------------------------------------------------
# Serial devices
#
# The container does not get the host's /dev. It gets permission to use the two USB serial device
# classes (compose.yaml's device_cgroup_rules: 166 is ttyACM, the boards' native USB, and 188 is
# ttyUSB), and makes the device nodes itself from what sysfs says, which a container sees as the
# host does, and /dev/serial/by-id links named as udev names them on the host (sync_by_id). A board
# that reboots or is plugged in again, possibly as another ttyACM number, gets its node within a
# second, and nothing else of the host's /dev -- its terminals, /dev/shm, disks -- is in reach.
#
# A node made here is another inode than the host's node for the same tty, so the flock the
# helpers take on a port does not reach the host or other containers. The tty's exclusive mode
# (TIOCEXCL), which kismet_cap_esp32c5 sets as well, does: the kernel keeps it with the tty, and a
# capture from the host or another container is refused with "already in use". A process with
# CAP_SYS_ADMIN, such as esptool run with sudo, is let in all the same.
#
# That a node could be made says nothing about whether it can be used: Docker lets a container
# mknod any device, and the device cgroup only refuses the open. So each class is tried once, by
# opening a node of it on a minor that no device has, never a board's own port: opening that moves
# DTR and RTS, which are the board's reset lines. Nodes that were in /dev before this script made
# any are Docker's own (docker run --device): usable whatever the try says, and left alone.
# The cgroup can also allow a single board: a rule for its minor alone, or docker run --device to a
# path of another name. The try on the unused minor is refused then, but access(2) asks the device
# cgroup about a node without opening it, so it can tell for the board's own node without moving
# DTR and RTS. It is trusted only where it refused the refused try as well: without faccessat2
# (kernels before 5.8) the C library works the answer out from the mode bits, and says yes to root.
# ------------------------------------------------------------------------------------------------

GIVEN_NODES=""   # those nodes' names,
GIVEN_DEVS=""    # and their device numbers, as stat prints them (a6:0 is 166:0)
MAY_OPEN=""      # the majors the device cgroup lets this container open
ACCESS_OK=""     # set when access(2) was seen to follow the device cgroup
OWN_BY_ID=""     # set when /dev/serial/by-id is ours to keep (it was not there at start)
BY_ID_TTYS=""    # the ttys sync_by_id made a link for

in_list() {  # in_list WORD LIST: is WORD one of the words in LIST?
    case " $2 " in *" $1 "*) return 0 ;; esac
    return 1
}

# May the container open devices of this major? The device cgroup refuses with EPERM; where it
# allows, a minor with nothing behind it gives ENXIO or ENODEV. ($$ in the name: an entrypoint run
# by hand with docker exec may probe at the same time.)
may_open_major() {  # may_open_major MAJOR
    minor=255
    while [ "$minor" -gt 0 ] && [ -e "/sys/dev/char/$1:$minor" ]; do
        minor=$((minor - 1))
    done
    probe=/dev/.esp32c5-probe-$$-$1
    rm -f "$probe"
    mknod -m 600 "$probe" c "$1" "$minor" 2>/dev/null || return 1
    err=$( (exec 3<>"$probe") 2>&1 ) || :
    case $err in
        *"not permitted"*)
            # Refused. If access(2) says no for this node too, it asks the device cgroup, and
            # find_boards can ask it about each board
            if ! { [ -r "$probe" ] && [ -w "$probe" ]; }; then
                ACCESS_OK=1
            fi
            rm -f "$probe"
            return 1
            ;;
    esac
    rm -f "$probe"
    return 0
}

sync_devices() {
    for dev in /sys/class/tty/ttyACM* /sys/class/tty/ttyUSB*; do
        [ -r "$dev/dev" ] || continue
        tty=${dev##*/}
        in_list "$tty" "$GIVEN_NODES" && continue
        majmin=$(cat "$dev/dev" 2>/dev/null) || continue
        major=${majmin%%:*}
        minor=${majmin##*:}
        node=/dev/$tty
        if [ -c "$node" ]; then
            have=$(stat -c '%t:%T' "$node" 2>/dev/null) || have=
            [ "$have" = "$(printf '%x:%x' "$major" "$minor")" ] && continue
            rm -f "$node"
        fi
        mknod -m 660 "$node" c "$major" "$minor" 2>/dev/null || true
    done
    # and forget the ones that are gone
    for node in /dev/ttyACM* /dev/ttyUSB*; do
        [ -c "$node" ] || continue
        in_list "${node##*/}" "$GIVEN_NODES" && continue
        [ -e "/sys/class/tty/${node##*/}" ] || rm -f "$node"
    done
    if [ -n "$OWN_BY_ID" ]; then
        sync_by_id
    fi
}

# A string as udev puts it in a by-id name: trimmed, each run of whitespace one '_', and any other
# character but [0-9A-Za-z#+-.:=@_] a '_' too
udev_string() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/[[:space:]][[:space:]]*/_/g' -e 's/[^0-9A-Za-z#+.:=@_-]/_/g'
}

# /dev/serial/by-id as udev keeps it on the host (its 60-serial.rules and usb_id): for each USB
# serial port, usb-<manufacturer>_<product>_<serial number>-if<interface>, with -port<n> after it
# for a ttyUSB, and the USB IDs where the device has no manufacturer or product string. For these
# boards that is usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00. A link is made only for a
# node that exists, and goes when its tty does. This runs every second, so the attributes are read
# with the shell's own read, and a name is worked out only when a tty's attributes change.
sync_by_id() {
    by_id=/dev/serial/by-id
    [ -d "$by_id" ] || mkdir -p "$by_id" 2>/dev/null || return 0
    # the ttys that are gone: forget them, and drop the links that led to them
    kept=""
    for tty in $BY_ID_TTYS; do
        if [ -c "/dev/$tty" ]; then
            kept="$kept $tty"
        else
            eval "unset BY_ID_KEY_$tty BY_ID_NAME_$tty"
        fi
    done
    BY_ID_TTYS=$kept
    for link in "$by_id"/*; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            rm -f "$link"
        fi
    done
    for dev in /sys/class/tty/ttyACM* /sys/class/tty/ttyUSB*; do
        tty=${dev##*/}
        case $tty in *[!A-Za-z0-9]*) continue ;; esac   # it becomes part of a variable name
        [ -c "/dev/$tty" ] && [ -e "$dev/device" ] || continue
        # ttyACM: device is the USB interface. ttyUSB: device is the port, under the interface.
        case $tty in
            ttyACM*)
                intf=$dev/device
                port=""
                ;;
            *)
                intf=$dev/device/..
                { read -r port < "$dev/device/port_number"; } 2>/dev/null || port=""
                ;;
        esac
        usb=$intf/..
        { read -r ifnum < "$intf/bInterfaceNumber"; } 2>/dev/null || continue
        { read -r vendor < "$usb/manufacturer"; } 2>/dev/null ||
            { read -r vendor < "$usb/idVendor"; } 2>/dev/null || continue
        { read -r model < "$usb/product"; } 2>/dev/null ||
            { read -r model < "$usb/idProduct"; } 2>/dev/null || continue
        { read -r serial < "$usb/serial"; } 2>/dev/null || serial=""
        key="$vendor/$model/$serial/$ifnum/$port"
        old_key=""
        old_name=""
        eval "old_key=\${BY_ID_KEY_$tty-} old_name=\${BY_ID_NAME_$tty-}"
        if [ "$key" = "$old_key" ] && [ -L "$by_id/$old_name" ]; then
            continue
        fi
        # udev leaves out a serial number with a comma or a character outside printable ASCII
        case $serial in *[![:print:]]*|*,*) serial="" ;; esac
        name=usb-$(udev_string "$vendor")_$(udev_string "$model")
        serial=$(udev_string "$serial")
        [ -z "$serial" ] || name=${name}_$serial
        name=$name-if$ifnum${port:+-port$port}
        # Another board on this tty number now: its old link goes, unless it leads elsewhere by now
        if [ -n "$old_name" ] && [ "$old_name" != "$name" ] &&
                [ "$(readlink "$by_id/$old_name" 2>/dev/null)" = "../../$tty" ]; then
            rm -f "$by_id/$old_name"
        fi
        ln -sfn "../../$tty" "$by_id/$name" 2>/dev/null || continue
        eval "BY_ID_KEY_$tty=\$key BY_ID_NAME_$tty=\$name"
        in_list "$tty" "$BY_ID_TTYS" || BY_ID_TTYS="$BY_ID_TTYS $tty"
    done
}

keep_devices_in_sync() {
    # Before the first node is made: what Docker put here itself
    for node in /dev/ttyACM* /dev/ttyUSB*; do
        [ -c "$node" ] || continue
        devno=$(stat -c '%t:%T' "$node" 2>/dev/null) || continue
        GIVEN_NODES="$GIVEN_NODES ${node##*/}"
        GIVEN_DEVS="$GIVEN_DEVS $devno"
    done
    # A /dev/serial/by-id that is already there is not ours: the host's, from a bound /dev
    [ -e /dev/serial/by-id ] || OWN_BY_ID=1
    for major in 166 188; do
        if may_open_major "$major"; then
            MAY_OPEN="$MAY_OPEN $major"
        fi
    done
    sync_devices
    # Until the process this shell becomes (exec) exits, not only the container: an entrypoint
    # run by hand with docker exec leaves no loop behind
    ( while sleep 1 && kill -0 $$ 2>/dev/null; do sync_devices; done ) &
}

# The ttys of every ESP32 on its native USB port (Espressif's USB-Serial-JTAG, 303a:1001)
espressif_ttys() {
    for dev in /sys/class/tty/ttyACM* /sys/class/tty/ttyUSB*; do
        [ -e "$dev/device" ] || continue
        usb=$(readlink -f "$dev/device/..")
        if [ "$(cat "$usb/idVendor" 2>/dev/null)" = 303a ] && [ "$(cat "$usb/idProduct" 2>/dev/null)" = 1001 ]; then
            echo "${dev##*/}"
        fi
    done
}

# Those the container may use: the node is there, and the device cgroup allows its major, or
# Docker gave this very device, or the cgroup allows this one device (a rule for its minor, or
# docker run --device to another path), which access(2) tells without opening the port
find_boards() {
    for tty in $(espressif_ttys); do
        majmin=$(cat "/sys/class/tty/$tty/dev" 2>/dev/null) || continue
        major=${majmin%%:*}
        devno=$(printf '%x:%x' "$major" "${majmin##*:}")
        if [ -c "/dev/$tty" ] && { in_list "$major" "$MAY_OPEN" || in_list "$devno" "$GIVEN_DEVS" ||
                { [ "$ACCESS_OK" = 1 ] && [ -r "/dev/$tty" ] && [ -w "/dev/$tty" ]; }; }; then
            echo "$tty"
        else
            log "found $tty in sysfs but the container may not use it: allow it with"
            log "compose.yaml's device_cgroup_rules, or docker run --device-cgroup-rule 'c $major:* rmw'"
        fi
    done
}

sources() {
    if [ -n "${KISMET_SOURCES:-}" ]; then
        echo "$KISMET_SOURCES"
        return
    fi
    found=""
    for tty in $(find_boards); do
        found="$found esp32c5-$tty:mode=${ESP32C5_MODE:-wifi}"
    done
    echo "$found"
}

# The boards on a hub come up one after another, a few hundred ms apart, and a check can land in
# the middle, the one at start included: check $defs again until two checks in a row agree, 10 s
# at most. A board that is rebooting (a mode switch) when one check is made only makes two
# disagree, so the next ones see it back.
settle() {
    prev=""
    settled=0
    while [ "$defs" != "$prev" ] && [ "$settled" -lt 10 ]; do
        prev=$defs
        sleep 2
        settled=$((settled + 2))
        sync_devices
        defs=$(sources 2>/dev/null)
    done
    # Quiet, as in the wait for a board: if no board is left that the container may use, this
    # says why
    [ -n "$defs" ] || defs=$(sources)
}

# ------------------------------------------------------------------------------------------------
# Kismet
# ------------------------------------------------------------------------------------------------

# Without a login, Kismet serves an unauthenticated page that lets the first visitor set one. With
# the port published, that is whoever gets there first, so a login is always set before Kismet
# starts: the one given, the one kept from an earlier run (or set in the browser then), or a new
# random one, printed once.
set_login() {
    file="$HOME/.kismet/kismet_httpd.conf"
    mkdir -p "$HOME/.kismet"
    # Said whichever login is then used, the kept one included: a password set on its own would
    # otherwise be dropped without a word from the second start on
    case "${KISMET_USER:+user}${KISMET_PASSWORD:+password}" in
        user|password)
            log "KISMET_USER and KISMET_PASSWORD go together; ignoring the one that is set"
            ;;
    esac
    if [ -n "${KISMET_USER:-}" ] && [ -n "${KISMET_PASSWORD:-}" ]; then
        user=$KISMET_USER
        pass=$KISMET_PASSWORD
    elif grep -qs '^httpd_username=.' "$file" && grep -qs '^httpd_password=.' "$file"; then
        return 0
    else
        user="admin"
        pass=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
        log "no web login was set, so Kismet's is now: user $user, password $pass"
        log "(kept in the /root/.kismet volume; set KISMET_USER and KISMET_PASSWORD to choose one)"
    fi
    # umask in a subshell: only the password file is private. Kismet inherits this shell's umask,
    # and with 077 its logs in /data would be readable by root only.
    (
        umask 077
        printf 'httpd_username=%s\nhttpd_password=%s\n' "$user" "$pass" > "$file"
    )
}

run_kismet() {  # run_kismet [KISMET-ARGS...]
    # "kismet --version" or "--help" only print something: no boards, demo or login for those
    for arg in "$@"; do
        case "$arg" in
            -v|--version|-h|--help) exec kismet "$@" ;;
        esac
    done
    set_login
    keep_devices_in_sync
    n=0
    if [ -n "${ESP32C5_DEMO:-}" ] && [ -f /opt/esp32c5/fake_board.py ]; then
        case "$ESP32C5_DEMO" in
            zigbee|802154) boot=802154 ;;
            btle|ble) boot=BLE ;;
            *) boot=WIFI ;;
        esac
        python3 /opt/esp32c5/fake_board.py /tmp/esp32c5-demo "$boot" > /tmp/fake-board.log 2>&1 &
        sleep 1
        log "demo: a fake board on /tmp/esp32c5-demo"
        set -- "$@" -c "esp32c5:device=/tmp/esp32c5-demo,mode=$ESP32C5_DEMO,name=demo"
        n=$((n + 1))
    fi
    # The demo needs no hardware, and the compose demo service may not use any: with the fake board
    # running, only the sources in KISMET_SOURCES are added, and no boards are looked for
    defs=""
    if [ "$n" -eq 0 ] || [ -n "${KISMET_SOURCES:-}" ]; then
        defs=$(sources)
    fi
    # Started before the boards were plugged in (or powered): give them a moment. Not when a board
    # is there that the container may not use: that does not change while it runs.
    limit=${ESP32C5_WAIT:-30}
    if [ "$n" -eq 0 ] && [ -z "$defs" ] && [ -z "$(espressif_ttys)" ] && [ "$limit" -gt 0 ]; then
        log "waiting up to $limit s for an ESP32-C5 board"
        waited=0
        while [ -z "$defs" ] && [ "$waited" -lt "$limit" ]; do
            sleep 2
            waited=$((waited + 2))
            sync_devices
            defs=$(sources 2>/dev/null)
        done
        # The checks above are quiet, or a board the container may not use would say so every 2 s:
        # one that turned up during the wait says it now
        [ -n "$defs" ] || defs=$(sources)
    fi
    if [ -z "${KISMET_SOURCES:-}" ] && [ -n "$defs" ] && [ "$limit" -gt 0 ]; then
        settle
    fi
    for def in $defs; do
        log "source: $def"
        set -- "$@" -c "$def"
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ] && [ -n "$(espressif_ttys)" ]; then
        log "Kismet starts with no source: no board here that the container may use (see above)"
    elif [ "$n" -eq 0 ]; then
        log "no ESP32-C5 board found. Plug one in and restart the container, or add sources from"
        log "the web UI (Data Sources); boards plugged in now appear in the container on their own."
    else
        log "Kismet starts with $n source(s)"
    fi
    exec kismet --no-ncurses "$@"
}

# ------------------------------------------------------------------------------------------------
# Helper: boards here, Kismet elsewhere
# ------------------------------------------------------------------------------------------------

run_helper() {
    : "${KISMET_SERVER:?KISMET_SERVER must be HOST:PORT of the Kismet to feed}"
    # The credentials reach kismet_cap_esp32c5 through its environment, not its command line,
    # where every account on the host could read them in the process list.
    if [ -n "${KISMET_APIKEY:-}" ]; then
        export KISMET_CAP_APIKEY="$KISMET_APIKEY"
    elif [ -n "${KISMET_USER:-}" ] && [ -n "${KISMET_PASSWORD:-}" ]; then
        # kismet_cap_esp32c5 sends the login in an Authorization header (Basic), which Kismet takes
        # as it is. Only a user name with ':', where Basic ends the user name, goes in the remote
        # capture URL's query instead, and Kismet decodes that before it splits it at '&': such a
        # login with an '&' anywhere cannot get through, however it is escaped
        case "$KISMET_USER" in
            *:*)
                case "$KISMET_USER$KISMET_PASSWORD" in
                    *'&'*)
                        echo "helper: a KISMET_USER with ':' in it cannot log in over remote capture" \
                            "when KISMET_USER or KISMET_PASSWORD holds '&'; use KISMET_APIKEY" >&2
                        exit 2
                        ;;
                esac
                ;;
        esac
        export KISMET_CAP_USER="$KISMET_USER" KISMET_CAP_PASSWORD="$KISMET_PASSWORD"
    else
        echo "helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD" >&2
        exit 2
    fi
    unset KISMET_APIKEY KISMET_PASSWORD
    keep_devices_in_sync
    defs=$(sources)
    if [ -z "${KISMET_SOURCES:-}" ] && [ -n "$defs" ] && [ "${ESP32C5_WAIT:-30}" -gt 0 ]; then
        settle
    fi
    if [ -z "$defs" ]; then
        echo "helper: no ESP32-C5 board found and KISMET_SOURCES is empty" >&2
        exit 1
    fi
    # One helper per source. kismet_cap_esp32c5 --connect retries by itself: without
    # --disable-retry its capture framework keeps a parent process that starts the capture again
    # 5 s after it ends ("Sleeping 5 seconds before attempting to reconnect"), whether the board
    # stayed away for 15 s, the server could not be reached, or a definition that names no port
    # (esp32c5, or esp32c5-kitchen without device=) found no board, or more than one to choose
    # from ("Could not probe local source ..."). The process does not exit for any of those. The
    # loop only starts it again when it does exit: after a command-line error (status 255, e.g. a
    # KISMET_SERVER without :PORT) or a kill.
    # Stopping the container stops them all: "kill 0" signals this shell's process group, i.e. the
    # loops and the kismet_cap_esp32c5 in them, after this shell has stopped listening to it.
    # (Not "kill $(jobs -p)": dash runs that in a subshell, which has no jobs, and the failing
    # kill ends the shell under set -e with status 2.)
    trap 'trap "" INT TERM; kill 0 2>/dev/null || :; exit 0' INT TERM
    for def in $defs; do
        (
            while :; do
                log "helper: $def -> $KISMET_SERVER"
                kismet_cap_esp32c5 --connect "$KISMET_SERVER" --source "$def" || true
                sleep 5
            done
        ) &
    done
    wait
}

case "${1:-kismet}" in
    kismet)
        [ $# -gt 0 ] && shift
        run_kismet "$@"
        ;;
    helper)
        run_helper
        ;;
    *)
        # A capture started from here opens the board like the other roles do, so it needs the
        # nodes too (--list alone would not: it reads sysfs and /proc/locks and opens no port.
        # In another container than the one capturing, it sees none of that one's locks, and
        # lists its boards as free.)
        keep_devices_in_sync
        exec "$@"
        ;;
esac
