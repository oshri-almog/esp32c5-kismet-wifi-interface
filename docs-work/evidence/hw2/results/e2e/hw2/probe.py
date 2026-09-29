#!/usr/bin/env python3
"""probe.py PORT [--mode WIFI|802154|BLE] [--chan SPEC] [--dwell MS] [--secs N] [--save FILE.pcap] [--quiet]

Raw board check: open PORT (RTS then DTR released after open, flock), optional MODE (waits for reboot),
optional CHANNELS/DWELL, START <us> <nonce>, report the answer, link type and a record summary.
"""
import collections
import json
import os
import struct
import sys
import time

sys.path.insert(0, os.path.expanduser("~/e2e"))
import c5lib  # noqa: E402


def arg(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


def main():
    port = sys.argv[1]
    mode = arg("--mode")
    chan = arg("--chan")
    dwell = arg("--dwell")
    secs = float(arg("--secs", "5"))
    save = arg("--save")
    t0 = time.time()
    ser = c5lib.open_port(port)
    out = {"port": port, "opened_s": round(time.time() - t0, 3)}
    if mode:
        ser, rebooted, info = c5lib.set_mode(port, ser, mode, watch=2.0)
        out["mode"] = {"rebooted": rebooted, **info}
    if dwell:
        c5lib.send(ser, "DWELL %s" % dwell)
    if chan:
        c5lib.send(ser, "CHANNELS %s" % chan)
        time.sleep(0.2)
    st = c5lib.Stream(ser)
    t1 = time.time()
    hdr = st.start()
    out["start"] = hdr
    out["start_answer_s"] = round(time.time() - t1, 3)
    n = 0
    nbytes = 0
    freqs = collections.Counter()
    ble = collections.Counter()
    pdu = collections.Counter()
    ch154 = collections.Counter()
    per_sec = collections.Counter()
    fw = None
    if save:
        fw = open(save, "wb")
        fw.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, hdr["linktype"]))
    for ts, tu, orig, p in st.records(secs):
        n += 1
        nbytes += 16 + len(p)
        per_sec[int(time.time())] += 16 + len(p)
        if fw:
            fw.write(struct.pack("<IIII", ts, tu, len(p), orig) + p)
        lt = hdr["linktype"]
        if lt == 127:
            freqs[c5lib.radiotap_freq(p)] += 1
        elif lt == 256:
            r = c5lib.check_ble(p)
            ble["crc_ok" if r.get("crc") else "crc_bad"] += 1
            ble["flags_0C00" if r.get("flags_ok") else "flags_missing"] += 1
            ble["flags=0x%04x" % r.get("flags", 0)] += 1
            ble["rf=%s" % r.get("rf")] += 1
            pdu[r.get("pdu_type")] += 1
        elif lt == 283:
            ch, frame = c5lib.tap154_split(p)
            ch154[ch] += 1
    if fw:
        fw.close()
    out["records"] = n
    out["bytes"] = nbytes
    out["bytes_per_s"] = round(nbytes / secs, 1)
    out["peak_1s_bytes"] = max(per_sec.values()) if per_sec else 0
    out["desync"] = st.desync
    if freqs:
        out["freqs"] = dict(sorted(((str(k), v) for k, v in freqs.items())))
    if ble:
        out["ble"] = dict(ble)
        out["pdu_types"] = {str(k): v for k, v in pdu.items()}
    if ch154:
        out["ch154"] = {str(k): v for k, v in ch154.items()}
    c5lib.close_port(ser)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
