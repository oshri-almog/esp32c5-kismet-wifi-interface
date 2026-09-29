"""Applies one mutation at a time to a copy of the snapshot and runs the unit tests against it.

    python mutate.py NAME...   (no name: all)
Writes mut-<name>.txt with the tests' tails and prints SURVIVED/KILLED per mutation.
"""
import os
import shutil
import subprocess
import sys
import concurrent.futures

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "base")

R = "esp32c5_kismet/remote.py"
B = "esp32c5_kismet/board.py"

MUTATIONS = {
    # 1. the API key back in the address
    "cookie_to_query": (R, [('        cookie = "KISMET=%s" % quote(args.apikey, safe="")',
                             '        query = "?KISMET=%s" % quote(args.apikey, safe="")')]),
    # the cookie in the header list, not cookie=
    "cookie_in_header_list": (R, [('            header.append("Authorization: " + authorization)\n',
                                   '            header.append("Authorization: " + authorization)\n'
                                   '        if cookie:\n            header.append("Cookie: " + cookie)\n'),
                                  ('origin=origin, header=header, cookie=cookie)',
                                   'origin=origin, header=header)')]),
    # the key not percent-encoded
    "cookie_not_encoded": (R, [('cookie = "KISMET=%s" % quote(args.apikey, safe="")',
                                'cookie = "KISMET=%s" % args.apikey')]),
    # 2. the refusal back to a failed answer and a closed connection
    "refusal_fails": (R, [('                self.send(kv3.configreport(seqno, True, error, channel=self.channel))\n                return\n            self._tune(value)',
                           '                self.send(kv3.configreport(seqno, False, error, channel=self.channel))\n                self.close(error)\n                return\n            self._tune(value)')]),
    "refusal_no_message": (R, [('                self._say(error, kv3.MSG_ERROR)\n', '')]),
    "refusal_info_level": (R, [('                self._say(error, kv3.MSG_ERROR)\n', '                self._say(error)\n')]),
    "refusal_no_reason_in_report": (R, [('self.send(kv3.configreport(seqno, True, error, channel=self.channel))',
                                         'self.send(kv3.configreport(seqno, True, "", channel=self.channel))')]),
    "tune_no_channel_tracking": (R, [('        number = channel_number(channel)\n        self.channel = str(number)\n',
                                      '        number = channel_number(channel)\n')]),
    "refusal_keeps_hopping": (R, [('            self._cancel_hop()  # a single channel cancels hopping, one that is refused as well\n',
                                   ''),
                                  ('            self._tune(value)\n            # Bluetooth',
                                   '            self._cancel_hop()\n            self._tune(value)\n            # Bluetooth')]),
    "unparseable_fails": (R, [('self.send(kv3.configreport(seqno, True, "", channel=self.channel))\n                return\n            if not',
                               'self.send(kv3.configreport(seqno, False, "", channel=self.channel))\n                return\n            if not')]),
    "channel_number_no_sign": (R, [('([+-]?)([0-9]+)', '()([0-9]+)')]),
    "channel_number_no_space": (R, [('r"[ \\t\\n\\v\\f\\r]*([+-]?)', 'r"([+-]?)')]),
    "channel_number_strict": (R, [('    m = re.match(r"[ \\t\\n\\v\\f\\r]*([+-]?)([0-9]+)", text)',
                                   '    m = re.fullmatch(r"[ \\t\\n\\v\\f\\r]*([+-]?)([0-9]+)", text)')]),
    # 3. statuses
    "lost_sync_by_port": (B, [('self._status("%s: lost sync (%s)" % (self.name, framer.sync_lost), "lost")',
                               'self._status("%s: lost sync (%s)" % (self.current_port, framer.sync_lost), "lost")')]),
    "capturing_no_radio": (B, [('self._status("%s capturing (%s)" % (self.name, RADIO_NAME[self.mode]), "capturing")',
                                'self._status("%s capturing" % self.name, "capturing")')]),
    "dropped_btle_error": (R, [('self._say("%s: %d BTLE records of impossible length dropped" % (src.name, self.dropped_btle))',
                                'self._say("%s: %d BTLE records of impossible length dropped" % (src.name, self.dropped_btle), kv3.MSG_ERROR)')]),
    "malformed_error": (R, [('self._say("%s: %d 802.15.4 frames with a malformed TAP header dropped" % (src.name, self.malformed))',
                             'self._say("%s: %d 802.15.4 frames with a malformed TAP header dropped" % (src.name, self.malformed), kv3.MSG_ERROR)')]),
    "no_reconnecting_branch": (B, [('        elif ser is not None:\n            # the C helper',
                                    '        elif False:\n            # the C helper')]),
    "busy_by_port": (B, [('self._status("%s: %s; waiting for it" % (self.name, error), "error")',
                          'self._status("%s; waiting for it" % error, "error")')]),
    "opened_by_port": (B, [('self._status("%s: %s opened" % (self.name, self.current_port), "opened")',
                            'self._status("%s opened" % self.current_port, "opened")')]),
    "other_board_by_port": (B, [('self._status("%s: %s now holds another board, looking for %s" % (self.name, self.port, self.mac),',
                                 'self._status("%s now holds another board, looking for %s" % (self.port, self.mac),')]),
    "moved_by_port": (B, [('self._status("%s: board %s is on %s now" % (self.name, self.mac, other), "info")',
                           'self._status("board %s is on %s now" % (self.mac, other), "info")')]),
    "open_fail_by_port": (B, [('            self._status("%s: %s" % (self.name, error), "error")\n        self._stop_event',
                               '            self._status("%s: %s" % (self.port, error), "error")\n        self._stop_event')]),
    "name_default_none": (B, [('self.name = name or port', 'self.name = name')]),
    "giveup_old_text": (R, [('self.fail("%s: no capture from the board on %s for %.0f seconds%s; is it flashed with the esp32c5 "\n'
                             '                      "sniffer firmware, and is nothing else holding the port?"\n'
                             '                      % (self.source.name, self.source.device, SYNC_TIMEOUT_S, last))',
                             'self.fail("the board on %s has not been capturing for %.0f s%s" % (self.source.device, SYNC_TIMEOUT_S, last))')]),
    "ping_old_text": (R, [('"no PING from Kismet for %.0f seconds"', '"no PING from Kismet for %.0f s"')]),
    "btle_tune_not_skipped": (R, [('        if self.source.mode == "btle":\n            return\n        number = channel_number(channel)',
                                   '        number = channel_number(channel)')]),
}


