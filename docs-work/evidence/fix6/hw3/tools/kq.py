#!/usr/bin/env python3
"""Kismet REST helper for the hw3 run (login from HW3_AUTH, default admin:hw3-Pass-99).

kq.py src                      concise source table
kq.py srcjson                  selected source fields as JSON
kq.py poll OUT SECS HZ         jsonl snapshots of sources
kq.py devs [phy]               device count by phy (+ rows for phy, with frequency)
kq.py get PATH                 raw GET
kq.py post PATH JSON           POST json=<JSON>; prints HTTP status and body
kq.py waitrun NAME SECS        wait until source NAME is running with num_packets>0; prints elapsed
kq.py uuid NAME                uuid of source NAME
kq.py msgs [SINCE]             messagebus messages since epoch SINCE
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("HW3_BASE", "http://127.0.0.1:2501")
AUTH = os.environ.get("HW3_AUTH", "admin:hw3-Pass-99")

SRC_KEYS = ["name", "interface", "running", "error", "error_reason", "warning", "num_packets", "num_error_packets",
            "channel", "hopping", "hop_rate", "hop_offset", "hop_channels", "channels", "uuid", "remote", "retry",
            "retry_attempts", "total_retry_attempts", "hardware", "capture_interface", "definition", "source_number",
            "ipc_pid", "type_driver", "dlt"]


def req(path, post=None, auth=AUTH, raw=False, timeout=15):
    data = None
    if post is not None:
        data = urllib.parse.urlencode({"json": json.dumps(post)}).encode()
    r = urllib.request.Request(BASE + path, data=data)
    if auth:
        r.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            body = resp.read()
            code = resp.status
    except urllib.error.HTTPError as e:
        body = e.read()
        code = e.code
    except Exception as e:
        return 0, str(e)
    if raw:
        return code, body
    try:
        return code, json.loads(body)
    except Exception:
        return code, body.decode(errors="replace")


def strip(d, prefix):
    return {(k[len(prefix):] if k.startswith(prefix) else k): v for k, v in d.items()}


def sources():
    code, raw = req("/datasource/all_sources.json")
    if not isinstance(raw, list):
        return raw
    out = []
    for s in raw:
        s = strip(s, "kismet.datasource.")
        t = s.get("type_driver")
        if isinstance(t, dict):
            s["type_driver"] = t.get("kismet.datasource.driver.type")
        out.append({k: s.get(k) for k in SRC_KEYS if k in s})
    return out


DEV_FIELDS = ["kismet.device.base.phyname", "kismet.device.base.macaddr", "kismet.device.base.name",
              "kismet.device.base.channel", "kismet.device.base.frequency", "kismet.device.base.packets.total",
              "kismet.device.base.signal", "kismet.device.base.type", "kismet.device.base.freq_khz_map"]


def devices():
    code, raw = req("/devices/views/all/devices.json", {"fields": DEV_FIELDS})
    if not isinstance(raw, list):
        return raw
    out = []
    for d in raw:
        d = strip(d, "kismet.device.base.")
        sig = d.get("signal")
        if isinstance(sig, dict):
            d["signal"] = sig.get("kismet.common.signal.last_signal")
        out.append(d)
    return out


def main():
    a = sys.argv[1:]
    cmd = a[0]
    if cmd == "src":
        s_all = sources()
        if not isinstance(s_all, list):
            print("ERR", s_all)
            return
        for s in s_all:
            print("%-26s run=%s err=%s rem=%s pkts=%-6s ch=%-4s hop=%s nch=%s pid=%s uuid=%s dlt=%s reason=%s" % (
                s.get("name"), s.get("running"), s.get("error"), s.get("remote"), s.get("num_packets"),
                s.get("channel"), s.get("hopping"), len(s.get("hop_channels") or []), s.get("ipc_pid"),
                s.get("uuid"), s.get("dlt"), (s.get("error_reason") or "")[:220]))
    elif cmd == "srcjson":
        print(json.dumps(sources(), indent=1))
    elif cmd == "poll":
        out, secs, hz = a[1], float(a[2]), float(a[3])
        end = time.time() + secs
        with open(out, "a") as f:
            while time.time() < end:
                t = time.time()
                s = sources()
                if isinstance(s, list):
                    f.write(json.dumps({"t": round(t, 3), "s": [{k: x.get(k) for k in (
                        "name", "uuid", "running", "error", "num_packets", "num_error_packets", "channel",
                        "hopping", "error_reason", "remote")} for x in s]}) + "\n")
                    f.flush()
                dt = 1.0 / hz - (time.time() - t)
                if dt > 0:
                    time.sleep(dt)
    elif cmd == "devs":
        devs = devices()
        if not isinstance(devs, list):
            print("ERR", devs)
            return
        phy = {}
        for d in devs:
            phy[d.get("phyname")] = phy.get(d.get("phyname"), 0) + 1
        print(json.dumps(phy))
        if len(a) > 1:
            for d in devs:
                if d.get("phyname") == a[1]:
                    print(json.dumps({k: d.get(k) for k in ("macaddr", "name", "channel", "frequency",
                                                           "packets.total", "signal", "freq_khz_map")}))
    elif cmd == "get":
        code, body = req(a[1], raw=True)
        print("HTTP", code)
        sys.stdout.write(body.decode(errors="replace") if isinstance(body, bytes) else str(body))
        print()
    elif cmd == "post":
        code, body = req(a[1], json.loads(a[2]))
        print("HTTP", code)
        print(body if isinstance(body, str) else json.dumps(body))
    elif cmd == "waitrun":
        name, secs = a[1], float(a[2])
        t0 = time.time()
        while time.time() - t0 < secs:
            s_all = sources()
            for s in s_all if isinstance(s_all, list) else []:
                if s.get("name") == name and s.get("running") and (s.get("num_packets") or 0) > 0:
                    print("%.2f" % (time.time() - t0))
                    return
            time.sleep(0.1)
        print("timeout")
    elif cmd == "uuid":
        for s in sources():
            if s.get("name") == a[1]:
                print(s.get("uuid"))
    elif cmd == "msgs":
        since = a[1] if len(a) > 1 else "0"
        code, body = req("/messagebus/last-time/%s/messages.json" % since)
        if isinstance(body, dict):
            body = body.get("kismet.messagebus.list")
        if isinstance(body, list):
            for m in body:
                print("%s flags=%s %s" % (m.get("kismet.messagebus.message_time"), m.get("kismet.messagebus.message_flags"),
                                        m.get("kismet.messagebus.message_string")))
        else:
            print(code, body)


if __name__ == "__main__":
    main()
