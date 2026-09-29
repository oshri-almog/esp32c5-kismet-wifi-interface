#!/bin/bash
# ab.sh TAG SECS SOURCE ORDER...: run the same --source through each helper in ORDER (c = C remote, py = Python remote,
# l = C local via add_source.cmd), SECS each, one pcapng stream per phase, then per-advertiser rates per phase.
D=~/e2e/hw2; cd $D
TAG=$1; SECS=$2; SRC=$3; shift 3
C=~/kismet-install/bin/kismet_cap_esp32c5
./k.sh start $TAG >/dev/null || exit 1
i=0
for ph in "$@"; do
  i=$((i+1)); P=$TAG.$i$ph
  case $ph in
    c) KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 setsid $C --connect 127.0.0.1:2501 --source "$SRC" > $P.log 2>&1 & HP=$!;;
    py) (cd ~/esp32c5-kismet-wifi-interface; exec ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source "$SRC" > $D/$P.log 2>&1) & HP=$!;;
    l) python3 kq.py post /datasource/add_source.cmd "{\"definition\":\"$SRC\"}" > $P.log;;
  esac
  sleep 8   # past start-up
  curl -sN -u admin:hw2-Pass-99 http://127.0.0.1:2501/pcap/all_packets.pcapng -o $P.pcapng & CURL=$!
  sleep $SECS
  kill $CURL; wait $CURL 2>/dev/null
  case $ph in
    c) kill -TERM -$HP; wait $HP 2>/dev/null;;
    py) kill -TERM $HP; wait $HP 2>/dev/null;;
    l) U=$(python3 kq.py uuid "$(echo $SRC | cut -d: -f1)"); python3 kq.py post /datasource/by-uuid/$U/close_source.cmd "{}" >> $P.log;;
  esac
  sleep 3
done
./k.sh stop >/dev/null
python3 - "$TAG" "$@" <<'PY'
import sys, os, collections
sys.path.insert(0, os.path.expanduser("~/e2e")); sys.path.insert(0, os.path.expanduser("~/e2e/hw2"))
import pcapng
tag = sys.argv[1]
for i, ph in enumerate(sys.argv[2:], 1):
    ifaces, pkts = pcapng.parse("%s.%d%s.pcapng" % (tag, i, ph))
    if not pkts:
        print(ph, "no packets"); continue
    ts = [t for _, t, _ in pkts]; dur = max(ts) - min(ts)
    c = collections.Counter(":".join("%02x" % b for b in reversed(p[16:22])) for _, _, p in pkts)
    print("%-3s %5d pkts %.1f s %.1f/s" % (ph, len(pkts), dur, len(pkts) / max(dur, 1)), [(a[-5:], round(n / max(dur, 1), 2)) for a, n in c.most_common(8)])
PY
