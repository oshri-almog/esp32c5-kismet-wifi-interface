"""Builds kismet_cap_esp32c5 variants, each with one of this fix's changes taken out of the tree's
patched capture_framework.c, into /root/fix7cf/variants/<name>/ (kismet_cap_esp32c5, and lib.a for
tests/c). Run in WSL with python3."""
import os
import re
import subprocess

K = "/root/src/kismet"
REPO = "/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface"
OUT = "/root/fix7cf/variants"
src = open(K + "/capture_framework.c").read()

SMD = """#if defined(LWS_WITH_SYS_SMD) && defined(LWS_WITH_NETLINK)
                /* lws tells its own listeners about each of the machine's routes as it
                 * starts, and its queue of 40 would drop the rest with a warning each */
                caph->lwsinfo.smd_queue_depth = 1024;
#endif
"""
REDIRECT_OLD = """            if (caph->lwshandshakes++ > 0) {
                fprintf(stderr, "FATAL: The websocket was answered with a redirect, which is "
                        "not followed: Kismet never redirects it, and the login would go along "
                        "to wherever it points; check --connect, --endpoint and --ssl\\n");
            } else if (auth != NULL"""
REDIRECT_NEW = """            if (auth != NULL"""
TCP_OLD = "        if (caph->use_ws) {\n            if (user != NULL && password != NULL && strchr(user, ':') == NULL) {"
TCP_NEW = "        if (1) {\n            if (user != NULL && password != NULL && strchr(user, ':') == NULL) {"
variants = {
    "no-smd-depth": (SMD, ""),
    "no-redirect-refusal": (REDIRECT_OLD, REDIRECT_NEW),
    "login-over-tcp": (TCP_OLD, TCP_NEW),
}

caplibs = re.search(r"^CAPLIBS\s*=(.*)$", open(K + "/Makefile.inc").read(), re.M).group(1).split()
cflags = ["-g", "-fPIE", "-pthread", "-Wall", "-Wno-unused-function", "-Wno-format-truncation", "-I" + K]
os.makedirs(OUT, exist_ok=True)
others = [o for o in subprocess.check_output(["ar", "t", K + "/libkismetdatasource.a"], text=True).split()
          if o != "capture_framework.c.o"]
subprocess.check_call(["ar", "x", K + "/libkismetdatasource.a"] + others, cwd=OUT)
for name, (old, new) in variants.items():
    assert src.count(old) == 1, name
    d = "%s/%s" % (OUT, name)
    os.makedirs(d, exist_ok=True)
    open(d + "/capture_framework.c", "w").write(src.replace(old, new))
    subprocess.check_call(["gcc"] + cflags + ["-c", d + "/capture_framework.c", "-o", d + "/capture_framework.c.o"],
                          cwd=K)
    if os.path.exists(d + "/lib.a"):
        os.remove(d + "/lib.a")
    subprocess.check_call(["ar", "rcs", d + "/lib.a", d + "/capture_framework.c.o"] + ["%s/%s" % (OUT, o) for o in others])
    subprocess.check_call(["gcc", "-g", "-pthread", "-Wno-unused-function", "-I" + K + "/capture_esp32c5", "-I" + K,
                           "-o", d + "/kismet_cap_esp32c5", REPO + "/kismet/capture_esp32c5/capture_esp32c5.c",
                           d + "/lib.a"] + caplibs + ["-lpthread", "-lm"])
    print("built", d + "/kismet_cap_esp32c5")
