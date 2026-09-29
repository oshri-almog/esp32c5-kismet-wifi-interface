"""Reverts each round-2 review fix, one at a time, in a copy of the repository's Python files, and runs
tests/test_kismet_v3.py against the copy. Prints KILLED (the tests fail) or SURVIVED per mutation.

    python mutate.py [PYTHON]        PYTHON runs the tests (default: this interpreter)
The copy goes to mut-<name>/ next to this script and is removed afterwards; the tail of each run to
mut-<name>.txt.
"""
import concurrent.futures
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("REPO", r"C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface")
PYTHON = sys.argv[1] if len(sys.argv) > 1 else sys.executable
R = "esp32c5_kismet/remote.py"

MUTATIONS = {
    # finding 1: redirects followed again (websocket-client's default of 3)
    "follow_redirects": [("cookie=cookie, redirect_limit=0)", "cookie=cookie)")],
    # finding 1: no check after the connect, which is all that catches a redirect before 1.9
    "no_redirect_check_after_connect": [("        redirected = self._redirected()\n        if redirected:\n",
                                         "        redirected = None\n        if redirected:\n")],
    # finding 2: a hop does not record its channel
    "tune_no_channel_tracking": [("        number = channel_number(channel)\n        self.channel = str(number)\n",
                                  "        number = channel_number(channel)\n")],
    # finding 3: the old PING text, and the cookie in the header list instead of cookie=
    "ping_old_text": [('"no PING from Kismet for %.0f seconds"', '"no PING from Kismet for %.0f s"')],
    "cookie_in_header_list": [('            header.append("Authorization: " + authorization)\n',
                               '            header.append("Authorization: " + authorization)\n'
                               '        if cookie:\n            header.append("Cookie: " + cookie)\n'),
                              ("cookie=cookie, redirect_limit=0)", "redirect_limit=0)")],
    # finding 4: the empty message back in an accepted set's answer, and in a channel that is no number's
    "accepted_empty_message": [("            self.send(kv3.configreport(seqno, True, None, channel=self.channel))\n"
                                "            return\n\n",
                                "            self.send(kv3.configreport(seqno, True, \"\", channel=self.channel))\n"
                                "            return\n\n")],
    "unparseable_empty_message": [("                self.send(kv3.configreport(seqno, True, None, channel=self.channel))\n"
                                   "                return\n            if not",
                                   "                self.send(kv3.configreport(seqno, True, \"\", channel=self.channel))\n"
                                   "                return\n            if not")],
}


def run(name):
    work = os.path.join(HERE, "mut-" + name)
    shutil.rmtree(work, ignore_errors=True)
    for d in ("esp32c5_kismet", "tests"):
        shutil.copytree(os.path.join(REPO, d), os.path.join(work, d),
                        ignore=shutil.ignore_patterns("__pycache__", "c"))
    path = os.path.join(work, R)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for old, new in MUTATIONS[name]:
        if text.count(old) != 1:
            shutil.rmtree(work, ignore_errors=True)
            return name, "NOT APPLIED (%d matches of %r)" % (text.count(old), old[:60])
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        r = subprocess.run([PYTHON, os.path.join(work, "tests", "test_kismet_v3.py")], capture_output=True,
                           text=True, timeout=900, env=env, cwd=work)
        out, code = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        out, code = str(e), "timeout"
    finally:
        shutil.rmtree(work, ignore_errors=True)
    fails = [line for line in out.splitlines() if line.startswith("FAIL")]
    with open(os.path.join(HERE, "mut-%s%s.txt" % (name, os.environ.get("MUT_TAG", ""))), "w", encoding="utf-8") as f:
        f.write("exit %s\n%s\n" % (code, "\n".join(out.splitlines()[-6:])))
    return name, ("KILLED: " + fails[0]) if code != 0 and fails else ("SURVIVED" if code == 0 else "KILLED (exit %s)" % code)


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        for name, verdict in pool.map(run, MUTATIONS):
            print("%-32s %s" % (name, verdict), flush=True)
