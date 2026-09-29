"""tests/kismet_e2e.sh with only its remote capture cases, for runs with other helpers (HELPER=...):
written to the path given"""
import sys
src = "/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface/tests/kismet_e2e.sh"
s = open(src, encoding="utf-8", newline="").read()
a = s.index('echo "== Wi-Fi: 2.4 and 5 GHz')
b = s.index('echo "== remote capture: kismet_cap_esp32c5 --connect')
c = s.index('echo "== a bare esp32c5 (no type=)')
d = s.index('if [ "$FAILED" -ne 0 ]; then')
head = s[:a].replace('HERE=$(cd "$(dirname "$0")/.." && pwd)',
                     'HERE=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface')
open(sys.argv[1], "w", encoding="utf-8", newline="").write(head + s[b:c] + s[d:])
