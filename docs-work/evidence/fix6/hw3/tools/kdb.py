#!/usr/bin/env python3
"""kdb.py FILE.kismet: packets per (phy, frequency, datasource) from the kismetdb packets table, the sources,
and the 802.15.4 / BTLE devices' frequency as the devices table stores it."""
import json
import sqlite3
import sys

db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
names = {}
for uuid, js in db.execute("SELECT uuid, json FROM datasources"):
    try:
        names[uuid] = json.loads(js).get("kismet.datasource.name")
    except Exception:
        names[uuid] = "?"
print("datasources:", names)
print("packets: phyname | frequency (kHz) | datasource | count | min(signal) | max(signal)")
for phy, freq, src, n, smin, smax in db.execute(
        "SELECT phyname, frequency, datasource, COUNT(*), MIN(signal), MAX(signal) FROM packets "
        "GROUP BY phyname, frequency, datasource ORDER BY phyname, datasource, frequency"):
    print("  %-10s %10s  %-14s %6d  %s..%s" % (phy, freq, names.get(src, src), n, smin, smax))
for phy in ("802.15.4", "BTLE"):
    rows = db.execute("SELECT devmac, device FROM devices WHERE phyname=?", (phy,)).fetchall()
    for mac, js in rows[:8]:
        d = json.loads(js)
        print("device %s %s: frequency %s, channel %r, freq_khz_map %s, packets %s" % (
            phy, mac, d.get("kismet.device.base.frequency"), d.get("kismet.device.base.channel"),
            d.get("kismet.device.base.freq_khz_map"), d.get("kismet.device.base.packets.total")))
    print("%s devices in the devices table: %d" % (phy, len(rows)))
