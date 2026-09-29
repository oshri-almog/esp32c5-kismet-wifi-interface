#!/bin/bash
# H11b: verify-flash of the whole image failed on every board with "digest mismatch", right after write-flash
# had reported "Hash of data verified" on each. The firmware writes its NVS (0x9000, 0x6000) and phy_init
# (0xf000, 0x1000) partitions when it boots, and the board had booted in between (write-flash's hard reset).
# So: verify-flash of the regions the firmware never writes (bootloader and partition table 0x0-0x9000, the app
# from 0x10000), and read-flash of the image's whole length, compared region by region.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h11-flash; mkdir -p $D/split; cd $D
IMG=$REPO/firmware/esp32c5-kismet-merged.bin
python3 - $IMG $D/split <<'EOF'
import sys
img = open(sys.argv[1], "rb").read()
open(sys.argv[2] + "/boot-0x0.bin", "wb").write(img[:0x9000])
open(sys.argv[2] + "/app-0x10000.bin", "wb").write(img[0x10000:])
nvs, phy = img[0x9000:0xF000], img[0xF000:0x10000]
print("image %d bytes; its nvs region is %s, its phy_init region is %s" % (
    len(img), "all 0xFF" if nvs == b"\xff" * len(nvs) else "not blank", "all 0xFF" if phy == b"\xff" * len(phy) else "not blank"))
EOF
ls -l $D/split
for m in $MAC_A $MAC_B $MAC_C $MAC_D; do
    dev=$(byid $m)
    echo "=== $m ($(readlink -f $dev))"
    $PY -m esptool --chip esp32c5 -p "$dev" verify-flash 0x0 $D/split/boot-0x0.bin 0x10000 $D/split/app-0x10000.bin > $D/verify-static-$m.log 2>&1
    echo "verify-flash of 0x0-0x9000 and 0x10000-end: exit $?"
    grep -E "Verif|verif|rror|match" $D/verify-static-$m.log
    sleep 2
    $PY -m esptool --chip esp32c5 -p "$dev" read-flash 0x0 1148592 $D/readback-$m.bin > $D/readflash-$m.log 2>&1
    echo "read-flash 0x0 1148592: exit $?"
    python3 - $IMG $D/readback-$m.bin <<'EOF'
import hashlib, sys
img = open(sys.argv[1], "rb").read(); rb = open(sys.argv[2], "rb").read()
h = lambda b: hashlib.sha256(b).hexdigest()[:16]
print("  whole: image %s, flash %s, %s" % (h(img), h(rb), "equal" if img == rb else "differ"))
for name, a, b in (("bootloader+table 0x0-0x9000", 0, 0x9000), ("nvs 0x9000-0xf000", 0x9000, 0xF000),
                   ("phy_init 0xf000-0x10000", 0xF000, 0x10000), ("app 0x10000-end", 0x10000, len(img))):
    diff = [i for i in range(a, b) if img[i] != rb[i]]
    print("  %-28s %s%s" % (name, "equal" if not diff else "differ in %d bytes" % len(diff),
                            (" (0x%x..0x%x)" % (diff[0], diff[-1])) if diff else ""))
EOF
    sleep 2
done
echo "--- START check again, 8 s each"
$PY - <<'EOF' 2>&1 | tee $D/start-check2.txt
import glob, os, struct, time, serial
for dev in sorted(glob.glob("/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_*")):
    s = serial.Serial()
    s.port = dev; s.baudrate = 115200; s.timeout = 0.2; s.exclusive = True
    s.open()
    s.rts = False; s.dtr = False
    s.reset_input_buffer()
    s.write(b"MODE WIFI\n"); time.sleep(0.8)
    s.write(b"CHANNELS 1-177\nSTART %d chk43\n" % int(time.time() * 1e6))
    buf = b""; end = time.time() + 8
    while time.time() < end:
        buf += s.read(4096)
    s.close()
    i = buf.find(b"<<START>> chk43")
    name = dev.split("unit_")[1][:17]
    if i < 0:
        print(name, os.path.realpath(dev), "NO START ANSWER", len(buf), "bytes"); continue
    j = buf.index(b"\n", i) + 1
    magic, vmaj, vmin, _, _, snap, lt = struct.unpack("<IHHiIII", buf[j:j + 24])
    print(name, os.path.realpath(dev), "START ok, magic %08x, version %d.%d, linktype %d, %d bytes after the header in 8 s"
          % (magic, vmaj, vmin, lt, len(buf) - j - 24))
EOF
python3 $T/lockcheck.py /dev/ttyACM* | tee $D/ports-after2.txt
