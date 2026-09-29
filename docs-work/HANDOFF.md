# Handoff: finishing esp32c5-kismet-wifi-interface in a cloud session

This branch (`docs-work`) is `main` plus this `docs-work/` folder: the working notes, evidence and
per-page inputs from the local sessions that built the project. Read this file first. The folder is
scaffolding: delete it in the last commit before anything goes to `main`.

## The project

Kismet capture support for ESP32-C5 boards running the sniffer firmware, on all three radios: Wi-Fi
2.4/5 GHz, 802.15.4 (Zigbee/Thread) and BLE advertising.

- `kismet/`: the `esp32c5` datasource (`datasource_esp32c5.h`) and its C capture helper
  (`capture_esp32c5/capture_esp32c5.c`). `add-to-kismet.sh` copies them into a Kismet source tree
  (upstream commit `cfe427074`) and applies upstream bug fixes to `capture_framework.c`.
- `esp32c5_kismet/`: the Python remote helper (`remote.py`, `board.py`, `kismet_v3.py`), for
  machines without a Kismet build, Windows included.
- `firmware/`: the ESP-IDF sniffer firmware.
- `docker/` and `compose.yaml`: a Kismet image with the helper; `.github/workflows/docker.yml`
  publishes it to ghcr.io.
- `tests/`: `c/run.sh` and `c/test_parser.c` (C harness), `test_board.py` and `test_kismet_v3.py`
  (Python), `kismet_e2e.sh` and `remote_e2e.sh` (end to end, against a real Kismet with
  `tools/fake_board.py` boards on ptys), and `docker_smoke.sh`.
- `docs/wiki/`: the wiki, 36 pages plus `_Sidebar` and `_Footer`, in GitHub-wiki Markdown with links
  of the form `[text](Page-Name)`. It carries 537 `<!-- VERIFY: ... -->` markers: claims written
  before they were checked.

## What is in this folder

| Path | What it is |
|---|---|
| `notes/pending-followups.md` | Running list of doc-affecting changes and known issues (firmware ones included) |
| `wikipass/inputs/<Page>.json` | One bundle per wiki page: its VERIFY markers now, the questions behind them, the hardware answers of both helpers, the hardware problems naming the page, and code-derived corrections |
| `wikipass/bundle.py` | Builds those bundles (run it again after editing pages; it reads Windows paths, so adjust them) |
| `verify-questions.txt` | The 487 questions the markers were condensed into, each with the pages it affects |
| `wiki-corrections-from-code.json` | 49 wiki errors found by reading the final code |
| `docs-facts/*.md` | Facts gathered for the wiki from the code and from test runs; `_changes-since.md` lists later changes |
| `results/hw-retest-result.json` | Hardware retest on a Raspberry Pi with four boards, before the fixes (triage, c, python, skeptic) |
| `results/fix6-result.json` | Fix round 1: C/framework and Python fixes, reviews, the Pi re-verification (`hw`) and its skeptic |
| `results/fix7-partial-result.json` | Fix round 2, stopped before the end (see below) |
| `results/pi-docker-test.log`, `results/docker-review2.json` | Docker on the Pi with real boards (8/8 pass, before the fixes), and the Docker review |
| `evidence/hw2`, `evidence/hw3`, `evidence/fix6`, `evidence/fix7` | Raw logs, polls, straces and scripts behind the results (pcap/pcapng files are not included) |

