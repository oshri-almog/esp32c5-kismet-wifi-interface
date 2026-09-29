"""Mutation harness (WSL): copy the repo's Python side to /tmp/pyfix2/<tag>-base, then for each mutation a
copy with one replacement, and run the unit tests on it. Usage: mut.py <tag> [ids...]"""
import os
import shutil
import subprocess
import sys

REPO = "/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface"
PY = "/root/esp32c5-venv/bin/python"
TAG = sys.argv[1]
ROOT = "/tmp/pyfix2"
BASE = os.path.join(ROOT, TAG + "-base")

OLD8 = ('                self.capturing = True\n'
        '                self._status("%s capturing" % self.current_port, "capturing")\n'
        '            for record in records:\n'
        '                self.packets += 1\n'
        '                self.on_packet(*record)\n')
NEW8 = ('                self.capturing = True\n'
        '            for record in records:\n'
        '                self.packets += 1\n'
        '                self.on_packet(*record)\n'
        '            if self.capturing and self._last_status != "%s capturing" % self.current_port:\n'
        '                self._status("%s capturing" % self.current_port, "capturing")\n')

MUTS = [
    ("B3", "esp32c5_kismet/board.py", "            self.synced = self.capturing = False\n            framer.resync()",
     "            self.synced = False\n            framer.resync()", ["board", "v3"]),
    ("B8", "esp32c5_kismet/board.py", OLD8, NEW8, ["board", "v3"]),
    ("R4", "esp32c5_kismet/remote.py", "        if not self.in_use(source.device):\n            self.held_off = None\n",
     "        if not self.in_use(source.device):\n", ["v3"]),
    ("R14", "esp32c5_kismet/remote.py", "    while word & (1 << RADIOTAP_EXT):", "    if word & (1 << RADIOTAP_EXT):", ["v3"]),
    # the parity fix, reverted: re-ask and stall timer only while not synced
    ("P1", "esp32c5_kismet/board.py", "            if self.capturing:\n                continue\n            now = time.monotonic()",
     "            if self.synced:\n                continue\n            now = time.monotonic()", ["board"]),
    # the Basic-auth login, reverted to the query
    ("A1", "esp32c5_kismet/remote.py", "    if args.user is not None and \":\" not in args.user:",
     "    if False:", ["v3"]),
]


def copy_repo(dst):
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    for d in ("esp32c5_kismet", "tests", "tools"):
        shutil.copytree(os.path.join(REPO, d), os.path.join(dst, d),
                        ignore=shutil.ignore_patterns("__pycache__", "c"))


copy_repo(BASE)
only = sys.argv[2:]
for mid, f, old, new, tests in MUTS:
    if only and mid not in only:
        continue
    d = os.path.join(ROOT, "%s-mut-%s" % (TAG, mid))
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(BASE, d)
    p = os.path.join(d, f)
    src = open(p).read()
    n = src.count(old)
    if n != 1:
        print(mid, "PATTERN COUNT %d (not applicable to this code)" % n, flush=True)
        shutil.rmtree(d, ignore_errors=True)
        continue
    open(p, "w").write(src.replace(old, new))
    out = []
    for t in tests:
        tf = {"board": "tests/test_board.py", "v3": "tests/test_kismet_v3.py"}[t]
        try:
            r = subprocess.run([PY, tf], cwd=d, capture_output=True, text=True, timeout=300)
            txt = r.stdout + r.stderr
            fails = [line for line in txt.splitlines() if line.startswith("FAIL")]
            passes = sum(line.startswith("PASS") for line in txt.splitlines())
            out.append("%s rc=%d pass=%d fails=%s%s" % (t, r.returncode, passes, fails[:2],
                                                       " TRACEBACK" if "Traceback" in txt else ""))
        except subprocess.TimeoutExpired:
            out.append("%s TIMEOUT" % t)
    print(mid, "->", "; ".join(out), "=>", "CAUGHT" if any("rc=0" not in o for o in out) else "SURVIVES",
          flush=True)
    shutil.rmtree(d, ignore_errors=True)
shutil.rmtree(BASE, ignore_errors=True)
