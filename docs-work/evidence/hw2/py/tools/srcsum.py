#!/usr/bin/env python3
"""srcsum.py: one JSON line per source with the identity fields, from Kismet's REST."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kq  # noqa: E402

KEYS = ("name", "definition", "interface", "capture_interface", "hardware", "uuid", "remote", "running", "error",
        "error_reason", "num_packets", "num_error_packets", "dlt", "channel", "hopping", "hop_rate", "hop_offset")
for s in kq.sources():
    d = {k: s.get(k) for k in KEYS}
    hc = s.get("hop_channels") or []
    d["hop_channels"] = "%d: %s..%s" % (len(hc), hc[0], hc[-1]) if hc else "0"
    print(json.dumps(d))
