"""Builds kismet_cap_esp32c5 variants, each with one of this round's framework fixes taken out
again, into /root/fix7c/variants/<name>/kismet_cap_esp32c5. Run in WSL with python3."""
import os
import re
import subprocess

K = "/root/src/kismet"
REPO = "/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface"
OUT = "/root/fix7c/variants"
src = open(K + "/capture_framework.c").read()

SMD = """#if defined(LWS_WITH_SYS_SMD) && defined(LWS_WITH_NETLINK)
                /* lws tells its own listeners about each of the machine's routes as it
                 * starts, and its queue of 40 would drop the rest with a warning each */
                caph->lwsinfo.smd_queue_depth = 1024;
#endif

"""
EMPTY = """    /* A channel set passes the callback's message buffer on, written in or not: an
     * empty one is no message */
    if (msg != NULL && msg[0] == '\\0')
        msg = NULL;

"""
SHUTDOWN = """                /* lws drops the connection without a CLIENT_CONNECTION_ERROR: end the
                 * loop as that would, or the process would wait for good */
                pthread_mutex_lock(&caph->handler_lock);
                caph->lwsclientwsi = NULL;
                caph->lwsestablished = 0;
                caph->shutdown = 1;
                pthread_mutex_unlock(&caph->handler_lock);
                lws_cancel_service(caph->lwscontext);
"""
variants = {"no-smd-depth": SMD, "no-empty-msg-fix": EMPTY, "no-handshake-shutdown": SHUTDOWN}

caplibs = re.search(r"^CAPLIBS\s*=(.*)$", open(K + "/Makefile.inc").read(), re.M).group(1).split()
cflags = ["-g", "-fPIE", "-pthread", "-Wno-unused-function", "-I" + K] + \
    subprocess.check_output(["pkg-config", "--cflags", "libnl-3.0"], text=True).split()
os.makedirs(OUT, exist_ok=True)
subprocess.check_call(["sh", "-c", "cd %s && ar x %s/libkismetdatasource.a mpack.c.o simple_ringbuf_c.c.o version.c.o" % (OUT, K)])
for name, piece in variants.items():
    assert src.count(piece) == 1, name
    d = "%s/%s" % (OUT, name)
    os.makedirs(d, exist_ok=True)
    open(d + "/capture_framework.c", "w").write(src.replace(piece, ""))
    # the tree's headers, as the framework includes them by name
    subprocess.check_call(["gcc"] + cflags + ["-I" + K, "-c", d + "/capture_framework.c", "-o", d + "/capture_framework.c.o"],
                          cwd=K)
    if os.path.exists(d + "/lib.a"):
        os.remove(d + "/lib.a")
    subprocess.check_call(["ar", "rcs", d + "/lib.a", d + "/capture_framework.c.o"] +
                          ["%s/%s" % (OUT, o) for o in ("mpack.c.o", "simple_ringbuf_c.c.o", "version.c.o")])
    subprocess.check_call(["gcc", "-g", "-pthread", "-Wno-unused-function", "-I" + K + "/capture_esp32c5", "-I" + K,
                           "-o", d + "/kismet_cap_esp32c5", REPO + "/kismet/capture_esp32c5/capture_esp32c5.c",
                           d + "/lib.a"] + caplibs + ["-lpthread", "-lm"])
    print("built", d + "/kismet_cap_esp32c5")
