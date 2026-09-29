import sys
import time

for line in sys.stdin:
    sys.stdout.write("%.3f %s" % (time.time(), line))
    sys.stdout.flush()
