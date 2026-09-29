#!/usr/bin/env python3
"""fwcheck.py PORT [MODE] [SECS]: open (RTS then DTR released after open), optionally MODE <MODE>,
then START <us> <nonce> (the helpers' form); print the answer (link type) and read records for SECS."""
import os, sys, time
sys.path.insert(0, os.path.expanduser("~/e2e"))
import c5lib
port = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "-" else None
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 3
ser = c5lib.open_port(port)
print("%.3f opened %s" % (time.time(), port), flush=True)
if mode:
    ser, rebooted, info = c5lib.set_mode(port, ser, mode, log=lambda m: print("%.3f %s" % (time.time(), m), flush=True))
    time.sleep(0.8)
st = c5lib.Stream(ser)
h = st.start()
print("%.3f START answered: %s" % (time.time(), h), flush=True)
n = 0; lens = 0
for ts, tu, orig, p in st.records(secs):
    n += 1; lens += len(p)
print("%.3f %d records in %.0f s (%d bytes), desync=%s" % (time.time(), n, secs, lens, st.desync), flush=True)
c5lib.close_port(st.ser)
