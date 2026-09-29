#!/usr/bin/env python3
"""pcapng.py FILE [--list N]: summarise a pcapng (Kismet's /pcap/all_packets.pcapng or a pcapng log).

Per interface: link type, name/description, packet count; for 127 the radiotap channel frequency
histogram (walks the radiotap present bits), for 256 the PHDR flags and CRC check, for 230 frame
summary (fc, seq, pan, dst, src).
"""
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.expanduser("~/e2e"))
try:
    import c5lib
except Exception:
    c5lib = None

# radiotap field (align, size) by bit
RT_FIELDS = {0: (8, 8), 1: (1, 1), 2: (1, 1), 3: (2, 4), 4: (2, 2), 5: (1, 1), 6: (1, 1), 7: (2, 2), 8: (2, 2),
             9: (2, 2), 10: (1, 1), 11: (1, 1), 12: (1, 1), 13: (1, 1), 14: (2, 2), 15: (2, 2), 16: (1, 1),
             17: (1, 1), 18: (4, 8), 19: (1, 3), 20: (4, 8), 21: (2, 12), 22: (8, 12), 23: (2, 12)}


def radiotap_freq(p):
    if len(p) < 8 or p[0] != 0:
        return None
    it_len = struct.unpack_from("<H", p, 2)[0]
    presents = []
    off = 4
    while True:
        pr = struct.unpack_from("<I", p, off)[0]
        presents.append(pr)
        off += 4
        if not pr & 0x80000000:
            break
    pr = presents[0]
    for bit in range(0, 31):
        if not pr & (1 << bit):
            continue
        if bit not in RT_FIELDS:
            return None
        align, size = RT_FIELDS[bit]
        off = (off + align - 1) & ~(align - 1)
        if bit == 3:
            return struct.unpack_from("<H", p, off)[0]
        off += size
    return None


def parse(path):
    data = open(path, "rb").read()
    pos = 0
    ifaces = []
    le = "<"
    pkts = []
    while pos + 12 <= len(data):
        btype, blen = struct.unpack_from(le + "II", data, pos)
        if btype == 0x0A0D0D0A:
            bom = struct.unpack_from("<I", data, pos + 8)[0]
            le = "<" if bom == 0x1A2B3C4D else ">"
            blen = struct.unpack_from(le + "I", data, pos + 4)[0]
        if blen < 12 or pos + blen > len(data):
            break
        body = data[pos + 8:pos + blen - 4]
        if btype == 1:
            lt = struct.unpack_from(le + "H", body, 0)[0]
            opts = {}
            o = 8
            while o + 4 <= len(body):
                code, olen = struct.unpack_from(le + "HH", body, o)
                if code == 0:
                    break
                val = body[o + 4:o + 4 + olen]
                if code in (2, 3):
                    opts[{2: "name", 3: "desc"}[code]] = val.decode(errors="replace")
                o += 4 + ((olen + 3) & ~3)
            ifaces.append({"linktype": lt, **opts})
        elif btype == 6:
            iid, th, tl, cap, orig = struct.unpack_from(le + "IIIII", body, 0)
            pkt = body[20:20 + cap]
            ts = ((th << 32) | tl) / 1e6
            pkts.append((iid, ts, pkt))
        pos += blen
    return ifaces, pkts


def main():
    path = sys.argv[1]
    ifaces, pkts = parse(path)
    out = {"file": path, "interfaces": ifaces, "packets": len(pkts)}
    per = collections.defaultdict(lambda: collections.Counter())
    lst = int(sys.argv[sys.argv.index("--list") + 1]) if "--list" in sys.argv else 0
    listed = collections.Counter()
    for iid, ts, p in pkts:
        lt = ifaces[iid]["linktype"] if iid < len(ifaces) else None
        c = per["if%d/lt%s" % (iid, lt)]
        c["count"] += 1
        if lt == 127:
            c["freq=%s" % radiotap_freq(p)] += 1
        elif lt == 256 and c5lib:
            r = c5lib.check_ble(p)
            c["crc_ok" if r.get("crc") else "crc_bad"] += 1
            c["flags=0x%04x" % r.get("flags", 0)] += 1
            c["pdu=%s" % r.get("pdu_type")] += 1
        elif lt == 230:
            if len(p) >= 9:
                fc, seq = struct.unpack_from("<HB", p, 0)
                pan, dst, src = struct.unpack_from("<HHH", p, 3)
                c["fc=0x%04x pan=0x%04x dst=0x%04x src=0x%04x" % (fc, pan, dst, src)] += 1
                if listed[iid] < lst:
                    listed[iid] += 1
                    print("230 seq=%d len=%d payload=%r" % (seq, len(p), p[9:]))
    out["per_interface"] = {k: dict(v) for k, v in per.items()}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
