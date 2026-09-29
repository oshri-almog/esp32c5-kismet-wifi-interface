#!/bin/bash
# n7: SIGKILL the local helper 3 times (first with a channel lock on 48); time recovery; strace the relaunched helper
D=~/e2e/hw2; cd $D
./k.sh start n7 -c esp32c5-ttyACM0:name=wA || exit 1
python3 kq.py waitrun wA 20
U=$(python3 kq.py uuid wA)
python3 kq.py poll n7.poll 75 10 &
POLL=$!
sleep 2
for i in 1 2 3; do
  if [ $i = 1 ]; then python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd "{\"channel\":\"48\"}" | cut -c1-60; sleep 3; fi
  P=$(python3 kq.py srcjson | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"ipc_pid\"])")
  echo "kill $i pid $P at $(date +%s.%N)" | tee -a n7.kills
  kill -KILL $P
  for j in $(seq 1 100); do NP=$(python3 kq.py srcjson | python3 -c "import json,sys; s=json.load(sys.stdin)[0]; print(s[\"ipc_pid\"] if s[\"running\"] else 0)"); [ "$NP" != "0" ] && [ "$NP" != "$P" ] && break; sleep 0.1; done
  echo "new pid $NP at $(date +%s.%N)" | tee -a n7.kills
  timeout 8 strace -f -tt -e trace=write -p $NP -o n7.strace.$i 2>/dev/null
  grep -o "write(3, \"[A-Z][^\"]*\"" n7.strace.$i | sort | uniq -c | sort -rn | head -5
  sleep 8
done
wait $POLL
python3 kq.py src | cut -c1-200
./k.sh stop
python3 - <<PY
import json
kills=[l.split() for l in open("n7.kills")]
rows=[json.loads(l) for l in open("n7.poll")]
for i in range(0, len(kills), 2):
    tk=float(kills[i][-1])
    err=next((r["t"] for r in rows if r["t"]>tk and r["s"][0]["error"]), None)
    run=next((r["t"] for r in rows if err and r["t"]>err and r["s"][0]["running"] and not r["s"][0]["error"]), None)
    base=next((r["s"][0]["num_packets"] for r in rows if r["t"]>tk), None)
    pk=next((r["t"] for r in rows if run and r["t"]>run and r["s"][0]["num_packets"]>base), None)
    after=[(r["s"][0]["channel"], r["s"][0]["hopping"]) for r in rows if pk and pk < r["t"] < pk+3]
    print("kill %d: error seen +%.2f, running again +%.2f, first new packet +%.2f, (channel,hopping) after: %s" % (i//2+1, err-tk, run-tk, pk-tk, sorted(set(after))))
PY
grep -h "IPC connection closed\|re-open\|re-opened\|capturing\|setting channel" n7.log | grep -v Detected | cut -c1-200
