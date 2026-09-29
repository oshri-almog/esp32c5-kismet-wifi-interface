#!/bin/bash
# H11: flash all four boards with the merged image, verify each board's flash against the file, then check each
# answers START with link type 127. Nothing may hold a port.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h11-flash; mkdir -p $D; cd $D
IMG=$REPO/firmware/esp32c5-kismet-merged.bin
sha256sum $IMG | tee $D/image.sha256
case "$(cut -c1-8 $D/image.sha256)" in 01a50bd6) ;; *) echo "image sha256 does not start 01a50bd6; not flashing"; exit 1;; esac
ls -l $IMG | tee -a $D/image.sha256
echo "mapping: $(mapping)" | tee $D/mapping.txt
echo "--- pre-flash port check"
pgrep -a kismet | tee $D/pgrep-before.txt
fuser -v /dev/ttyACM* 2>&1 | tee $D/fuser-before.txt
python3 $T/lockcheck.py /dev/ttyACM* | tee $D/ports-before.txt
if fuser /dev/ttyACM* > /dev/null 2>&1; then echo "a port is in use; not flashing"; exit 1; fi
for m in $MAC_A $MAC_B $MAC_C $MAC_D; do
    dev=$(byid $m)
    echo "=== $m ($dev -> $(readlink -f $dev))"
    t=$(now)
    $PY -m esptool --chip esp32c5 -p "$dev" write-flash 0x0 "$IMG" > $D/flash-$m.log 2>&1
    echo "write-flash exit $? in $(awk -v a=$(now) -v b=$t 'BEGIN{printf "%.1f", a-b}') s"
    grep -E "Chip|MAC|Wrote|Hash of data|Hard resetting|rror" $D/flash-$m.log
    sleep 2
    $PY -m esptool --chip esp32c5 -p "$dev" verify-flash 0x0 "$IMG" > $D/verify-$m.log 2>&1
    echo "verify-flash exit $?"
    grep -E "MAC|Verif|verif|match|rror|Hard resetting" $D/verify-$m.log
    sleep 2
done
sleep 3
echo "--- START check (link type 127 expected)"
$PY - <<'EOF' 2>&1 | tee $D/start-check.txt
import glob, os, struct, time, serial
for dev in sorted(glob.glob("/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_*")):
    s = serial.Serial()
    s.port = dev; s.baudrate = 115200; s.timeout = 0.2; s.exclusive = True
    s.open()
    s.rts = False; s.dtr = False
    s.reset_input_buffer()
    s.write(b"MODE WIFI\n"); time.sleep(0.8)
    s.write(b"CHANNELS 1-177\nSTART %d chk42\n" % int(time.time() * 1e6))
    buf = b""; end = time.time() + 4
    while time.time() < end:
        buf += s.read(4096)
    s.close()
    i = buf.find(b"<<START>> chk42")
    name = dev.split("unit_")[1][:17]
    if i < 0:
        print(name, os.path.realpath(dev), "NO START ANSWER", len(buf), "bytes"); continue
    j = buf.index(b"\n", i) + 1
    magic, vmaj, vmin, _, _, snap, lt = struct.unpack("<IHHiIII", buf[j:j + 24])
    print(name, os.path.realpath(dev), "START ok, magic %08x, version %d.%d, linktype %d, %d bytes after the header in 4 s"
          % (magic, vmaj, vmin, lt, len(buf) - j - 24))
EOF
echo "mapping after: $(mapping)" | tee -a $D/mapping.txt
python3 $T/lockcheck.py /dev/ttyACM* | tee $D/ports-after.txt
