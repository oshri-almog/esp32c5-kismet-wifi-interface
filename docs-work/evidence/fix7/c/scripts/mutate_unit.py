"""Runs tests/c/run.sh against mutated copies of capture_esp32c5.c, each undoing one of this
round's helper changes. Run in WSL with python3."""
import os
import shutil
import subprocess

REPO = "/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface"
src = open(REPO + "/kismet/capture_esp32c5/capture_esp32c5.c").read()

mutants = {
    # round 1's rule: any '&' in a login
    "warn-any-ampersand": ("strchr(given.user, ':') != NULL &&\n            (strchr", "(strchr"),
    # the ':' condition dropped the other way: a ':' user always warned
    "warn-any-colon": ("            (strchr(given.user, '&') != NULL || strchr(given.password, '&') != NULL))\n        fprintf(stderr, \"WARNING: the Kismet user name holds",
                       "            1)\n        fprintf(stderr, \"WARNING: the Kismet user name holds"),
    # the helper spins down itself again where a send fails
    "send-spindown": ("            local->send_failed = true;\n", "            local->send_failed = true;\n            cf_handler_spindown(local->caph);\n"),
    # the capture thread does not stop on a failed send
    "send-no-stop": ("    while (!local->caph->spindown && !local->send_failed) {", "    while (!local->caph->spindown) {"),
}
for name, (a, b) in mutants.items():
    assert src.count(a) == 1, name
    d = "/root/fix7c/mut/" + name
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d + "/tests/c")
    os.makedirs(d + "/kismet/capture_esp32c5")
    for f in ("run.sh", "test_parser.c"):
        shutil.copy(REPO + "/tests/c/" + f, d + "/tests/c/" + f)
    open(d + "/kismet/capture_esp32c5/capture_esp32c5.c", "w").write(src.replace(a, b))
    r = subprocess.run(["sh", d + "/tests/c/run.sh", "/root/src/kismet"], capture_output=True, text=True)
    fails = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
    print("== %s: exit %d, %d FAIL" % (name, r.returncode, len(fails)))
    for l in fails:
        print("   " + l)
    shutil.rmtree(d)
