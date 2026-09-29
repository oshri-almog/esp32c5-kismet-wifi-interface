import sys, os
sys.path.insert(0, os.path.expanduser("~/e2e/hw2"))
import kq
code, body = kq.req("/datasource/list_interfaces.json")
rows = body if isinstance(body, list) else []
Z = "00000000-0000-0000-0000-000000000000"
names = []
for r in rows:
    n = r.get("kismet.datasource.probed.interface", "?")
    u = r.get("kismet.datasource.probed.in_use_uuid", Z)
    if u != Z:
        n += "[in use by %s]" % u
    names.append(n)
print("HTTP %s, %d rows: %s" % (code, len(rows), " ".join(sorted(names))))
if rows:
    print("  example row:", {k.replace("kismet.datasource.probed.", ""): v for k, v in rows[0].items() if not isinstance(v, (dict, list))})
