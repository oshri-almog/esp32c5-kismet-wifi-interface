#!/usr/bin/env python3
"""watch.py OUT SECS HZ PORT UUID [PID...]

Every 1/HZ s appends one JSON line to OUT: t (epoch), the given pids that are alive with their children
(pid -> [child pids]), the flock holders of PORT (pids, from /proc/locks), and Kismet's running/num_packets
for UUID (and how many sources carry that UUID). Stops after SECS or when the file OUT.stop appears.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kq  # noqa: E402


def children(pid):
    out = []
    try:
        for t in os.listdir("/proc/%d/task" % pid):
            try:
                out += [int(c) for c in open("/proc/%d/task/%s/children" % (pid, t)).read().split()]
            except OSError:
                pass
    except OSError:
        pass
    return out


def flockers(port):
    try:
        st = os.stat(port)
    except OSError:
        return None
    maj, mn, ino = os.major(st.st_dev), os.minor(st.st_dev), st.st_ino
    pids = []
    for line in open("/proc/locks"):
        f = line.split()
        if f[1] == "->":
            continue
        try:
            dmaj, dmin, dino = f[5].split(":")
            if int(dmaj, 16) == maj and int(dmin, 16) == mn and int(dino) == ino:
                pids.append(int(f[4]))
        except (ValueError, IndexError):
            continue
    return pids


def main():
    out, secs, hz, port, uuid = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
    pids = [int(p) for p in sys.argv[6:]]
    end = time.time() + secs
    with open(out, "a") as f:
        while time.time() < end and not os.path.exists(out + ".stop"):
            t = time.time()
            alive = {str(p): children(p) for p in pids if os.path.exists("/proc/%d" % p)}
            s_all = kq.sources()
            match = [s for s in s_all if s.get("uuid") == uuid] if isinstance(s_all, list) else []
            row = {"t": round(t, 3), "alive": alive, "flock": flockers(port),
                   "n_src": len(match),
                   "running": [s.get("running") for s in match], "pkts": [s.get("num_packets") for s in match],
                   "err": [(s.get("error_reason") or "")[:120] for s in match if s.get("error")]}
            f.write(json.dumps(row) + "\n")
            f.flush()
            dt = 1.0 / hz - (time.time() - t)
            if dt > 0:
                time.sleep(dt)


if __name__ == "__main__":
    main()
