#!/usr/bin/env python3
"""ble_raw.py PORT SECS OUTPREFIX [--keep-mode] [--no-mode]

Raw BLE capture straight from a board (no helper in between): MODE BLE (unless --no-mode),
START <us> <nonce>, then read records for SECS.  Writes OUTPREFIX.pcap (the records exactly as the
board sent them, link type from its global header) and OUTPREFIX.json (summary):
  phdr flags histogram, CRC as sent (valid / zero / other), record length checks, rf_channel,
  PDU types, AdvData lengths, AD types, names by AD type (0x08 shortened / 0x09 complete),
  per-advertiser counts and inter-arrival gaps, overall gap histogram.
Ends with MODE WIFI unless --keep-mode.
"""
import collections
import json
import os
import struct
import sys
import time

sys.path.insert(0, os.path.expanduser("~/e2e"))
import c5lib  # noqa: E402


def log(msg):
    print("%.3f %s" % (time.time(), msg), flush=True)


def ad_structs(data):
    out = []
    i = 0
    while i < len(data):
        ln = data[i]
        if ln == 0:
            break
        if i + 1 + ln > len(data):
            out.append(("trunc", data[i:]))
            break
        out.append((data[i + 1], data[i + 2:i + 1 + ln]))
        i += 1 + ln
    return out


def main():
    port, secs, prefix = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    ser = c5lib.open_port(port)
    log("opened %s" % port)
    if "--no-mode" not in sys.argv:
        ser, rebooted, info = c5lib.set_mode(port, ser, "BLE", log=log)
        time.sleep(0.8)
    st = c5lib.Stream(ser)
    hdr = st.start()
    log("START answered: %s" % hdr)
    s = {"port": port, "global_header": hdr, "secs": secs}
    flags = collections.Counter()
    crc_state = collections.Counter()
    lens = collections.Counter()
    rfch = collections.Counter()
    pdut = collections.Counter()
    advlen = collections.Counter()
    adtypes = collections.Counter()
    names = collections.defaultdict(lambda: collections.defaultdict(set))
    per_adv = collections.Counter()
    last_seen = {}
    adv_gaps = collections.defaultdict(list)
    all_ts = []
    sig = collections.Counter()
    n = 0
    f = open(prefix + ".pcap", "wb")
    f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, hdr["linktype"]))
    t_end = time.time() + secs
    for ts, tu, orig, p in st.records(secs):
        n += 1
        f.write(struct.pack("<IIII", ts, tu, len(p), orig) + p)
        t = ts + tu / 1e6
        all_ts.append(t)
        r = c5lib.check_ble(p)
        flags["0x%04x" % r.get("flags", 0)] += 1
        lens["ok" if r["ok_len"] else "bad"] += 1
        if len(p) >= 19:
            crc = p[-3:]
            if crc == b"\0\0\0":
                crc_state["zero"] += 1
            elif r["crc"]:
                crc_state["valid"] += 1
            else:
                crc_state["other"] += 1
        rfch[r.get("rf")] += 1
        sig[r.get("sig")] += 0
        pt = r.get("pdu_type")
        pdut[pt] += 1
        adva = r.get("adva")
        per_adv[adva] += 1
        if adva in last_seen:
            adv_gaps[adva].append(t - last_seen[adva])
        last_seen[adva] = t
        pdu_len = p[15] if len(p) > 15 else 0
        if pt in (0, 2, 4, 6) and pdu_len >= 6:
            data = p[22:16 + pdu_len]
            advlen[len(data)] += 1
            for typ, val in ad_structs(data):
                adtypes[typ if isinstance(typ, int) else typ] += 1
                if typ in (0x08, 0x09):
                    names[adva]["0x%02x" % typ].add(val.decode("utf-8", "replace"))
    f.close()
    s["desync"] = st.desync
    s["records"] = n
    s["rate_per_s"] = round(n / secs, 1)
    s["phdr_flags"] = dict(flags)
    s["crc_as_sent"] = dict(crc_state)
    s["record_length"] = dict(lens)
    s["rf_channel"] = {str(k): v for k, v in rfch.items()}
    s["pdu_types"] = {str(k): v for k, v in sorted(pdut.items(), key=lambda x: str(x[0]))}
    s["advdata_len_max"] = max(advlen) if advlen else None
    s["advdata_len_hist"] = {str(k): v for k, v in sorted(advlen.items())}
    s["ad_types"] = {("0x%02x" % k if isinstance(k, int) else k): v for k, v in sorted(adtypes.items(), key=lambda x: str(x[0]))}
    s["advertisers"] = len(per_adv)
    s["names"] = {a: {k: sorted(v) for k, v in d.items()} for a, d in names.items()}
    s["top_advertisers"] = []
    for a, c in per_adv.most_common(12):
        g = sorted(adv_gaps[a])
        med = g[len(g) // 2] if g else None
        s["top_advertisers"].append({"adva": a, "count": c, "median_gap_ms": None if med is None else round(med * 1000, 1),
                                     "min_gap_ms": None if not g else round(g[0] * 1000, 1)})
    gaps = [b - a for a, b in zip(all_ts, all_ts[1:])]
    hist = collections.Counter()
    for g in gaps:
        for edge in (0.001, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0):
            if g < edge:
                hist["<%gms" % (edge * 1000)] += 1
                break
        else:
            hist[">=1s"] += 1
    s["all_gap_hist"] = dict(hist)
    s["max_gap_ms"] = round(max(gaps) * 1000, 1) if gaps else None
    json.dump(s, open(prefix + ".json", "w"), indent=1)
    print(json.dumps({k: v for k, v in s.items() if k not in ("names", "top_advertisers")}, indent=1))
    print("names:", json.dumps(s["names"])[:3000])
    print("top:", json.dumps(s["top_advertisers"]))
    if "--keep-mode" not in sys.argv:
        ser, rebooted, info = c5lib.set_mode(port, st.ser, "WIFI", log=log)
    c5lib.close_port(ser)
    log("closed")


if __name__ == "__main__":
    main()
