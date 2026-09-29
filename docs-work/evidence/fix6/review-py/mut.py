"""Mutation harness: copy /tmp/rvpy/base to /tmp/rvpy/mut-<id>, apply one replacement, run the unit tests."""
import os, shutil, subprocess, sys, json

BASE = "/tmp/rvpy/base"
PY = "/root/esp32c5-venv/bin/python"

MUTS = [
 # id, file, old, new, tests
 ("B1", "esp32c5_kismet/board.py", "if not self.capturing and not framer.need_global_hdr:", "if not self.capturing:", ["board", "v3"]),
 ("B2", "esp32c5_kismet/board.py", "            self.synced = self.capturing = False\n            lost = True", "            self.synced = False\n            lost = True", ["board", "v3"]),
 ("B3", "esp32c5_kismet/board.py", "            self.synced = self.capturing = False\n            framer.resync()", "            self.synced = False\n            framer.resync()", ["board", "v3"]),
 ("B4", "esp32c5_kismet/board.py", 'and fields[5] == want and fields[4] != me:', 'and fields[5] == want:', ["board", "v3"]),
 ("B5", "esp32c5_kismet/board.py", 'if len(fields) >= 6 and fields[1] == "FLOCK" and', 'if len(fields) >= 6 and', ["board", "v3"]),
 ("B6", "esp32c5_kismet/board.py", 'want = "%02x:%02x:%d"', 'want = "%x:%x:%d"', ["board", "v3"]),
 ("B7", "esp32c5_kismet/board.py", "        st = os.stat(device)\n        with open(locks)", "        st = os.lstat(device)\n        with open(locks)", ["board", "v3"]),
 ("R1", "esp32c5_kismet/remote.py", "if link is None or link.capturing:", "if link is None or link.synced:", ["v3"]),
 ("R2", "esp32c5_kismet/remote.py", "                if not self.available(source):", "                if False:", ["v3"]),
 ("R3", "esp32c5_kismet/remote.py", "        if self.held_off != source.device:", "        if True:", ["v3"]),
 ("R4", "esp32c5_kismet/remote.py", "        if not self.in_use(source.device):\n            self.held_off = None\n", "        if not self.in_use(source.device):\n", ["v3"]),
 ("R5", "esp32c5_kismet/remote.py", "        if p.device in held:\n            continue\n", "", ["v3"]),
 ("R6", "esp32c5_kismet/remote.py", "    if len(held) == len(boards):\n        return 1\n", "", ["v3"]),
 ("R7", "esp32c5_kismet/remote.py", 'self.channel = BTLE_CHANNEL if self.source.mode == "btle" else value', "self.channel = value", ["v3"]),
 ("R8", "esp32c5_kismet/remote.py", "            channels = [BTLE_CHANNEL for _ in channels]\n", "            pass\n", ["v3"]),
 ("R9", "esp32c5_kismet/remote.py", "return 37 <= number <= 39", "return True", ["v3"]),
 ("R10", "esp32c5_kismet/remote.py", ",\n                                     freq_khz=BTLE_FREQ_KHZ))", "))", ["v3"]),
 ("R11", "esp32c5_kismet/remote.py", "freq_khz=radiotap_freq_khz(payload)))", "freq_khz=0))", ["v3"]),
 ("R12", "esp32c5_kismet/remote.py", "pos = (pos + 7) // 8 * 8 + 8", "pos += 8", ["v3"]),
 ("R13", "esp32c5_kismet/remote.py", "    pos += pos % 2  # frequency and flags, two u16\n", "", ["v3"]),
 ("R14", "esp32c5_kismet/remote.py", "    while word & (1 << RADIOTAP_EXT):", "    if word & (1 << RADIOTAP_EXT):", ["v3"]),
 ("R15", "esp32c5_kismet/remote.py", "    if args.tcp or args.user is None:\n        return None\n    parts", "    if args.user is None:\n        return None\n    parts", ["v3"]),
 ("R16", "esp32c5_kismet/remote.py", '(("user name", args.user), ("password", args.password))', '(("user name", args.user),)', ["v3"]),
 ("R17", "esp32c5_kismet/remote.py", "        log.error(\"every source thread has died, which is an internal error; stopping\")\n        return 1", "        log.error(\"every source thread has died, which is an internal error; stopping\")\n        return 0", ["v3"]),
 ("R18", "esp32c5_kismet/remote.py", "freq_khz=zigbee_freq_khz(channel)))", "freq_khz=0))", ["v3"]),
 ("R19", "esp32c5_kismet/remote.py", "    if present & (1 << RADIOTAP_TSFT):\n", "    if False:\n", ["v3"]),
 ("R20", "esp32c5_kismet/remote.py", "    pos += bool(present & (1 << RADIOTAP_FLAGS)) + bool(present & (1 << RADIOTAP_RATE))\n", "    pos += bool(present & (1 << RADIOTAP_FLAGS))\n", ["v3"]),
]

only = sys.argv[1:]
results = {}
for mid, f, old, new, tests in MUTS:
    if only and mid not in only:
        continue
    d = "/tmp/rvpy/mut-" + mid
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(BASE, d)
    p = os.path.join(d, f)
    src = open(p).read()
    n = src.count(old)
    if n != 1:
        results[mid] = "PATTERN COUNT %d" % n
        print(mid, results[mid], flush=True)
        continue
    open(p, "w").write(src.replace(old, new))
    out = []
    for t in tests:
        tf = {"board": "tests/test_board.py", "v3": "tests/test_kismet_v3.py"}[t]
        try:
            r = subprocess.run([PY, tf], cwd=d, capture_output=True, text=True, timeout=240)
            txt = r.stdout + r.stderr
            fails = [l for l in txt.splitlines() if l.startswith("FAIL")]
            tb = "Traceback" in txt
            out.append("%s rc=%d fails=%d%s %s" % (t, r.returncode, len(fails), " TRACEBACK" if tb else "", fails[:3]))
            open(d + "/" + t + ".out", "w").write(txt)
        except subprocess.TimeoutExpired:
            out.append("%s TIMEOUT" % t)
    results[mid] = out
    print(mid, out, flush=True)
    shutil.rmtree(os.path.join(d, "tools"), ignore_errors=True)