def run(name):
    path, edits = MUTATIONS[name]
    work = os.path.join(HERE, "mut", name)
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(BASE, work)
    target = os.path.join(work, path)
    with open(target, encoding="utf-8") as f:
        text = f.read()
    for old, new in edits:
        if text.count(old) != 1:
            return name, "NOT APPLIED (%d matches of %r)" % (text.count(old), old[:60])
        text = text.replace(old, new)
    with open(target, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    results = []
    tests = ["tests/test_board.py"] if path == B else []
    tests.append("tests/test_kismet_v3.py")
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    out = []
    killed = []
    for t in tests:
        p = subprocess.run([sys.executable, t], cwd=work, env=env, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=900)
        lines = (p.stdout + p.stderr).splitlines()
        fails = [l for l in lines if l.startswith("FAIL")]
        out.append("== %s exit %d\n%s\n...\n%s" % (t, p.returncode, "\n".join(fails[:5]), "\n".join(lines[-3:])))
        if p.returncode != 0:
            killed.append("%s: %s" % (t, (fails[0] if fails else lines[-1] if lines else "?")[:200]))
    with open(os.path.join(HERE, "mut-%s.txt" % name), "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    shutil.rmtree(work, ignore_errors=True)
    return name, ("KILLED " + " | ".join(killed)) if killed else "SURVIVED"


if __name__ == "__main__":
    names = sys.argv[1:] or list(MUTATIONS)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        for name, verdict in ex.map(run, names):
            print("%-28s %s" % (name, verdict), flush=True)
