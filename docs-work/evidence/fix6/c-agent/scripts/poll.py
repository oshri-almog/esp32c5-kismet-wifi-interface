# poll.py NAME SECONDS HZ : prints t (s since start), num_packets of the source named NAME
import base64, json, sys, time, urllib.request
name, secs, hz = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
user, pw, api = sys.argv[4], sys.argv[5], sys.argv[6]
auth = "Basic " + base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()
t0 = time.monotonic()
while time.monotonic() - t0 < secs:
    t = time.monotonic() - t0
    try:
        req = urllib.request.Request(api + "/datasource/all_sources.json", headers={"Authorization": auth})
        srcs = json.load(urllib.request.urlopen(req, timeout=2))
        s = [x for x in srcs if x.get("kismet.datasource.name") == name]
        n = s[0].get("kismet.datasource.num_packets") if s else None
        ch = s[0].get("kismet.datasource.channel") if s else None
        run = s[0].get("kismet.datasource.running") if s else None
    except Exception as e:
        n, ch, run = "err %s" % e, None, None
    print("%6.2f %s running=%s channel=%s" % (t, n, run, ch), flush=True)
    time.sleep(max(0, 1.0 / hz - ((time.monotonic() - t0) - t)))
