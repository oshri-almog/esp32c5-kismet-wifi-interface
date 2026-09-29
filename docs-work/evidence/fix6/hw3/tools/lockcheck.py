#!/usr/bin/env python3
"""lockcheck.py [--holders-only] PORT...

For each port: who holds a flock on it (from /proc/locks, by device and inode), and, unless
--holders-only, whether it can be opened now: a plain open (EBUSY = another process has it in
exclusive mode, TIOCEXCL) and then flock(LOCK_EX|LOCK_NB) (EWOULDBLOCK = flocked). The port is
closed again at once. The kernel raises DTR and RTS at open; like the helpers, RTS then DTR are
released right after, which does not reset the board.
"""
import errno
import fcntl
import os
import sys
import termios
import time
import struct

TIOCMBIC = getattr(termios, "TIOCMBIC", 0x5417)
TIOCM_DTR = getattr(termios, "TIOCM_DTR", 0x002)
TIOCM_RTS = getattr(termios, "TIOCM_RTS", 0x004)


def holders(path):
    try:
        st = os.stat(path)
    except OSError as e:
        return "stat failed: %s" % e.strerror
    maj, mn, ino = os.major(st.st_dev), os.minor(st.st_dev), st.st_ino
    out = []
    for line in open("/proc/locks"):
        f = line.split()
        # "1: FLOCK  ADVISORY  WRITE 589 00:16:2235 0 EOF" (a "->" blocked entry has one field more)
        if f[1] == "->":
            f = f[:1] + f[2:]
        try:
            pid = int(f[4])
            dmaj, dmin, dino = f[5].split(":")
        except (ValueError, IndexError):
            continue
        if int(dmaj, 16) == maj and int(dmin, 16) == mn and int(dino) == ino:
            try:
                cmd = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode(errors="replace")
            except OSError:
                cmd = "?"
            out.append("%s %s by pid %d (%s)" % (f[1], f[3], pid, cmd.strip()[:110]))
    return out


def try_open(path):
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
        return "open: %s (%s)" % (errno.errorcode.get(e.errno, e.errno), e.strerror)
    try:
        fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", TIOCM_RTS))
        fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", TIOCM_DTR))
    except OSError:
        pass
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        r = "OPENED and flocked (port free)"
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError as e:
        r = "opened, but flock: %s" % errno.errorcode.get(e.errno, e.errno)
    os.close(fd)
    return r


def main():
    args = sys.argv[1:]
    only = "--holders-only" in args
    args = [a for a in args if a != "--holders-only"]
    for p in args:
        h = holders(p)
        line = "%.3f %s -> %s: holders %s" % (time.time(), p, os.path.realpath(p), h if h else "none")
        if not only:
            line += "; " + try_open(p)
        print(line, flush=True)


if __name__ == "__main__":
    main()
