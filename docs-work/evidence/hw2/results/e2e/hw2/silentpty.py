import os, sys, time, tty
m, s = os.openpty()
tty.setraw(s)
print(os.ttyname(s), flush=True)
open(sys.argv[1], "w").write(os.ttyname(s))
t = time.time()
while time.time() - t < float(sys.argv[2]):
    try:
        d = os.read(m, 4096)
    except OSError:
        time.sleep(0.1)
