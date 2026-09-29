#!/usr/bin/env python3
"""b9an.py TAG: compare TAG.pcapng (Kismet's own packet stream) with TAG.devices.json and TAG.log for BTLE."""
import collections, json, os, re, struct, sys
sys.path.insert(0, os.path.expanduser("~/e2e")); sys.path.insert(0, os.path.expanduser("~/e2e/hw2"))
import c5lib, pcapng

tag = sys.argv[1]
ifaces, pkts = pcapng.parse(tag + ".pcapng")
print("interfaces:", ifaces)
flags = collections.Counter(); crc = collections.Counter(); rf = collections.Counter(); pdut = collections.Counter()
per = collections.Counter(); names = collections.defaultdict(lambda: collections.defaultdict(set)); lt = collections.Counter()
adv_types = {}
for iid, ts, p in pkts:
    lt[ifaces[iid]["linktype"]] += 1
    if ifaces[iid]["linktype"] != 256:
        continue
    r = c5lib.check_ble(p)
    flags["0x%04x" % r.get("flags", 0)] += 1
    crc["ok" if r["crc"] else "bad"] += 1
    rf[r.get("rf")] += 1
    pdut[r.get("pdu_type")] += 1
    a = r.get("adva"); per[a] += 1
    adv_types[a] = "random" if p[14] & 0x40 else "public"
    n = p[15]
    data = p[22:16 + n]
    i = 0
    while i < len(data) and data[i]:
        ln = data[i]; typ = data[i + 1] if i + 1 < len(data) else None
        if typ in (8, 9):
            names[a]["0x%02x" % typ].add(data[i + 2:i + 1 + ln].decode("utf-8", "replace"))
        i += 1 + ln
print("linktypes", dict(lt), "packets", sum(lt.values()))
print("flags", dict(flags), "crc", dict(crc), "rf_channel", dict(rf), "pdu", dict(pdut))
print("advertisers in pcapng", len(per))
devs = json.load(open(tag + ".devices.json"))
print("devices in Kismet", len(devs), collections.Counter(d.get("kismet.device.base.phyname") for d in devs))
src = json.load(open(tag + ".allsrc.json"))
for s in src:
    print("source", s["kismet.datasource.name"], "num_packets", s["kismet.datasource.num_packets"], "channel", s["kismet.datasource.channel"],
          "hop_channels", s.get("kismet.datasource.hop_channels"), "channels", s.get("kismet.datasource.channels"), "dlt", s.get("kismet.datasource.dlt"),
          "error_packets", s.get("kismet.datasource.num_error_packets"))
tot = 0
keys = collections.Counter()
rows = []
for d in devs:
    for k in d:
        keys[k] += 1
    mac = d.get("kismet.device.base.macaddr", "").lower()
    pk = d.get("kismet.device.base.packets.total")
    tot += pk or 0
    rows.append((pk, mac, d.get("kismet.device.base.name"), d.get("kismet.device.base.commonname"), d.get("kismet.device.base.manuf"),
                 d.get("kismet.device.base.type"), d.get("kismet.device.base.channel"), d.get("kismet.device.base.frequency"),
                 per.get(mac), dict((k, sorted(v)) for k, v in names.get(mac, {}).items()), adv_types.get(mac),
                 (d.get("kismet.device.base.signal") or {}).get("kismet.common.signal.last_signal") if isinstance(d.get("kismet.device.base.signal"), dict) else None))
print("sum of device packets.total", tot)
print("device keys:", sorted(k for k in keys if not k.startswith("kismet.device.base.") or k in ("kismet.device.base.phyname",)))
for r in sorted(rows, key=lambda x: -(x[0] or 0)):
    print("pk=%-5s mac=%s name=%r common=%r manuf=%r type=%r ch=%r freq=%r pcap=%s names=%s addr=%s sig=%s" % r)
missing = [a for a in per if a not in {r[1] for r in rows}]
print("advertisers in pcapng without a Kismet device:", missing)
for a, d in names.items():
    print("NAMES", a, dict((k, sorted(v)) for k, v in d.items()))
