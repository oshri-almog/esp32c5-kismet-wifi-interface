#!/bin/bash
# H11c: after the flash, board C (38:44:BE:BF:D8:0C), the one that was in 802.15.4 mode before it, answered START
# with link type 127 but sent no records until a MODE BLE / MODE WIFI cycle. Try to reproduce: put it in 802.15.4,
# flash it again, check START (8 s) and CHANNELS 6, then run it as a C local Wi-Fi source in Kismet for 20 s; then
# the same with the board in Wi-Fi before the flash. End with the static regions verified and a START check.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h11-flash/repro; mkdir -p $D; cd $D
IMG=$REPO/firmware/esp32c5-kismet-merged.bin
DEV=$(byid $MAC_C)
startchk() {
    $PY - $DEV <<'EOF'
import os, struct, sys, time, serial
dev = sys.argv[1]
s = serial.Serial(); s.port = dev; s.baudrate = 115200; s.timeout = 0.2; s.exclusive = True
s.open(); s.rts = False; s.dtr = False; s.reset_input_buffer()
s.write(b"MODE WIFI\n"); time.sleep(0.8)
s.write(b"CHANNELS 1-177\nSTART %d chk44\n" % int(time.time() * 1e6))
buf = b""; end = time.time() + 8
while time.time() < end:
    buf += s.read(4096)
s.close()
i = buf.find(b"<<START>> chk44")
if i < 0:
    print(os.path.realpath(dev), "NO START ANSWER", len(buf))
else:
    j = buf.index(b"\n", i) + 1
    lt = struct.unpack("<IHHiIII", buf[j:j + 24])[6]
    print(os.path.realpath(dev), "START ok, linktype %d, %d bytes after the header in 8 s" % (lt, len(buf) - j - 24))
EOF
}
kismet20() {  # kismet20 TAG
    local T2=$(tty_of $MAC_C)
    kstart h11$1 $D/$1 -c esp32c5-$T2 || return 1
    python3 $T/kq.py poll $D/$1/poll.jsonl 20 2
    python3 $T/kq.py src | tee $D/$1/src-end.txt
    kstop $D/$1
    grep -i "esp32c5-$T2" $D/$1/kismet.log | grep -v Detected | cut -c1-200
}
for prior in 802154 WIFI; do
    echo "########## board C in $prior before the flash"
    $PY $T/tx.py $DEV --mode-only $prior
    $PY $T/diag2.py $DEV $prior 2>&1 | sed 's/^/before flash: /'
    fuser -v /dev/ttyACM* 2>&1
    $PY -m esptool --chip esp32c5 -p "$DEV" write-flash 0x0 "$IMG" > $D/flash-prior-$prior.log 2>&1
    echo "write-flash exit $?"; grep -E "Wrote|Hash of data|Hard resetting" $D/flash-prior-$prior.log
    sleep 3
    echo "--- START check (MODE WIFI, CHANNELS 1-177, 8 s)"; startchk
    echo "--- as a C local Wi-Fi source in Kismet, 20 s"; mkdir -p $D/k-$prior; kismet20 k-$prior
    echo "--- diag2 WIFI (no reboot if already in Wi-Fi), then BLE, then WIFI"; $PY $T/diag2.py $DEV WIFI BLE WIFI
done
echo "########## end state of board C"
$PY -m esptool --chip esp32c5 -p "$DEV" verify-flash 0x0 $E/h11-flash/split/boot-0x0.bin 0x10000 $E/h11-flash/split/app-0x10000.bin > $D/verify-static-end.log 2>&1
echo "verify-flash of the static regions: exit $?"; grep -E "Verif" $D/verify-static-end.log
sleep 3
startchk
python3 $T/lockcheck.py /dev/ttyACM*
