#!/usr/bin/env python3
"""h1.py OUTDIR KIND N SOURCE UUID [SECS] [--strace]

KIND: c-ws (C helper, websocket, login from KISMET_CAP_USER/KISMET_CAP_PASSWORD), c-tcp (C helper, --tcp to
3501), py (Python helper, websocket, login from the same environment variables).
Runs N sessions. Each: start the helper in its own session, poll Kismet's REST at 5 Hz for SECS (default 30),
SIGTERM the helper's process group, wait. Per session it writes OUTDIR/KIND-i.out (helper stdout+stderr),
OUTDIR/KIND-i.poll (t since launch, num_packets, running for UUID) and prints a JSON summary line:
first packet (s from launch), increments, largest gap between increments after the first packet, how many of
the 1 s windows after the first packet saw packets, packets at 5 s marks. With --strace the helper runs under
strace -f -tt -e trace=sendto,write (OUTDIR/KIND-i.strace).
"""
import json
import os
import signal
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kq  # noqa: E402

CAP = os.path.expanduser("~/kismet-install/bin/kismet_cap_esp32c5")
PY = os.path.expanduser("~/esp32c5-venv/bin/python")
REPO = os.path.expanduser("~/esp32c5-kismet-wifi-interface")


def src(uuid):
    s_all = kq.sources()
    for s in s_all if isinstance(s_all, list) else []:
        if s.get("uuid") == uuid:
            return s.get("num_packets") or 0, s.get("running")
    return None, None


def main():
    out, kind, n, source, uuid = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
    secs = float(sys.argv[6]) if len(sys.argv) > 6 and not sys.argv[6].startswith("--") else 30.0
    use_strace = "--strace" in sys.argv
    user, pw = kq.AUTH.split(":", 1)
    env = dict(os.environ, KISMET_CAP_USER=user, KISMET_CAP_PASSWORD=pw)
    if kind == "c-ws":
        cmd = [CAP, "--connect", "127.0.0.1:2501", "--source", source]
    elif kind == "c-tcp":
        cmd = [CAP, "--connect", "127.0.0.1:3501", "--tcp", "--source", source]
    elif kind == "py":
        cmd = [PY, "-u", "-m", "esp32c5_kismet.remote", "--connect", "127.0.0.1:2501", "--source", source]
    else:
        raise SystemExit("kind?")
    results = []
    for i in range(n):
        tag = "%s-%d" % (kind, i)
        base, _ = src(uuid)
        c = cmd
        if use_strace:
            c = ["strace", "-f", "-tt", "-e", "trace=sendto,write", "-o", os.path.join(out, tag + ".strace")] + cmd
        fo = open(os.path.join(out, tag + ".out"), "w")
        t0 = time.time()
        p = subprocess.Popen(c, env=env, stdout=fo, stderr=subprocess.STDOUT, cwd=REPO, start_new_session=True)
        rows = []
        with open(os.path.join(out, tag + ".poll"), "w") as fp:
            fp.write(json.dumps({"t0": t0, "pid": p.pid, "cmd": c, "base": base}) + "\n")
            while time.time() - t0 < secs:
                ts = time.time()
                pk, run = src(uuid)
                rows.append((ts - t0, pk, run))
                fp.write(json.dumps({"t": round(ts - t0, 3), "pkts": pk, "running": run}) + "\n")
                fp.flush()
                dt = 0.2 - (time.time() - ts)
                if dt > 0:
                    time.sleep(dt)
        os.killpg(p.pid, signal.SIGTERM)
        try:
            rc = p.wait(10)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            rc = p.wait()
        time.sleep(0.5)
        try:
            os.killpg(p.pid, signal.SIGKILL)
            left = True
        except ProcessLookupError:
            left = False
        fo.close()
        b = base or 0
        first = None
        incs = []
        prev = None
        for t, pk, run in rows:
            if pk is None:
                continue
            if first is None and pk > 0 and pk != b:
                first = t
            if prev is not None and pk > prev:
                incs.append(t)
            prev = pk
        gaps = [round(y - x, 2) for x, y in zip(incs, incs[1:])]
        windows = None
        if first is not None:
            nwin = int(secs - first)
            windows = "%d of %d" % (len({int(t - first) for t in incs if t >= first and int(t - first) < nwin}), nwin)
        marks = {}
        for m in (2, 5, 10, 15, 20, 25, 29):
            v = [pk for t, pk, run in rows if t >= m and pk is not None]
            marks[m] = (v[0] - b) if v else None
        r = {"run": tag, "rc": rc, "group_left_after_term": left,
             "first_packet_s": None if first is None else round(first, 2),
             "increments": len(incs), "max_gap_after_first_s": max(gaps) if gaps else None,
             "one_s_windows_with_packets": windows, "pkts_since_launch_at": marks}
        print(json.dumps(r), flush=True)
        results.append(r)
        time.sleep(3)
    v = [r["first_packet_s"] for r in results if r["first_packet_s"] is not None]
    g = [r["max_gap_after_first_s"] for r in results if r["max_gap_after_first_s"] is not None]
    if v:
        print("%s first packet: min %.2f median %.2f max %.2f (n=%d of %d)" % (
            kind, min(v), statistics.median(v), max(v), len(v), len(results)))
    if g:
        print("%s largest gap between REST increments after the first packet: min %.2f median %.2f max %.2f" % (
            kind, min(g), statistics.median(g), max(g)))


if __name__ == "__main__":
    main()