The JSON files cite Windows paths such as
`C:\Users\oshria\AppData\Local\Temp\claude\...\scratchpad\hw3\h1-websocket\...`. Everything after
`scratchpad\` maps to `docs-work/evidence/` here (for example `scratchpad\hw3\...` is
`docs-work/evidence/hw3/...`). `results/` holds the top-level JSON files. Two differences from the originals:
MAC addresses in file names under `evidence/hw3/h11-flash/` use '-' instead of ':' (for example
`verify-10-BD-A3-C8-7D-54.log`), and firmware images and flash read-backs (`*.bin`) were left out,
as were pcap, pcapng and kismetdb files.

## State of the code

**Round 1 (done, verified on the Pi's four real boards, see `results/fix6-result.json` `hw` and
`skeptic`):**
- `capture_framework.c` patches in `add-to-kismet.sh`:
  - wake the websocket service loop from the capture thread; the first packet over `--connect` now
    arrives in 1.2 s instead of 5 to 6 s;
  - a closed websocket ends the capture child;
  - spindown wakes the loop;
  - plus the older `cf_commit_packet` leak fix.
- C helper:
  - the 15 s give-up text reaches Kismet's log (as an ERROR message);
  - "capturing" only after the right link type;
  - the remote capture child dies with its parent (PR_SET_PDEATHSIG, re-armed after setfsuid);
  - a busy-board check before offering a source over `--connect`;
  - BTLE 38/39 reported as 37;
  - lws log level; a frequency in every packet's signal block;
  - a 15 s PING watchdog on the websocket (monotonic clock);
  - `nohup`-safe signals.
- Python helper: the same where it applies; logins go in a Basic `Authorization` header;
  repeat-until-capturing handshake.
- All four Pi boards were reflashed with firmware image sha256 `01a50bd6...`.

**Round 2 (code written and tested, not yet verified on hardware):**
- Both helpers send the login as `Authorization: Basic` and an API key as `Cookie: KISMET=<key>`.
  No secret goes in the URL, except a user name containing ':'. That login falls back to the
  percent-encoded query, and warns only when it also holds an '&'.
- A refused channel set keeps the capture running on its old channel. The helper answers success
  with the old channel and sends Kismet an ERROR message; both helpers now behave alike.
- Status texts name the source in both helpers.
- `add-to-kismet.sh` copies files only when their content changed, so re-running it no longer
  forces a 489 MB kismet relink.
- The lws "rejecting message on queue depth 40" warning is fixed in the framework patch.
- `docker/entrypoint.sh` only refuses the one impossible login (a ':' user name with an '&').
- The Python helper refuses websocket redirects, so the key and login cannot leak to another host.
- The Python side finished its review-fix pass: Windows 238+2 SKIP / 363+1 SKIP, all OK.
- The C side's review found six issues (in `results/fix7-partial-result.json`, `review:c`):
  1. (medium) lws re-sends the Basic login and the KISMET cookie to any redirect target, another
     host included;
  2. `--tcp` is refused when a ':' user name makes the websocket URI longer than 1023 bytes;
  3. the e2e check for the queue warning passes with the fix reverted on hosts with fewer than
     about 40 routes;
  4. the "login does not fit" message suggests an API key even when the key is what did not fit;
  5. the list of stale wiki lines is incomplete (12 lines in 10 pages);
  6. comment nits.

  The C fixer was stopped after it had changed `add-to-kismet.sh`, `tests/c/test_parser.c`,
  `tests/c/run.sh` and `tests/kismet_e2e.sh`, rebuilt and installed the helper, and run the unit
  tests and a mutation build. It never wrote its report. Its transcript's last steps were
  "Run redirect demo against the newly built helper", "Reproduce --tcp long login", "Build helper
  variants with one fix removed each" and "Run remote e2e cases with variant and previous helpers".
- At commit time, on this exact tree in WSL (Ubuntu, lws 4.3.3; Kismet cfe427074 patched by this
  `add-to-kismet.sh`, the helper built from this source):
  - `tests/c/run.sh`: ALL OK;
  - `tests/kismet_e2e.sh`: 80 PASS, 0 FAIL;
  - `tests/remote_e2e.sh`: 101 PASS, 0 FAIL.

  Logs are in `results/final-kismet-e2e.log` and `results/final-remote-e2e.log`. The C review
  findings still need checking one by one (task 1): passing suites do not show that each one was
  fixed.

## Tasks for the cloud session, in order

1. **Close round 2 on the C side.** For each of the six C review findings, check in the code
   whether the stopped fixer resolved it (finding 1 matters most: the helper must not send the
   Basic header or the cookie after a redirect, or must refuse redirects the way the Python helper
   does). Fix what is left, with tests. Then run the full suites.
   - The Python tests need only Python and `websocket-client>=1.9.1`.
   - `tests/c/run.sh`, `kismet_e2e.sh` and `remote_e2e.sh` need a Kismet built from source:
     `git clone https://github.com/kismetwireless/kismet`, `git checkout cfe427074`, install
     Kismet's build dependencies, `kismet/add-to-kismet.sh <tree>`, `./configure`, `make -j$(nproc)`,
     `make install` (as root without a `kismet` group add
     `INSTGRP=root SUIDGROUP=root MANGRP=root`).
   - Kismet reads its config from the passwd home, so the tests pass `--homedir`.
2. **The wiki pass.** Resolve all 537 VERIFY markers so the wiki describes the code as it is now.
   - **Per page:** read the page's bundle in `wikipass/inputs/`, the evidence it cites, the current
     code, and `notes/pending-followups.md`.
   - **When evidence settles a claim:** fix the text if needed and remove the marker.
   - **When nothing tested it:** keep the marker, or say plainly in the text that it is untested.
     This applies especially to macOS and BSD, setuid installs, and a browser walk-through of
     Kismet's web UI (only REST was checked).
   - **Fold in:**
     - the round-1 and round-2 behaviour and message texts (`user_visible_texts` in the result
       files; the helpers' source is the final word);
     - the stale lines the round-2 agents listed in `open_issues`;
     - the firmware known issues in `notes/pending-followups.md` (deaf Wi-Fi after flashing a
       board that was in 802.15.4 mode; the intermittent hang on a Wi-Fi -> BLE switch; the
       whole-image verify-flash that fails after first boot);
     - Kismet limits: kismetdb frequency 0 for 802.15.4 and BTLE; the ERROR frame ignored for
       local sources; `close_source` lasts only until a remote helper reconnects; a remote source
       that reconnects under a known UUID keeps its old options; BLE advertisers whose data ends in
       zero padding never become devices;
     - the new test counts.
   - **Split the work by topic.** For example: install pages; Windows/WSL/macOS-BSD; Docker;
     remote and service; the radio pages and guides; reference (Command-Line-Reference,
     Source-Definitions, Troubleshooting); overview; and the rest.
   - **Then check the whole wiki:** cross-page consistency (the same message text everywhere),
     that every `[text](Page-Name)` link resolves, and that `_Sidebar` lists every page.
   - **Then adversarially verify** a sample of the changed claims against code and evidence.
   - **Style:** plain English, written for someone installing and using the project.
3. **README.md** and the in-code docs must agree with the final wiki.

## Wait for the local machine; do not attempt these here

The cloud cannot reach the owner's LAN, the Raspberry Pi or the USB boards.

- The round-2 hardware check on the Pi:
  - logins with '&', a space and '%41', and API keys, through a logging proxy (no secret in any
    request line);
  - a ':' user-name login;
  - refused BTLE channel 40 with both helpers;
  - stderr noise;
  - a four-source regression through the C local helper and one Python process.
- The Docker image rebuild and `pi-docker-test` on the Pi (needs the owner's sudo).
- Any board flashing, and a Windows run of the Python helper with a real board.

## Rules

- The repository is private. Do not make anything public, create releases or publish images.
- Work on branches and open pull requests for the owner to review. Do not push to `main` directly.
- Never write credentials into files. None of the Pi's are in this folder, and none may be added.
- Keep the code style: plain comments that say why, and the same naming and density as the
  surrounding code.
