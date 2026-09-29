#!/usr/bin/env python3
"""rtime.py KIND N SOURCE LOGTAG [SECS]

KIND: ws-env (C, login from KISMET_CAP_USER/PASSWORD), ws-key (C, KISMET_CAP_APIKEY from ./apikey),
      tcp (C --tcp to 3501), py (Python websocket, --user/--password), py-key (Python, KISMET_CAP_APIKEY)
Runs N sessions: start helper, poll REST at 10 Hz for SECS (default 12), SIGTERM, wait.
Reports per session: Kismet log 'connected' -> 'capturing' (from LOGTAG.log), helper start -> first packet
(REST), packet counts at +2,+4,+6,+8,+10 s.
"""
import json
import os
import signal
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.expanduser("~/e2e/hw2"))
import kq  # noqa: E402

D = os.path.expanduser("~/e2e/hw2")
CAP = os.path.expanduser("~/kismet-install/bin/kismet_cap_esp32c5")
PY = os.path.expanduser("~/esp32c5-venv/bin/python")
REPO = os.path.expanduser("~/esp32c5-kismet-wifi-interface")


def src_pkts(uuid):
    for s in kq.sources() or []:
        if isinstance(s, dict) and s.get("uuid") == uuid:
            return s.get("num_packets") or 0, s.get("running")
    return None, None


def log_times(logfile, since):
    conn = cap = None
    for line in open(logfile, errors="replace"):
        try:
            t = float(line.split(" ", 1)[0])
        except ValueError:
            continue
        if t < since:
            continue
        is_conn = ("Remote source" in line and ("reconnected" in line or ") connected" in line)) or \
            ("New remote source" in line and "connected" in line)
        if conn is None and is_conn:
            conn = t
        if cap is None and "capturing" in line and conn is not None:
            cap = t
    return conn, cap


def main():
    kind, n, source, logtag = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    secs = float(sys.argv[5]) if len(sys.argv) > 5 else 12.0
    uuid = sys.argv[6] if len(sys.argv) > 6 else None
    env = dict(os.environ)
    if kind == "ws-env":
        env.update(KISMET_CAP_USER="admin", KISMET_CAP_PASSWORD="hw2-Pass-99")
        cmd = [CAP, "--connect", "127.0.0.1:2501", "--source", source]
    elif kind == "ws-key":
        env["KISMET_CAP_APIKEY"] = open(os.path.join(D, "apikey")).read().strip()
        cmd = [CAP, "--connect", "127.0.0.1:2501", "--source", source]
    elif kind == "tcp":
        cmd = [CAP, "--connect", "127.0.0.1:3501", "--tcp", "--source", source]
    elif kind == "py":
        cmd = [PY, "-m", "esp32c5_kismet.remote", "--connect", "127.0.0.1:2501", "--user", "admin", "--password",
               "hw2-Pass-99", "--source", source]
    elif kind == "py-key":
        env["KISMET_CAP_APIKEY"] = open(os.path.join(D, "apikey")).read().strip()
        cmd = [PY, "-m", "esp32c5_kismet.remote", "--connect", "127.0.0.1:2501", "--source", source]
    else:
        raise SystemExit("kind?")
    results = []
    for i in range(n):
        base, _ = src_pkts(uuid) if uuid else (None, None)
        base = base or 0
        out = open(os.path.join(D, "rt-%s-%d.out" % (kind, i)), "w")
        t0 = time.time()
        p = subprocess.Popen(cmd, env=env, stdout=out, stderr=subprocess.STDOUT, cwd=REPO, start_new_session=True)
        first = None
        samples = {}
        cmdline_secret = None
        while time.time() - t0 < secs:
            if cmdline_secret is None and time.time() - t0 > 0.5:
                try:
                    cl = open("/proc/%d/cmdline" % p.pid, "rb").read().replace(b"\0", b" ").decode()
                    cmdline_secret = ("hw2-Pass-99" in cl) or ("apikey" in cl.lower())
                except Exception:
                    pass
            if uuid:
                pk, run = src_pkts(uuid)
                el = time.time() - t0
                if pk is not None and pk > base and first is None:
                    first = el
                for mark in (2, 4, 6, 8, 10):
                    if el >= mark and mark not in samples and pk is not None:
                        samples[mark] = pk - base
            time.sleep(0.1)
        os.killpg(p.pid, signal.SIGTERM)
        try:
            rc = p.wait(10)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            rc = p.wait()
        time.sleep(0.5)
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out.close()
        conn, cap = log_times(os.path.join(D, logtag + ".log"), t0)
        r = {"i": i, "rc": rc, "connect_s": None if conn is None else round(conn - t0, 3),
             "connected_to_capturing_s": None if (conn is None or cap is None) else round(cap - conn, 3),
             "start_to_capturing_s": None if cap is None else round(cap - t0, 3),
             "start_to_first_packet_s": None if first is None else round(first, 2),
             "pkts_at": samples, "secret_in_cmdline": cmdline_secret}
        print(json.dumps(r), flush=True)
        results.append(r)
        time.sleep(3)
    for k in ("connected_to_capturing_s", "start_to_capturing_s", "start_to_first_packet_s"):
        v = [r[k] for r in results if r[k] is not None]
        if v:
            print("%s: min %.2f median %.2f max %.2f (n=%d)" % (k, min(v), statistics.median(v), max(v), len(v)))


if __name__ == "__main__":
    main()
