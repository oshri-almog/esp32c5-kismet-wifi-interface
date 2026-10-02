This page is for anyone who wants to report a problem or send a change: what to put in a report, how to prepare a pull request, the code style, the two licences, the plan to move the Kismet side into Kismet, and the firmware shared with esp32c5-wireshark-sniffer. How to build and run the tests is on [Development and Testing](Development-and-Testing).

## Where to start

Questions, problems and ideas go in [the repository's issues](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/issues). <!-- VERIFY: OWNER: will the repository be public with issues enabled when this page is published? If not, name where questions go instead (decide, then remove) -->

Before you open one:

1. Look up the symptom on [Troubleshooting](Troubleshooting) and the [FAQ](FAQ). Many messages the helpers and Kismet print are quoted there with their cause.
2. Search the existing issues, open and closed.
3. If you can, try the same thing with the fake board ([Try It Without Hardware](Try-It-Without-Hardware)). A problem that also happens without a board is easier to reproduce and to fix.

## Reporting a problem

Say what you did, what you expected and what happened instead, and whether it happens every time. Then add what applies from this table:

| What | How to get it |
|---|---|
| Your setup | Which one from [Choosing a Setup](Choosing-a-Setup): Kismet built from source, Docker, or boards fed by the Python remote helper. The OS and its version, and the machine, for example a Raspberry Pi 4 with 8 GB. |
| Kismet's version | `kismet --version`. It exits with status 1; that is normal. With Docker: the image tag you run, or the commit you built it from. |
| This project's version | The commit you built or run from: `git rev-parse --short HEAD` in your clone |
| The Python remote helper's packages | `python --version` and `python -m pip show pyserial msgpack websocket-client` |
| The board and firmware | The board model; how it is connected (a powered hub or not; how many boards). Which firmware it runs: built from this repository (which commit), or installed from the esp32c5-wireshark-sniffer browser flasher. |
| The source definitions | Exactly as you gave them: `-c`, `source=`, `--source` or `KISMET_SOURCES` |
| The boards the helpers see | `kismet_cap_esp32c5 --list 2>&1` (it exits with status 2; that is normal), or `python -m esp32c5_kismet.remote --list`. On Linux both leave out a board that another capture holds, with all three of its names (the Python remote helper says so in a `Left out, in use by another capture: ...` line): run them with Kismet and the helpers stopped, or say which boards were in use. |
| Messages | Kismet's output for the source: the lines with its name or `esp32c5`. For the Python remote helper, its output with `--debug` added. For Docker, `docker compose logs kismet \| grep -v "web login"` (which leaves out the line with a made-up web password) or `docker compose logs helper`. |
| The source as Kismet sees it | The source's entry in `/datasource/all_sources.json`, in particular `kismet.datasource.error_reason` |

On Linux, for a Kismet installed in `~/kismet-install` and this project cloned to `~/esp32c5-kismet-wifi-interface` (change the paths to yours, and `admin:PASSWORD` to your Kismet login):

```bash
~/kismet-install/bin/kismet --version
~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1   # with Kismet stopped: a board in use is left out
git -C ~/esp32c5-kismet-wifi-interface rev-parse --short HEAD
curl -s -u admin:PASSWORD http://localhost:2501/datasource/all_sources.json | python3 -m json.tool | grep -E '"kismet.datasource.(name|definition|running|error_reason|hardware|num_packets)"'
```

On Windows, for the Python remote helper, in PowerShell from the repository root:

```powershell
git rev-parse --short HEAD
python --version
python -m pip show pyserial msgpack websocket-client
python -m esp32c5_kismet.remote --list
```

No USB command reports the firmware version. Two signs tell you which firmware a board runs:

- If a BTLE source logs `the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; ...`, the board runs older firmware, such as the one from the esp32c5-wireshark-sniffer browser flasher. The message appears only while the board captures BTLE, once each time the source opens (for a remote helper, once per connection).
- The firmware prints its version on its UART0 log at boot, in the `App version:` line. Reading it needs a UART connection: a devkit's USB connector marked UART, or a USB-UART adapter on GPIO11 and GPIO12 on a board with only the native USB-C port, such as the XIAO ESP32C5. See [Seeing what the firmware does](Development-and-Testing#seeing-what-the-firmware-does).

> **Warning:** Before you post logs or command lines, remove your Kismet login, passwords and API keys: from `--user`, `--password` and `--apikey` options, from `KISMET_PASSWORD`, `KISMET_APIKEY` and `KISMET_CAP_*` variables or a compose `.env` file, and from the `no web login was set, so Kismet's is now: user admin, password ...` line that the kismet container prints when it makes up a login, which `docker compose logs kismet` shows. Kismet's logs and captures also hold the MAC addresses and network names of devices around you that are not yours. Mask them, and do not attach a `.kismet` or `.pcapng` file unless everything in it is yours to share.

Only capture on networks and devices you own or are authorised to test.

### Results from platforms nobody has tested

The project has been tested on a Raspberry Pi 4 with Debian 13, on Windows 11 feeding Kismet in WSL2 and in Docker Desktop, and on WSL2 Ubuntu 24.04. macOS, FreeBSD, OpenBSD, NetBSD, Fedora and Arch have not been tested. The C helper has never been compiled on macOS or a BSD, and the Python remote helper has never run there.

A report from one of those is useful even when everything works. Say what you ran and what happened, and include:

- for the C helper, the build output of `kismet_cap_esp32c5`;
- for a Kismet build on Fedora or Arch, the packages you had to install (only the Debian and Ubuntu names are known);
- on macOS or a BSD, the port name the board got.

The platform pages are [Install on macOS and BSD](Install-on-macOS-and-BSD) and [Install on Linux](Install-on-Linux).

## Proposing a change

For a small fix, send the pull request. For anything larger, open an issue first and describe what you want to change and why, so the approach can be agreed before you write it. This matters most for changes that reach across the project:

- the line protocol or the stream format, which the firmware, both helpers, the fake board and the Wireshark project share;
- source names, `mode=` and `channel=` rules and UUIDs, which the two helpers keep the same, and their messages, which they keep close;
- the Docker roles and environment variables, which people put in their compose files and scripts.

## Sending a pull request

1. Fork the repository and make a branch from `main`.
2. Keep to one change per pull request. A fix and a clean-up are two pull requests.
3. Make the change everywhere it belongs; see [Changes that go together](#changes-that-go-together).
4. Add or change a test that fails without your change. The tests need no framework; see [Tests](#tests).
5. Run the tests for what you changed. The table *Which tests to run for a change* on [Development and Testing](Development-and-Testing) lists them.
6. Update the wiki pages that describe what you changed. They live in the repository in `docs/wiki/`, one Markdown file per page. If you changed a message, search the wiki for the old text: [Troubleshooting](Troubleshooting) quotes many of them. The GitHub wiki is a separate repository, and no workflow in this repository copies `docs/wiki/` into it: the maintainer publishes the pages after a merge. <!-- VERIFY: OWNER: is docs/wiki copied to the GitHub wiki by hand after a merge, or will a sync workflow do it? The text says by hand (decide, then remove) -->
7. Write the pull request description:
   - what changes for the user, and why;
   - which tests you ran, and on which OS;
   - whether you tested with the fake board or with real boards, and on which firmware;
   - what you could not test.

CI runs only the Docker smoke test. On pushes to `main` and on pull requests it runs only when `kismet/`, `docker/`, `.dockerignore`, `tools/fake_board.py`, `tests/docker_smoke.sh` or the workflow change; it also runs for version tags and for manual runs. For everything else, the list of tests you ran is the only record that the change works. [CI](Development-and-Testing#ci) on Development and Testing has the details.

Write commit messages as one summary line in the imperative that says what changes, with a body when the reason is not obvious. The sibling project's history shows the style: "Read a channel spec in the numbering of the radio it is for", "Explain the board that prints `<<START>>` and then goes quiet".

### Changes that go together

| If you change | Also change |
|---|---|
| A source name or alias, a `mode=` or `channel=` rule, the UUID or hardware label, or a message, in one helper | The other helper, and both helpers' tests. The Python remote helper follows the C helper's names and rules on purpose: the same UUIDs, labels, names, `channel=` rules, port lock, stream parser and BLE fix-up. |
| The line protocol or the stream format: a command, the start marker, a record layout | The firmware, both helpers and the fake board, and [Firmware Protocol](Firmware-Protocol). Check whether it breaks boards flashed for esp32c5-wireshark-sniffer ([below](#firmware-shared-with-esp32c5-wireshark-sniffer)). |
| `capture_esp32c5.c`, `datasource_esp32c5.h` or `capture_esp32c5/Makefile.in` | `add-to-kismet.sh`, if the build wiring changes |
| The Docker entrypoint's roles or variables | `compose.yaml`, `tests/docker_smoke.sh` and [Docker Reference](Docker-Reference) |
| A default, a limit or a measured number the wiki states | The wiki pages that state it |

## Code style

There is no formatter or linter to run. Match the file you are in: its indentation, naming and line length, and the way its comments explain why rather than what.

| Where | Language | What to keep |
|---|---|---|
| `kismet/` | C, and a C++ header | Kismet's conventions. Each C file and header starts with Kismet's licence header; scripts carry an SPDX line. The helper is built like Kismet's own serial capture helpers (`capture_freaklabs_zigbee_v2`, `capture_catsniffer_zigbee`), on Kismet's capture framework. In C, 4 spaces, no tabs, lines up to about 100 characters. No warnings of its own under `-Wall`; it also builds without warnings of its own under `-Wextra -Wno-unused-parameter -Wno-sign-compare`. The only warnings are Kismet's own, from `capture_framework.h`, which Kismet's build turns off with `-Wno-unused-function`. |
| `kismet/`, portability | C | No new libraries: the source needs only a serial port, which is why `configure` has no test for it. `add-to-kismet.sh` adds it to Kismet's build on every platform, so Linux-only parts stay optional: `<sys/sysmacros.h>` is included only on Linux, and without sysfs the helper asks for the port by name. |
| `esp32c5_kismet/` | Python | The standard library plus the three packages in `requirements.txt` (pyserial, msgpack, websocket-client); a new dependency needs a good reason. It runs from the repository root without being installed, on Windows and on POSIX alike, so port handling needs a test on both. 4 spaces, lines up to about 120 characters. |
| `firmware/` | C, ESP-IDF 5.5 | One source file. The native USB port carries only the capture stream and the host's commands; logs go to UART0. One radio per boot. Nothing transmits except `TXTEST`. Build-time options go in `Kconfig.projbuild`. |
| `tests/*.sh`, `docker/entrypoint.sh`, `kismet/add-to-kismet.sh` | POSIX sh | `#!/bin/sh` and no bash features: the entrypoint runs under dash. LF line endings, which `.gitattributes` enforces. |

### Messages

A message the user sees says what happened and what to do about it, in plain words. For example, the C helper's message when no board is plugged in:

```text
no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition
```

Where the two helpers report the same thing, make the texts match. A board already in use, for example, gives `... is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time` from either one.

### Tests

Each test is a plain script. A small `check` function prints `PASS <name>` or `FAIL <name>`, and a clean run ends with `ALL OK`. This holds for the Python files, the C harness and the shell scripts alike. Add your case in the same way, next to the cases it belongs with. The tests never open a port of the machine they run on: they use the fake board, or a fake of their own. Keep it that way, so that nobody's boards are reset by a test run.

## Licences

| Part | Licence | Why |
|---|---|---|
| Everything outside `kismet/`: the firmware, the Python remote helper, the fake board, the tests, the Docker files | MIT ([LICENSE](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/LICENSE)) | The project's own licence, the same as esp32c5-wireshark-sniffer's |
| `kismet/` | GPL-2.0-or-later ([kismet/COPYING.md](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/kismet/COPYING.md)) | It is written to become part of Kismet, which is GPL-2.0-or-later, and the C helper links against Kismet's capture framework. Each C file and header carries Kismet's licence header; `add-to-kismet.sh` has an SPDX line. |
| The Docker image | GPL-2.0-or-later | It contains Kismet. The image is labelled `org.opencontainers.image.licenses=GPL-2.0-or-later`. |

What this means for a contribution:

- A change is contributed under the licence of the files it changes: MIT, or GPL-2.0-or-later in `kismet/`. <!-- VERIFY: OWNER: is "under the licence of the files it changes" the whole of the terms, or do you want a CLA or a Signed-off-by line? (decide, then remove) -->
- A new C file or header in `kismet/` starts with Kismet's licence header, as the others do. A new script there carries the line `# SPDX-License-Identifier: GPL-2.0-or-later`, as `add-to-kismet.sh` does.
- Code from Kismet, or from `kismet/`, cannot be copied into the MIT parts.
- [CREDITS.md](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/CREDITS.md) says that everything in the repository was written for it, except where a file says otherwise. If you bring in code from elsewhere, three things are needed:
  - its licence must allow it in that part of the repository;
  - the file must say where the code came from;
  - CREDITS.md must name the source.

## Moving the Kismet side into Kismet

`kismet/datasource_esp32c5.h` makes the Kismet server understand the source type `esp32c5`. `kismet/capture_esp32c5/` is the C helper. Both are written to become part of Kismet itself, which is why they are GPL, and why the helper is built the way Kismet builds its own capture helpers.

No Kismet release has them yet. `add-to-kismet.sh` copies them into a Kismet source tree at commit cfe427074. It then makes the edits a merge into Kismet would make:

- it registers the source type in `kismet_server.cc`;
- it adds the build and install rules to `Makefile.in`;
- it adds the helper to `configure.ac`;
- it adds the helper binary to `.gitignore`.

The Docker image is built the same way. The source has not been merged into Kismet. <!-- VERIFY: OWNER: has the esp32c5 source been offered to Kismet upstream (a pull request or a mail)? If so, add the link and its state; if not, the sentence stands (decide, then remove) -->

What this means for a change to `kismet/`:

- Write it as a change to Kismet: Kismet's conventions, Kismet's capture framework, Kismet's licence. Nothing in `kismet/` may depend on the rest of this repository.
- Add no dependency to Kismet's build.
- Keep `add-to-kismet.sh` in step with the files. It is how the source gets into a Kismet tree until Kismet has it, and its edits show what a merge has to change.
- The script also fixes six bugs in Kismet's `capture_framework.c`, which every capture helper shares: a leak of about 32 bytes per packet in `cf_commit_packet`; websocket remote capture sending in 5 s bursts; a closed websocket that could leave the helper asleep; the websocket login, which went into the request's URI and now goes in HTTP headers, with redirects refused so that it cannot follow one; libwebsockets' `rejecting message on queue depth 40` warnings; and an empty `INFO: ` line after every channel set. Each goes to Kismet as a change of its own; none is part of the esp32c5 source. The script skips each one once Kismet has it.

What it means for users once Kismet has merged it: a Kismet built from Kismet's own source would include the `esp32c5` source type and `kismet_cap_esp32c5`, with no `add-to-kismet.sh` and no pinned commit, and so could a Kismet package built from a release that has it. <!-- VERIFY: OWNER: after an upstream merge, will kismet/ and add-to-kismet.sh stay here for older Kismet versions, or go? Say which in this paragraph (decide, then remove) -->

The Python remote helper, the firmware, the fake board, the Docker files and this wiki are not part of the plan. They are this project's own, under MIT.

For Kismet itself, see [Kismet's documentation](https://www.kismetwireless.net/docs/readme/intro/kismet/).

## Firmware shared with esp32c5-wireshark-sniffer

[esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) feeds the same boards to Wireshark. This project's `firmware/` started as its firmware, and the serial stream code in the Python remote helper's `board.py` started as its `host/sniffer.py`. Both firmwares speak the same line protocol, and both store the chosen radio in the same place (NVS namespace `sniffer`, key `mode`). A board on the sibling's 1.2.0 works with both helpers of this project: on the Raspberry Pi, a board flashed with the published 1.2.0 image captured Wi-Fi, 802.15.4 and BLE through the C helper, local and remote, and through the Python remote helper. The other direction, a board on this project's firmware under the sibling's Wireshark extcap, is expected to work as well, since the protocol is the same, but has not been tried.

One earlier observation is still unexplained. Before the field test, the four boards ran a build whose app version and compile time match the 1.2.0 web-flasher image (`5cdab32-dirty`, built Sep 18 2026 12:01:24). Two of them answered `START`. The other two streamed Wi-Fi but did not answer `START` within 3 s, and both helpers wait for that answer before they read the stream. All four boards were then reflashed with this project's firmware, and passed every test after that. The published 1.2.0 image, flashed onto one of them later, answered `START` at once in every test, so the image was not the cause; what was is not known.

Older firmware from the sibling project does not work with every radio. On the test board:

- 1.0.0 answered `START` but sent no Wi-Fi at all (the board had been on 802.15.4 when flashed; cause not isolated), and it has no `MODE` command, so zigbee and btle sources fail too.
- 1.1.0 captured Wi-Fi and 802.15.4. It has no BLE and ignores `MODE BLE` without a word, so btle sources fail: the helper reports `lost sync (the board sends link type 127, not 256)` and gives up after 15 s.

If a board streams but does not answer `START`, or runs 1.0.0 or 1.1.0, flash this project's image ([Flashing the Firmware](Flashing-the-Firmware)).

The firmware here has moved on in four places. The README lists them under "Changes from the Wireshark project's firmware".

| | esp32c5-wireshark-sniffer 1.2.0 | This project |
|---|---|---|
| BLE CRC | Left at zero; flags `0x0013`, not checked, not valid | Computed; flags `0x0C13`, "CRC checked" and "CRC valid" |
| Longest command line | 63 characters | 255 characters |
| Channels in one scan list | 39: a full Wi-Fi list loses 169, 173 and 177 | All 42 |
| A list that does not fit | Cut short without a word | Refused |

When a BLE packet is not marked as CRC-checked, Kismet checks the CRC itself, and a zero CRC always fails, so it would drop every BLE packet from 1.2.0. Both helpers therefore fill in the CRC for a board on 1.2.0, and say so once.

When you change the firmware:

- Keep the protocol compatible, or change it in both projects. The Wireshark project's extcap plugin, the C helper, the Python remote helper and the fake board all send the same commands and read the same stream.
- A fix to how a radio is driven usually belongs in both projects. Say in the pull request whether it applies to the other one.
- Keep the stored radio's values (`0` Wi-Fi, `1` 802.15.4, `2` BLE), so that a board moved from one firmware to the other keeps its radio.
- `TXTEST` frames still carry the payload `esp32c5-wireshark-sniffer self test`, and it shows in captures. Changing it is cosmetic, but it changes what the other project's users see too.
- Test on boards: nothing automated runs the firmware. Build it, flash it ([Flashing the Firmware](Flashing-the-Firmware)), and run the hardware checks on [Development and Testing](Development-and-Testing).

## Credits

[CREDITS.md](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/CREDITS.md) lists where this project comes from and what it builds on. In short:

- **esp32c5-wireshark-sniffer**, where the firmware and the serial stream code started. It owes its approach to Abir Mojumder's ESP32 packet sniffer sketch and to @xdavidhu's SerialShark.
- **Kismet**, by Mike Kershaw (dragorn) and contributors. The C helper is built on Kismet's capture framework and follows the layout of `capture_freaklabs_zigbee_v2` and `capture_catsniffer_zigbee`. The Python remote helper implements Kismet's external capture protocol, version 3.
- **Espressif's ESP-IDF**: Wi-Fi promiscuous mode, the IEEE 802.15.4 driver and NimBLE.
- **radiotap**, the **IEEE 802.15.4 TAP** link type and the **Bluetooth LE link-layer pseudo-header** (LINKTYPE 256), which carry the radio metadata with each frame.
- **Wireshark**, whose BTLE dissector was used to check the advertising CRC the firmware computes.
- **msgpack**, **websocket-client** and **pyserial**, which the Python remote helper uses.

Apart from the author of esp32c5-wireshark-sniffer, where this project started, none of the people and projects named had a part in this project, and none of them endorses it. If your contribution builds on someone else's work, add them to CREDITS.md in the same pull request.
