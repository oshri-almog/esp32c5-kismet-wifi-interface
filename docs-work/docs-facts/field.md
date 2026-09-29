# Field facts: real hardware and end-to-end runs (2026-09-28)

This sheet covers what happened when the project ran on real boards and against a real Kismet today. It is for writers who cannot see the code or the logs. Every fact names its source. Times are local (IDT, UTC+3).

## Legend

- **IN FLUX**: the code has changed since the run, or is still changing (the C helper is in final review, and the Python helper is being brought to parity). Document the intended behaviour and mark it "to verify".
- **UNVERIFIED**: I could not confirm it from a log or a measurement.
- **FIXED-IN-CODE**: the field run hit a problem, and the current repo has a fix that has not yet been re-run on hardware. Treat it as IN FLUX too.
- **UPSTREAM**: Kismet's behaviour, not this project's.

### Source tags

| Tag | Where |
|---|---|
| PI-BUILD | `tasks/wlb7myqjd.output` → `result.build` (native Kismet build on the Pi) |
| PI-FLASH | `tasks/wlb7myqjd.output` → `result.flash` (backup, flash and verification of the four boards) |
| PI-HW Tn | `tasks/wlb7myqjd.output` → `result.hw.checks` (Kismet end-to-end on the Pi with real boards, tests T1-T7) |
| PI-WSL | `tasks/wlb7myqjd.output` → `result.wsl` (fake-board end-to-end in WSL Ubuntu 24.04) |
| PI-REV #n | `tasks/wlb7myqjd.output` → `result.review.findings[n]` (verified review findings) |
| WIN | `tasks/w8bmmfsqs.output` → `result.wsl` (Windows 11, Python helper, real board on COM32, Kismet in WSL2) |
| WIN-DOCKER | `tasks/w8bmmfsqs.output` → `result.docker` (same, Kismet in Docker Desktop) |
| WIN-REV Wn | `scratchpad/windows-review.txt` (verified review findings W1-W6 plus the hardware-test problems) |
| CFIX | `tasks/w871w92qk.output` (C helper fixes and their tests, WSL) |
| NOTES | `scratchpad/pi-run-notes.txt` |
| DD | `tasks/w0qe7uzyi.output` (Docker Desktop image build and smoke test; not on my reading list, but it holds the NET_ADMIN facts) |
| log:… | raw logs: `scratchpad/logs/*.log` (Windows helper runs), `scratchpad/e2e/*.log` (Kismet logs from the Pi, epoch-timestamped) |
| repo:file:line | current repo, read-only, `C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface` |

All paths under `scratchpad/` and `tasks/` are relative to `C:\Users\oshria\AppData\Local\Temp\claude\c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer\75fe8a4e-1aa2-48f3-9e8d-8f12a0275438\`.

### Timeline: which code the numbers come from

Every hardware number below was measured with code that is now out of date. Keep this in mind when you quote them.

- The Pi Kismet build and the add-to-kismet.sh run happened 12:59-14:17 (PI-BUILD), and the Pi Kismet tests ran until about 14:47 (log:e2e/t6.helper.log). The Windows tests ran 13:55-14:47 (WIN, WIN-DOCKER). All of these used the C and Python helpers as they were **before** the CFIX workflow (started about 14:45) and before the Python helper parity work.
- The boards were flashed at about 13:09 with a merged image of 1,148,560 bytes, sha256 `d9078c560fa85a94b02796f6410304cc878ce08150f2d05211d907c6aad41e56` (PI-FLASH problems[3]). The repo's current image, `firmware/build/esp32c5-kismet-merged.bin`, was built at 14:56. It is 1,148,576 bytes, sha256 `a3b97ae1e4be3d98606fed25a13fd9b54b925c0f9de00fae6b24b6b864b3a7a1` (measured now). So the boards run older firmware than the repo holds. At minimum, the older firmware has the 39-entry scan-list limit; see TS-26.
- At the time of writing, the Pi is rebuilding Kismet with the current code (the configure step passed, and `make -j4` is running, per the orchestrator). Nothing from that rebuild is in this sheet.

---

## 1. Tested hardware and environments

| What | Details | Source |
|---|---|---|
| Raspberry Pi | Raspberry Pi 4, 8 GB, Debian 13 "trixie", arm64 (aarch64), Python 3.13.5 | task brief; PI-HW T7 (Python 3.13.5 aarch64) |
| Boards | Four ESP32-C5 boards, "ESP32-C5 rev v1.0 with 8MB flash" (esptool: mfr 0x85, device 0x2017). They connect by native USB (USB-Serial-JTAG, USB ID 303a:1001) through a powered USB hub (kernel hub path 1-1.2) and appear as /dev/ttyACM0-3 | PI-FLASH boards[*].before; PI-HW checks[0] |
| Board ports on Linux | `/dev/ttyACMn`, plus stable links `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC with colons>-if00` | PI-FLASH boards[*].by_id |
| Windows PC | Windows 11. Two of the four boards, moved over from the Pi (the MACs match), appeared as **COM30** and **COM32**. Python helper with pyserial and websocket-client 1.9.2 | WIN; WIN-REV W3 (1.9.2 installed on Windows) |
| Kismet in WSL2 | Ubuntu 24.04, Kismet "2026.09.0-cfe427074" installed to /root/kismet-install, python3 3.12.3 | PI-WSL checks[2]; WIN summary |
| Kismet in Docker Desktop | `esp32c5-kismet:latest` (amd64), published on 127.0.0.1:2612 | WIN-DOCKER checks[0-1] |
| Kismet version | Commit cfe427074b7ffcfcbc055a123c1df3b3cde60d59 ("Merge branch 'shrout1-ble-uuid-manufacturer-data'"). `kismet --version` prints `Kismet 2026.09.0-cfe427074` | PI-BUILD kismet_commit, notes §6 |
| Python packages (Pi venv) | msgpack 1.2.2, websocket-client 1.9.2, pyserial (3.5 in WSL); esptool v5.4.0 in `~/esp32c5-venv` | PI-HW T6; PI-WSL summary; PI-FLASH esptool_version |
| Not tested | macOS, the BSDs, Fedora and Arch. No macOS or OpenBSD compile of the C helper | task brief; CFIX problems[1] |
| Four boards at once | **Not run.** Two boards left the Pi hub at 13:49:51 and 13:49:54 (see TS-12), so T1e (two Wi-Fi, one Zigbee and one BTLE at once) was skipped. Two runs of two sources each covered the same checks | PI-HW T1e |

Boards for traceability only (do not publish the MACs): A = 38:44:BE:BF:D8:0C (Pi ttyACM2), B = 10:BD:A3:C8:7D:54 (Pi ttyACM3), C = 38:44:BE:BF:C9:10 (Pi ttyACM0, later Windows COM32), D = 10:BD:A3:CF:05:40 (Pi ttyACM1, later Windows COM30).

---

## 2. Building Kismet with the esp32c5 source

### 2.1 Raspberry Pi 4 (native, no sudo) — PI-BUILD notes

The exact commands that ran:

```sh
git clone https://github.com/kismetwireless/kismet.git ~/src/kismet
cd ~/src/kismet && git checkout cfe427074        # detached HEAD
sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
cd ~/src/kismet && ./configure --prefix=$HOME/kismet-install --disable-python-tools \
    --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger
nohup nice make -j4 > ~/kismet-build.log 2>&1 &
make install INSTUSR=osh INSTGRP=osh SUIDGROUP=osh
```

What happened at each step:

- **add-to-kismet.sh**: it edited kismet_server.cc twice, Makefile.in four times, configure.ac five times and .gitignore once. It then ran `aclocal -I m4` and `autoconf` and printed "Done". `git status --short` afterwards showed M for .gitignore, Makefile.in, configure, configure.ac and kismet_server.cc, and ?? for capture_esp32c5/ and datasource_esp32c5.h.
  - IN FLUX: the current script also edits capture_framework.c to fix an upstream leak (CFIX fixes[6]; repo:kismet/add-to-kismet.sh:16-20). On the first run that prints "edited capture_framework.c". A second run changes nothing (md5 unchanged; CFIX tests[4]).
  - The script needs autoconf and automake (repo:kismet/add-to-kismet.sh:14-15, "apt install autoconf automake").
- **configure**: exit 0. No extra --disable flags and no packages were missing (UNVERIFIED: which apt packages had been installed on the Pi before). The summary prints **`ESP32-C5: yes`**. It also showed aarch64, libpcre2, websockets yes, libnl, libnm and "Linux HCI Bluetooth yes".
  - UPSTREAM cosmetic: the summary runs "Setuid group: kismet" and "Prelude SIEM : no" together on one line (a missing \n in upstream configure.ac).
- **make -j4**: about **78 minutes** (12:59-14:17), ending "== MAKE EXIT 0". There were no OOM kills and no need for -j2. The memory peak came with phy_80211.cc (2.4 GB), phy_80211_dissectors.cc (1.8 GB) and phy_80211_components.cc (1.7 GB) compiling at once: about 1.1 GB stayed available and about 40 MB of swap was used. The log has 76 warning lines, all in upstream files, and none from capture_esp32c5.c or datasource_esp32c5.h.
- **make install** (with INSTUSR/INSTGRP/SUIDGROUP set to the user): exit 0, and **nothing needed root**. The `install` target runs commoninstall and configsinstall only, with no setuid step and no groupadd. It installed bin/ (kismet, kismet_server, 19 kismet_cap_* helpers including kismet_cap_esp32c5, the kismetdb_* tools and kismet_discovery), etc/ (kismet*.conf), lib/ and share/.
- Installed sizes: `kismet_cap_esp32c5` 410,024 bytes, and `bin/kismet` 489,329,152 bytes (unstripped, built with -g).

### 2.2 WSL2 Ubuntu 24.04 — PI-WSL checks[0-2], CFIX tests[5]

- The build finished ("== BUILD OK").
- **Plain `make install` fails** with `/usr/bin/install: invalid group 'kismet'` (Makefile:596 commoninstall; `SUIDGROUP = kismet` is hard-set in Makefile.inc). WSL has no `kismet` group. What worked: `make install INSTGRP=root SUIDGROUP=root MANGRP=root`. The alternative is to create the group. See TS-7.
- The C helper compiles with no warnings of its own under -Wall at -O0 and -O2, and also with -Wextra (minus unused-parameter and sign-compare). The only 3 warnings come from Kismet's capture_framework.h (static ws_* functions declared but not defined), which every helper gets (CFIX tests[3]).

### 2.3 Docker Desktop image build (Windows, amd64) — DD

- The compile takes about **18.5 minutes** (JOBS=4).
- After a strip step: `esp32c5-kismet:latest` 177 MB and `:demo` 227 MB (before stripping: 895 MB and 946 MB).
- Smoke test `tests/docker_smoke.sh`: 21/21 PASS.
- The image declares `VOLUME /data` and `/root/.kismet`, so each container leaves 2 anonymous volumes unless it is removed with `docker rm -f -v` (DD file changes; WIN-DOCKER checks[9]).

### 2.4 Exit codes that look like failures but are not (UPSTREAM) — PI-BUILD problems[2]; DD

- `kismet --version` prints `Kismet 2026.09.0-cfe427074` and **exits 1** (kismet_server.cc:569).
- `kismet_cap_esp32c5 --help` prints the full capture-framework usage and **exits 255**.
- `kismet_cap_esp32c5 --list` writes its list **to stderr** and **exits 2** (`cf_handler_list_devices()`, then `exit(KIS_EXTERNAL_RETCODE_ARGUMENTS=2)`).
- The helper's `--help` lists: --connect, --tcp, --ssl, --user/--password/--apikey, --endpoint, --source, --list, --autodetect, --version (PI-BUILD notes §6).

---

## 3. Flashing the boards — PI-FLASH

### 3.1 What ran

All commands used esptool v5.4.0, with the board addressed by its /dev/serial/by-id path:

```sh
esptool --chip esp32c5 -p <by-id> read-flash 0 ALL <backup>.bin        # 8,388,608 bytes, 61-86 s per board
esptool --chip esp32c5 -p <by-id> verify-flash 0x0 <backup>.bin        # "Verification successful (digest matched)"
esptool --chip esp32c5 -p <by-id> write-flash 0x0 esp32c5-kismet-merged.bin
#   1,148,560 bytes written, "Hash of data verified", then esptool hard-resets the board
# To restore:
esptool --chip esp32c5 -p <by-id> write-flash 0x0 ~/esp32c5-flash-backup/<MAC>.bin
```

- The merged image lives at **`firmware/build/esp32c5-kismet-merged.bin`**, not at `firmware/esp32c5-kismet-merged.bin` (PI-FLASH problems[3]; confirmed in the repo now).
- The merged image covers 0x0-0x118fff, NVS included. **Flashing it erases the stored radio, so every board comes up in Wi-Fi** (PI-FLASH notes). See 4.2.
- All four boards were backed up, flashed and verified. Every per-board test and all 12 cross-board 802.15.4 pairs passed, and every board was left in MODE WIFI.

### 3.2 What was on the boards before

All four boards ran the sibling project's older app: `esp32c5_sniffer`, "App version 5cdab32-dirty", ESP-IDF v5.5.5, compiled Sep 18 2026 12:01:24, validation hash c7d1c273…

- Boards C and D answered `START <us> <nonce>` with `<<START>> <nonce>`.
- Boards A and B streamed Wi-Fi radiotap PCAP (113-121 KB in 3 s) but **did not answer START within 3 s** (no `<<START>>` at all). The docs should say: a board on older firmware may stream and still ignore START, so flash the current image. The sibling repo's recent commit "Explain the board that prints <<START>> and then goes quiet" (task git log) covers the same symptom.

### 3.3 Windows esptool on a wedged port — log:tasks/bu10kjjtz.output

esptool v4.12.0 on COM30 failed with:

```
A fatal error occurred: Could not open COM30, the port is busy or doesn't exist.
(Cannot configure port, something went wrong. Original message: PermissionError(13, 'A device attached to the system is not functioning.', None, 31))
```

See TS-1.

---

## 4. How the boards behave (firmware, measured)

### 4.1 Radio switch = reboot, and the USB port stays

- Each `MODE` change reboots the chip. The boot header (`\n<<START>>\n` plus a PCAP global header with the new link type) arrives **0.53-0.54 s** after the MODE line, on every board (PI-FLASH boards[*].zigbee_evidence / wifi_evidence).
- **The USB port did not disappear on this hardware.** The read never failed, the by-id links kept their 12:35 creation time, and ttyACM0-3 kept their numbers, even across esptool hard resets (PI-FLASH problems[0]).
  - PI-HW T3 also says: "The board's USB port never disappeared during the switches."
- A START sent within about 0.5 s of MODE is lost in the reboot. The helpers now wait `MODE_SETTLE_S = 0.8` s between MODE and START (repo:kismet/capture_esp32c5/capture_esp32c5.c:159-162; repo:esp32c5_kismet/board.py:64-67). IN FLUX: not re-measured on hardware; the fake-board e2e passed "no START lost in the reboot" (CFIX fixes[12], tests[11]).
- The C helper's header still says the port "can also go away" (repo:capture_esp32c5.c:65-72), and the fake board has a `--vanish` mode for that. Neither the Pi nor Windows showed it, apart from the reset described in 4.3.
- `MODE` for the radio already running costs nothing: no reboot (repo:firmware/main/esp32c5_sniffer.c:793-795; PI-FLASH boards[1]: "MODE WIFI caused no reboot").

### 4.2 Boards remember their radio

- The firmware saves the chosen radio in NVS and boots into it. A board that has never been told anything boots Wi-Fi (repo:firmware/main/esp32c5_sniffer.c:771-813 MODE handler, :1223-1257 load_mode/save_mode).
- Flashing the merged image erases NVS, so a freshly flashed board boots Wi-Fi (PI-FLASH notes).
- User-visible result: the first source after a board last used another radio pays the reboot. Measured with the pre-CFIX C helper, 'launched successfully' to 'capturing' took **1.50 s** when the board had to switch and **0.50 s** when it was already on the requested radio (PI-HW T3; log:e2e/t2.log 1790595507.76 → 508.26 = 0.50 s).
- Only one radio runs at a time. Two sources for different radios on one board make it reboot back and forth (WIN-REV W6). This is now refused; see TS-25.

### 4.3 DTR/RTS reset the board

- On Windows, opening a COM port with pyserial's defaults raises DTR and RTS, which drive reset and boot mode on these boards. After such an open, COM30 and COM32 **both briefly disappeared** (`FileNotFoundError`), probably a reset (WIN com30_status).
- The helpers open with DTR and RTS low. On Windows both are set before open; on POSIX RTS is cleared before DTR after open, because the reverse order resets the chip (repo:esp32c5_kismet/board.py:372-411).
- The Pi flashing scripts released RTS before DTR (PI-FLASH notes).
- Advice for the docs: serial monitors and scripts should not open the port with default DTR/RTS.

### 4.4 Stream facts

- The START answer comes back in about 0.11 s: `<<START>> <nonce>`, then PCAP magic a1b2c3d4 v2.4 (WIN-DOCKER checks[9]).
- Link types from the board: Wi-Fi 127 (radiotap, every record with the firmware's 16-byte radiotap header), 802.15.4 283 (TAP), BLE 256 (LE LL with PHDR) (PI-FLASH boards[*]).
- Wi-Fi on channel 6 (2437 MHz): 410-778 records in 8 s per board. With `DWELL 150` and a 77-character CHANNELS list (1-14, 36-64, 100, 104, 108), 700-1010 records came in 15 s from 15-19 distinct frequencies, none outside the list (PI-FLASH boards[*]).
- Nothing lost sync during flashing verification (PI-FLASH notes).

### 4.5 802.15.4 over the air (TXTEST)

- `TXTEST <n>` sends n 802.15.4 frames and works **only in 802.15.4 mode** (firmware log "TXTEST only works in 802.15.4 mode"). The count is 1-1000; anything else, or no count, gives 10 (repo:firmware/main/esp32c5_sniffer.c:814-826).
- Frame: fc 0x8841 (data, PAN ID compressed, short addresses), destination PAN 0x1234, destination 0xffff (broadcast), source 0x0001, payload `esp32c5-wireshark-sniffer self test\0`, sequence number = index (repo:firmware/main/esp32c5_sniffer.c:826-839; PI-FLASH notes).
- Cross-board test: all four boards in MODE 802154 on channel 20, each board in turn receiving `TXTEST 50` from each of the other three. **All 12 pairs gave 50/50** (150 per receiver, 600 in total), with 50 distinct sequence numbers, TAP channel TLV 20 and RSS between -7 and +9 dBm (PI-FLASH boards[*].zigbee_evidence, notes).
- On channel 15 with no Zigbee or Thread equipment nearby: 0 frames in 8 s on every board. This is expected (PI-FLASH).
- Into Kismet: **200/200**. See 5.2.

### 4.6 BLE advertising

- All **757/757** BLE records across the four boards had valid CRCs and flags: 286 + 106 + 99 + 266. The check: a 10-byte pseudo-header, flags containing 0x0C00, access address 0x8E89BED6, a length consistent with the PDU header, and the CRC recomputed with the reflected LFSR (PI-FLASH boards[*].ble_*, notes).
- On Windows, all 74 records read straight from COM32 had PHDR flags **0x0C13** (bit 10 CRC checked, bit 11 CRC valid) (WIN checks[8]).
- **Every BLE record carries rf_channel 0** (the RF index of advertising channel 37), although the passive scan covers 37, 38 and 39. So Kismet (and Wireshark) label every advert as channel 37 / 2402 MHz (PI-FLASH problems[2]; WIN problems[5]; repo:firmware/main/esp32c5_sniffer.c:213, :609). See TS-9.
- The CRC is valid for the PDU **as rebuilt from the HCI report**. The firmware cannot recover the ChSel header bit (bit 5), so for BLE 5 advertisers that set ChSel in ADV_IND/ADV_DIRECT_IND, the recorded header byte and CRC differ from what an nRF Sniffer or Ubertooth would record. ADV_NONCONN_IND, ADV_SCAN_IND and SCAN_RSP are unaffected (PI-REV #18, severity low). The docs should not call it the "real on-air CRC".
- Older firmware (the sibling project's published 1.2.0 / 7f260d4) sends BTLE flags 0x0013 and three zero CRC bytes, and Kismet silently drops those packets: the source counts packets but no BTLE devices appear, and there is no error (PI-REV #10). The helpers now fill in the CRC and flags and say so once (see TS-19).

---

## 5. What Kismet shows, per radio (measured)

### 5.1 Wi-Fi

| Run | Duration | Packets | Devices | 5 GHz | Source |
|---|---|---|---|---|---|
| Pi, two local sources by by-id path (C helper) | 242.7 s, 243 REST polls, zero error/not-running samples | 8801 + 10242 | 244 Wi-Fi devices (seen by the two sources: 170 and 183) | 16 devices on ch 36, 40, 48, 100 (109 on 2.4 GHz ch 1-11 and 13) | PI-HW T1c |
| Pi, remote C helper over websocket | 60 s | 3473 | 100 Wi-Fi devices | 15 on ch 36/40/48/100 | PI-HW T5 |
| Pi, Python helper, 2 sources in one process | 75 s | Wi-Fi 2711 | 127 Wi-Fi devices | 19 on ch 36, 40, 48, 52, 100, 149, 157 | PI-HW T6 |
| Windows → Kismet in WSL (Python helper, COM32) | about 3 min | 233 → 9900 | 128 IEEE802.11 devices, 60 on 2.4 GHz channels | 4 devices with packets on 5 GHz; AP 'osvc-52' ch 48 (5240 MHz) | WIN checks[2-4] |
| Windows → Docker Desktop, login | about 2.5 min | 6249, 0 error packets | 128 | AP 'osvc-52' ch 48; two APs on ch 52 / 5260 MHz ('cohen'); 11 devices on 5 GHz by the end of step 2 | WIN-DOCKER checks[2-3] |
| Windows → Docker Desktop, API key | about 90 s | 9988 → 15032 | 179, 11 on 5 GHz | — | WIN-DOCKER checks[5] |

- Frequencies seen:
  - Pi: the channel tracker saw 2412-2484 MHz and 5180/5200/5220/5240/5280/5300/5500/5745-5825 MHz (PI-HW T1c).
  - Windows: 21 frequencies within a minute (2412-2472 plus 5180, 5200, 5220, 5240, 5280, 5765, 5785, 5825 MHz) (WIN checks[3]).
- 5 GHz examples by SSID, for the docs: 'osvc-52' ch 48 / 5240 MHz; 'Cudy-C223-5G' ch 40; 'MEIRAV' ch 100 / 5500 MHz; 'Dayan' ch 36 (PI-HW T1c). UNVERIFIED whether publishing neighbours' SSIDs is wanted; use generic wording instead.
- Hopping as Kismet reports it (PI-HW T1b; WIN checks[3]):
  - hopping=1, hop_rate=5 (5 hops/s), hop_shuffle=1, hop_shuffle_skip=4.
  - 42 hop channels: **1-14, 36-64, 100-144, 149-177**.
  - The helper writes `CHANNELS n` every 200 ms.
- **`kismet.datasource.channel` stays at '6' while hopping.** This is UPSTREAM behaviour: the helper hops the board itself and does not report each hop (PI-HW T1b; WIN checks[3]).
- Two sources of the same type share out the channels. The Kismet log says "Splitting channels for interfaces using 'esp32c5' among 2 interfaces", with hop_offset 21 and 0, and the two boards are never on the same channel at once. UPSTREAM detail: after the first pass the two drift to only 5 positions apart instead of 21 (PI-HW problems[5]; NOTES).
- Channel lock through REST works: `set_channel.cmd {"channel":"48"}` put all 287 new packets in the next 20 s on 5240 MHz, and `set_hop.cmd` spread packets over 2.4 and 5 GHz again within 20 s (WIN-DOCKER checks[6]).
- Source record, as seen in the field (WIN checks[1]): name, uuid `E5C50001-0000-0000-0000-<MAC>`, running=1, error=0, remote=1, type=esp32c5, hardware `ESP32-C5 (<MAC>)`, interface `esp32c5-COM32`, capif `COM32`, dlt 127.
  - **IN FLUX**: the hardware string is now `Espressif USB-Serial-JTAG (<MAC>)`, or `ESP32-C5` when there is no MAC (repo:capture_esp32c5.c:488-496; repo:remote.py:226-228). The C helper's capif is now `esp32c5-<tty>`, e.g. `esp32c5-ttyACM0` (repo:capture_esp32c5.c:1421-1429; CFIX fixes[8]).

### 5.2 IEEE 802.15.4 (Zigbee / Thread)

- A Zigbee source starts on channel **'15'** and hops **11-26** (16 channels) at 5/s (PI-HW T1d; WIN checks[9]).
- With nothing transmitting nearby: **0 packets**, as expected (PI-HW T1d; WIN checks[9]).
- **Over the air into Kismet** (PI-HW T2): board B sent `TXTEST 200` on channel 20 while the Kismet source (board A) was on channel 20. Result: **`num_packets=200`, 200/200**.
  - Kismet showed 802.15.4 device **00:01** (200 packets, tx_total 200, channel 20, frequency 2450000 kHz, signal +9 dBm) and device **FF:FF** (rx_total 200). Log lines: "Detected new 802.15.4 device 00:01" and "Detected new 802.15.4 device FF:FF".
  - Kismet's live `/pcap/all_packets.pcapng` held the frames as **link type 230** (802.15.4 without FCS) with the expected fc, PAN, addresses and payload.
  - **Kismet's 802.15.4 device record has no PAN field.**
  - The source was tuned to 20 with REST `POST /datasource/by-uuid/<uuid>/set_channel.cmd` and body `{"channel":"20"}`, because channel= in the definition was ignored at the time (see TS-10). Kismet logged "Source 'c5-zb20' (…) setting channel 20" (log:e2e/t2.log).
- Fake board, for the demo docs: the fake's 802.15.4 devices appear as 10:01, 25:01 and FF:FF (PI-WSL checks[12]).

### 5.3 Bluetooth LE advertising

| Run | Packets | Devices | Named | Source |
|---|---|---|---|---|
| Pi local, 150 s | 2969 | 17-18 BTLE devices | 'net' (GD Midea), 'tcl_AC_t*ap_szkt'; also Samsung, LG Innotek and randomized addresses | PI-HW T1d |
| Pi, Python helper, 75 s | 1274 | 15 | 1 ('tcl_AC_t*ap_szkt') | PI-HW T6 |
| Windows → WSL, about 3 min | 97 at +6 s; 3443 by the end | 16 | 1 ('tcl_AC_t*ap_szkt'); the rest random addresses | WIN checks[6-7] |

- The hop list is just **['37']**, i.e. hop_channels(1)=37 (PI-HW T1d; WIN checks[6]).
- **Every BTLE device shows channel 37 / 2402 MHz**, and **per-device packet counts stay at 1-3** while the source counts about 20 packets/s. See TS-9.
- Kismet error packets: 0 (WIN checks[8]).
- Fake board, for the demo docs: BTLE device C6:00:00:C5:E5:5A named **'ESP32C5-FAKE'** (PI-WSL checks[15]).

---

## 6. Timings (all measured; pre-fix code, see Timeline)

| What | Value | How measured | Source |
|---|---|---|---|
| Board reboot after MODE (another radio) | 0.53-0.54 s | MODE line → boot header | PI-FLASH |
| Local source, board already on the radio | 0.50 s | Kismet "launched successfully" → "capturing" | PI-HW T3; log:e2e/t2.log |
| Local source, radio switch (Wi-Fi→Zigbee, Wi-Fi→BTLE, Zigbee→Wi-Fi) | 1.50 s each | same | PI-HW T1d, T3; log:e2e/t1mix.log, t3.log |
| Local Wi-Fi, first packets after Kismet start | 1.7 s (B), 2.7 s (A) | Kismet start → first packet | PI-HW T1c |
| Local helper killed (SIGKILL) → Kismet re-opens | error at +0.0 s; "Attempting to re-open" at +5.8 s; capturing at +6.4 s | Kismet log | PI-HW T4; log:e2e/t3.log 641.07 → 646.90 → 647.42 |
| Remote C helper over websocket, connect → "capturing" in Kismet | 2.96 s, 3.63 s, 5.38 s (three sessions) | Kismet log "connected"/"reconnected" → "capturing" | PI-HW T5; log:e2e/t5.log lines 62-63, 209-210, 239-240 (the third is my computation) |
| Remote C helper over websocket, packet count | 0 → 24 (+3.5 s) → 461 (+6.0 s), bursty | REST polls | NOTES (PI-REV websocket finding) |
| Remote C helper over legacy TCP (`--tcp`, port 3501) | capturing at +0.51 s, packets from +0.9 s | same | PI-HW T5; log:e2e/t5.log 893.05 → 893.56 |
| Remote Python helper over websocket (Pi), board on the radio | +0.35 s (Wi-Fi); +0.34/0.36 s on a rerun | helper "connected" → "capturing" | log:e2e/t6.helper.log, t6.log |
| Remote Python helper (Pi), BTLE with a radio switch | +1.22 s | same | PI-HW T6 |
| Remote Python helper (Windows, `--connect localhost:2501`), launch → capturing | about 2.5 s, of which about 2 s is the IPv6 attempt | launcher timestamp → helper log | WIN checks[5]; log:logs/t2wifi.log |
| Windows Wi-Fi→BTLE switch through the Python helper | "opened" 14:05:08 → "capturing" 14:05:09 (≈1 s, 1 s log resolution) | helper log | log:logs/t3btle.log |
| Python helper reconnect after Kismet restart (Windows→WSL) | about 7 s after Kismet listens again (5 s backoff + 2-4 s IPv6); retries 7-9 s apart | helper log + REST | WIN checks[12]; log:logs/t5restart.log |
| Python helper reconnect after `docker restart` | 7 s (14:44:41 ended → 14:44:48 connected) | helper log | WIN-DOCKER checks[7] |
| Remote C helper restarted → Kismet reuses the source | capturing +3.6 s, packets +3.9 s | Kismet log | PI-HW T5 |
| Ctrl+C → Python helper exit (Windows, console Ctrl+C) | 0.17-0.56 s, exit 0, in 7 of 8 attempts (the run summary says "0.23 to 0.54 s … 6 of 7"; my figures come from the listed timestamps: 0.24, 0.44, 0.17, 0.23, 0.56, 0.54, 0.47 s, plus the one failure) | CTRL_C_EVENT → exit | WIN checks[14], problems[1] |
| SIGINT → Python helper exit (Pi) | 0.21 s, exit 0 | kill -INT | PI-HW T6 |
| Remote helper killed → Kismet marks the source in error | immediate (SIGKILL); within 0.04 s (SIGTERM) | Kismet log | PI-HW T5 |
| Windows `localhost` connect to WSL-forwarded Kismet | 2.067 s via localhost; 0.001 s via 127.0.0.1; ::1 refused after 2.050 s | socket.create_connection | WIN problems[3] |

---

## 7. Remote capture: what worked, with the exact commands

### 7.1 Commands used

Python helper, Windows (log:logs/*.start; scratchpad/launch.py):

```
python -m esp32c5_kismet.remote --list
python -m esp32c5_kismet.remote --connect localhost:2501 --user <u> --password <p> --debug \
    --source esp32c5-COM32:mode=wifi,name=win-wifi
# BTLE:   --source esp32c5-COM32:mode=btle,name=win-btle
# lock:   --source esp32c5-COM32:mode=zigbee,name=win-zigbee,channel_hop=false,channel=20
# two:    --source esp32c5-COM32:mode=wifi,name=win-wifi --source esp32c5-COM30:mode=btle,name=win-com30-btle
```

Python helper, Pi, two sources in one process (PI-HW T6):

```
python -m esp32c5_kismet.remote --connect localhost:2501 --user test --password ... \
    --source 'esp32c5-ttyACM2:mode=btle' --source 'esp32c5:device=<B by-id>,mode=wifi'
```

C helper as a remote source (PI-HW T5; PI-WSL checks[17-18]):

```
kismet_cap_esp32c5 --connect localhost:2501 --user test --password ... \
    --source 'esp32c5:device=<B by-id>,mode=wifi,name=remote-c'
kismet_cap_esp32c5 --connect localhost:3501 --tcp --source ...     # legacy TCP, no login
```

Local sources (Kismet -c) on the Pi (PI-HW T1a; log:e2e):

```
kismet --homedir <dir> --no-ncurses --no-logging \
  -c 'esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00,mode=wifi,name=c5-wifi-a'
```

- By-id paths with colons work inside a definition, because Kismet splits only at the first ':' (PI-HW T1a).
- `esp32c5-ttyACM2:mode=wifi` works too (PI-HW T1a, run t8).

Docker Desktop server (WIN-DOCKER checks[1]):

```
docker run -d --name esp32c5-wintest -p 127.0.0.1:2612:2501 -e KISMET_USER=wintest -e KISMET_PASSWORD=... \
    -e ESP32C5_DEMO= esp32c5-kismet:latest kismet --no-logging
```

- The log said 'HTTP server listening on 0.0.0.0:2501'.
- `/system/status.json` returned 200 with the login and 401 without it.
- `/datasource/types.json` lists 'esp32c5'.
- For the demo (no hardware): `docker compose --profile demo up demo`, then http://localhost:2501 with login demo / demo (repo:compose.yaml:1-11).

### 7.2 Authentication

- A login (`--user/--password`) and an API key (`--apikey`) both worked against Docker (WIN-DOCKER checks[2], [5]).
- An API key was created over REST: `POST /auth/apikey/generate.cmd` with `{"name":"wintest","role":"datasource","duration":0}` → HTTP 200 and a token. `/auth/apikey/list.json` showed role datasource, expiration 0 (WIN-DOCKER checks[4]).
- **A datasource-role key gets 401 on `/datasource/all_sources.json`.** This is expected, since the role only allows remote capture (WIN-DOCKER checks[4]).
- The key survived `docker restart`. It is kept in `/root/.kismet/session.db` on the container's volume (WIN-DOCKER checks[7]).
- IN FLUX: both helpers now also take the login from the environment: `KISMET_CAP_APIKEY`, or `KISMET_CAP_USER` + `KISMET_CAP_PASSWORD`. That keeps it out of the process list (repo:remote.py:28-30, :1067-1082; repo:capture_esp32c5.c:82-85, :1498-1506; CFIX fixes[11]). Not used in the field runs.

### 7.3 Source identity across reconnects

- The UUID is **`E5C5000M-0000-0000-0000-<MAC without colons>`**, where M = 1 for Wi-Fi, 2 for Zigbee and 3 for BTLE (field UUIDs: E5C50001-…-3844BEBFC910, E5C50002-…, E5C50003-…; repo:remote.py:219-223).
- When the helper reconnects with the same UUID, Kismet reuses the source and logs:
  - `Matching new remote source '<definition>' with known source with UUID '<uuid>'`
  - `Remote source <name> (<uuid>) reconnected`

  (log:e2e/t5.log 208-209; WIN-DOCKER checks[5]).
- A new UUID logs `New remote source <name> (<uuid>) connected` (log:e2e/t5.log 62).
- Kismet matches remote sources **by UUID only**, and it never removes an old source: a source in error stays listed (WIN-REV W1, W4; Kismet datasourcetracker.cc ~1683-1757). This is why a changing UUID leaves a duplicate source; see TS-16.

### 7.4 Messages seen in the field (exact text)

Python helper log (log:logs/t2wifi.log, t5restart.log, t6two.log):

```
13:58:30 INFO: esp32c5-COM32:mode=wifi,name=win-wifi: connected, offering it to Kismet as E5C50001-0000-0000-0000-3844BEBFC910
13:58:30 INFO: esp32c5-COM32:mode=wifi,name=win-wifi: opening COM32 for wifi
13:58:30 INFO: COM32 opened
13:58:30 INFO: COM32 capturing
14:08:08 INFO: stopping
14:08:08 INFO: esp32c5-COM32:mode=btle,name=win-btle: connection ended: stopped
14:14:28 INFO: …: connection ended: Connection to remote host was lost.
14:14:37 ERROR: …: [WinError 10061] No connection could be made because the target machine actively refused it
14:29:49 ERROR: esp32c5-COM30:mode=btle,name=win-com30-btle: the board on COM30 has not been capturing for 15 s
```

Kismet log (log:e2e/*.log):

```
INFO: Found type 'esp32c5' for 'esp32c5:device=…,mode=zigbee,name=c5-zigbee'
INFO: Data source 'esp32c5:device=…' launched successfully
INFO: c5-zigbee capturing (zigbee)                               (local source)
INFO: remote-c - remote-c capturing (wifi)                       (remote C helper)
INFO: esp32c5 - /dev/serial/by-id/… capturing                    (remote Python helper)
ERROR: Data source 'c5-switch / esp32c5:…' ('esp32c5') encountered an error: IPC connection closed
ALERT: SOURCEERROR Source c5-switch (E5C50001-…) has encountered an error (IPC connection closed) Kismet will attempt to re-open the source in 5 seconds.  (1 failures)
INFO: Attempting to re-open source c5-switch
ALERT: SOURCEOPEN Source c5-switch (E5C50001-…) successfully re-opened
ERROR: Data source 'remote-c / …' ('esp32c5') encountered an error: websocket connection closed
```

- A remote helper over legacy `--tcp` that goes away shows as "IPC connection closed", not "websocket connection closed" (log:e2e/t5.log line 262, the end of the --tcp session).
- Kismet start-up lines worth knowing (log:e2e/t1mix.log):
  - "Launching remote capture server on 127.0.0.1 3501": legacy TCP, loopback only by default.
  - "HTTP server listening on 0.0.0.0:2501"
  - "Setting default channel hop rate to 5/sec"
  - "Sources will be re-opened if they encounter an error"
  - "Data sources passed on the command line (via -c source), ignoring source= definitions in the Kismet config file."

### 7.5 Stopping

- Ctrl+C in a console: "INFO: stopping", then "connection ended: stopped", exit 0 within about 0.2-0.6 s (WIN checks[14]; see the table in section 6).
- The COM port is released at once, and a new open of COM32 succeeds straight away. While the helper runs, a second open gets "Access is denied" (WIN checks[15]).
- Kismet then shows the source running=0, error=1, reason **'websocket connection closed'**. The C capture tool gives the same, so this is expected (WIN checks[16]; WIN-DOCKER checks[8]).
- UPSTREAM display quirk: after a later reconnect, Kismet keeps showing the old error text while running=1 (WIN checks[16]). After a local re-open, REST shows retry_attempts=1 and a stale error_reason with error=0 (PI-HW T4).

---

## 8. Troubleshooting entries

Format: **Symptom** (what the user sees, with exact text where known) / **Cause** / **Fix** / **Status** / Source.

### TS-1 Windows: a board fails with error 31, "A device attached to the system is not functioning"

- **Symptom:**
  - The Python helper logs, about once a second, alternating:
    - `COM30 opened`
    - `COM30: Write timeout`
    - `COM30: Cannot configure port, something went wrong. Original message: PermissionError(13, 'A device attached to the system is not functioning.', None, 31)`
  - After 15 s it logs `ERROR: …: the board on COM30 has not been capturing for 15 s`, and it repeats about every 22 s.
  - esptool says `Could not open COM30, the port is busy or doesn't exist.` with the same PermissionError 31.
  - The port is still listed (`--list` still shows `COM30  10:BD:A3:CF:05:40`), but it cannot be opened, or opens and does not answer START within 3 s.
  - The episode lasted from about 13:55 to 14:31 with brief good moments. The port also flapped in the Docker test: fine at 14:34, error 31 at about 14:40, fine at about 14:47.
- **Cause:** the Windows USB device for that board is in a bad state. The same board (D) had passed every test on the Pi an hour earlier, so the firmware and hardware are fine. The trigger was probably an earlier open with pyserial's defaults, which raise DTR and RTS and reset the chip; right after one, COM30 and COM32 briefly vanished (`FileNotFoundError`) (WIN com30_status). UNVERIFIED: the exact trigger.
- **Fix:** unplug the board and plug it back in (or power-cycle the hub). The Windows run recommended "It needs a re-plug or power-cycle", and the WIN-REV W5 verifier later noted "COM30 itself opens fine again now". The orchestrator reports that a replug fixed it; that fix is not recorded in the logs I read (UNVERIFIED in logs). Other sources in the same helper are unaffected: COM32 kept capturing, with 2952 packets at 14:30:21 (WIN checks[13]).
- **Status:**
  - In the field version of the Python helper, Kismet showed the wedged source as running with 0 packets for about 15 s of every ~22 s cycle, and its status lines crowded Kismet's message log (28 of the last 50 messages in 30 s) (WIN problems[4]; WIN-REV W5).
  - **FIXED-IN-CODE / IN FLUX:** the helper now tries the port first (waiting up to `FIRST_OPEN_WAIT_S = 2.0` s). If the open fails, it answers Kismet's open with a failure carrying the OS error, so the reason shows in Kismet's error_reason (repo:remote.py:77, :746-774). Repeated identical errors go to Kismet at most once every `STATUS_REPEAT_S = 10` s, with a count "(N more times in the last S s)" (repo:remote.py:78, :903-915). The no-capture timeout reason now appends "(last: <last status>)" (repo:remote.py:707-710).
  - Also see TS-16: while the board is unplugged, its source identity must not change.
- Sources: WIN com30_status, checks[11], [13], problems[4]; WIN-DOCKER com30_status; log:logs/t6two.log; tasks/bu10kjjtz.output.

### TS-2 Windows: every connection to Kismet in WSL or Docker takes 2 s more than it should (`localhost`)

- **Symptom:** `--connect localhost:2501` takes about 2 s to connect. A refused attempt (Kismet not up yet) takes about 4 s, so reconnects come 7-9 s apart instead of about 5 s.
- **Cause:** Windows resolves `localhost` to `::1` first, and it retries a refused TCP connect for about 2 s. WSL's port forwarder (wslrelay.exe) listens only on 127.0.0.1:2501, so ::1 is refused.
  - Measured: `create_connection(('localhost',2501))` took 2.067 s and ended on 127.0.0.1; `('127.0.0.1',2501)` took 0.001 s; `('::1',2501)` was refused after 2.050 s.
- **Fix:** use `--connect 127.0.0.1:2501` in Windows examples.
- **Status:** FIXED-IN-CODE / IN FLUX. The Python helper now tries 127.0.0.1 before ::1 for `localhost` (repo:remote.py:1027-1031). It has not been re-measured on Windows. The docs can still recommend 127.0.0.1.
- Source: WIN problems[3], checks[5], [12].

### TS-3 Windows / Git Bash: the helper will not stop (kill -INT, taskkill)

- **Symptom:** the helper was started as a Git Bash background job (`python … &`).
  - `kill -INT <pid>` had no effect: PONG lines kept coming.
  - `taskkill //PID <pid>` gave `ERROR: … This process can only be terminated forcefully (with /F option).`
  - A console Ctrl+C event was also ignored.
- **Cause:**
  - Windows passes the "ignore Ctrl+C" attribute from a parent to its children, and this shell starts background jobs with it set: a Python process started from it had ConsoleFlags=0x1.
  - A test script got "not interrupted" from kill -INT, but got a KeyboardInterrupt once `SetConsoleCtrlHandler(NULL, FALSE)` had cleared the flag.
  - taskkill without /F only sends WM_CLOSE, and a console program has no window to receive it.
- **Fix, for the docs:** run the helper in an ordinary console window (Windows Terminal, PowerShell, cmd) and press **Ctrl+C**. On Windows, **Ctrl+Break** also stops it. For a background job, a force kill is safe: `taskkill /F /PID <pid>` freed COM32 at once, and Kismet showed reason 'websocket connection closed'.
- **Status:** FIXED-IN-CODE / IN FLUX. The helper now handles SIGINT, SIGTERM and SIGBREAK through an event, and on Windows it calls `SetConsoleCtrlHandler(None, False)` at startup to clear an inherited "ignore Ctrl+C" (repo:remote.py:1085-1114; the docstring at :29-30 says "Ctrl+C, Ctrl+Break (Windows) or SIGTERM stop the helper"). UNVERIFIED on Windows: whether Git Bash `kill -INT` now works. Note that SIGTERM cannot be sent to a Windows process from outside, and taskkill without /F sends WM_CLOSE, not SIGTERM (general Windows behaviour, not tested here).
- Related: in Git Bash, MSYS path conversion rewrote `device=/tmp/esp32c5-fake` into `device=C:/Users/…/Temp/esp32c5-fake` when passing it to a Windows program. Set `MSYS_NO_PATHCONV=1` (and `MSYS2_ARG_CONV_EXCL='*'`) when a source definition or docker argument holds a POSIX path (DD file changes, tests/docker_smoke.sh).
- Sources: WIN problems[2], checks[17]; WIN-REV hardware-test problems.

### TS-4 Windows: Ctrl+C ignored once (cause unknown)

- **Symptom:** in one run (t5restart: Wi-Fi source, a radio switch from 802.15.4 at start, then a Kismet TERM restart and a kill -9 restart), two console Ctrl+C events a minute apart did nothing. The helper kept answering PINGs and had to be killed with taskkill /F. Two exact repeats stopped cleanly in 0.56 s and 0.54 s.
- **Cause:** unknown. The shutdown then relied only on KeyboardInterrupt reaching the main thread.
- **Fix:** Ctrl+Break, or `taskkill /F`. The port is released and Kismet marks the source errored.
- **Status:** FIXED-IN-CODE / IN FLUX. There is a second stop path through signal handlers, with a DEBUG line "stop signal <name>" when one arrives (repo:remote.py:1088-1097). Not re-tested.
- Source: WIN problems[1]; log:logs/t5restart.*.

### TS-5 C helper over websocket: 3-5 s before the first data, then bursts

- **Symptom:** with `kismet_cap_esp32c5 --connect … --user … --password …`, Kismet shows the source 3-5 s after it connects: 2.96 s, 3.63 s and 5.38 s in three sessions. Packets then arrive in bursts (0 → 24 at +3.5 s → 461 at +6.0 s). Over `--tcp` (legacy port 3501) it takes 0.51 s. The Python helper over websocket took 0.35 s.
- **Cause (suspected, UPSTREAM):** strace showed the helper sent START at +0.3 s, so the delay is in the transport. Probably `cf_send_ws_raw_bytes()` in Kismet's capture_framework.c (around line 3153) calls `lws_callback_on_writable()` from the capture thread without `lws_cancel_service()`, so the libwebsockets loop only flushes when something else wakes it, such as a server ping. Not verified in lws internals.
- **Fix / advice:** harmless for normal use. For lower latency on a trusted network, use `--tcp` to port 3501.
  - Caveats: the legacy TCP port has no authentication, and Kismet listens on it on 127.0.0.1 only by default ("Launching remote capture server on 127.0.0.1 3501"). It needs `remote_capture_listen=` changed to accept other hosts, and the Docker image leaves it loopback-only (repo:docker/kismet_site.conf:7-11).
  - The C helper with `--tcp` takes no login (PI-WSL checks[18]). The Python helper warns "ignoring the user, password and API key in legacy TCP mode" (repo:remote.py:1163-1165).
- **Status:** UPSTREAM, open.
- Sources: NOTES (websocket finding) = PI-HW problems[4]; PI-HW T5; log:e2e/t5.log.

### TS-6 Kismet ignores $HOME: login file not found, REST returns nothing

- **Symptom:**
  - Kismet was started with `HOME=<dir>`, expecting it to read `<dir>/.kismet/kismet_httpd.conf`. Instead it logged `ERROR: Error reading config file '/root/.kismet/kismet_httpd.conf': No such file or directory`, and every REST call failed (no JSON).
  - On Windows→WSL, a first start without the fix used /root/.kismet for about 35 s and came up asking for a first login.
  - On the Pi, the first attempt created `/home/osh/.kismet`.
- **Cause:** Kismet expands `%h` in its config (e.g. `httpd_auth_file=%h/.kismet/kismet_httpd.conf`) from the passwd entry (`getpwuid_r()`), not from `$HOME`, unless `--homedir` is given (configfile.cc; kis_net_beast_httpd.cc).
- **Fix:** pass **`--homedir <dir>`** to kismet. It is then used for `.kismet/`: login, session db, server id, plugins.
- **Status:** FIXED in tests/kismet_e2e.sh (it passes `--homedir "$WORK/home"`). This is general Kismet behaviour that users running Kismet under a different home will hit.
- Sources: PI-WSL problems[1]; WIN summary (setup notes); PI-HW summary (harness notes).

### TS-7 WSL (and any system without a `kismet` group): `make install` fails

- **Symptom:** `/usr/bin/install: invalid group 'kismet'` at Makefile:596 (commoninstall), from `/usr/bin/install -c -o "root" -g kismet -m 4550 capture_rz_killerbee/…`.
- **Cause:** `SUIDGROUP = kismet` is hard-set in Makefile.inc, and the suid-capable helpers install with `-g $(SUIDGROUP)`.
- **Fix:**
  - Either create the group (`sudo groupadd kismet`; the Kismet docs then add users to it), or override it:
    - as root: `make install INSTGRP=root SUIDGROUP=root MANGRP=root` (what ran in WSL);
    - as a normal user into a home prefix: `make install INSTUSR=<you> INSTGRP=<you> SUIDGROUP=<you>` (what ran on the Pi, without sudo).
- **Status:** environment note; no repo change.
- Sources: PI-WSL problems[3], checks[2]; CFIX tests[5]; PI-BUILD notes §5.

### TS-8 Docker: no source ever starts; helper crashes with signal 11 (NET_ADMIN)

- **Symptom:** in a container without `--cap-add NET_ADMIN`:
  - Kismet logs only `cancelling source probe due to timeout` / `Unable to find driver`.
  - The helper exits with `capture process exited 0 signal 11`.
  - The first smoke test failed 14 checks because of it.
- **Cause:** Kismet's capture helpers, run as root, try to keep NET_ADMIN and NET_RAW and drop the rest (`cf_drop_most_caps()`). Docker's default set has NET_RAW but not NET_ADMIN, so `cap_set_proc` fails with EPERM. `cf_send_warning()` ('datasource failed to set future process capabilities: Operation not permitted') then dereferences a NULL ring buffer. This hits Kismet's stock helpers too (kismet_cap_catsniffer_zigbee crashed the same way).
- **Fix:** `--cap-add NET_ADMIN` on `docker run`. compose.yaml already has `cap_add: [NET_ADMIN]` on the kismet, demo and helper services (repo:compose.yaml:40-43, :74; repo:docker/Dockerfile:17-19).
- The entrypoint now warns (repo:docker/entrypoint.sh:134-154):
  - with local sources and no NET_ADMIN: "the container has no NET_ADMIN capability, and without it Kismet's capture helpers crash on start. Add --cap-add NET_ADMIN to docker run (compose.yaml has it)."
  - with no local sources: "no NET_ADMIN capability: sources from remote helpers work, boards plugged into this machine would not (add --cap-add NET_ADMIN for those)"
- **Remote-only use does not need NET_ADMIN.** The Windows→Docker test ran without it: 26k+ packets, no errors. Its log showed the old wording of the warning, which was misleading for remote-only use and has since been reworded (WIN-DOCKER problems[0]).
- **Status:** worked around on the Docker side. The C helper still calls `cf_drop_most_caps(caph)` (repo:capture_esp32c5.c:1590). UNVERIFIED whether a native root install on a system that limits capabilities could hit the same crash.
- Sources: DD problems[1] and file changes; WIN-DOCKER problems[0].

### TS-9 BTLE: every device on channel 37, and device packet counts stuck at 1-3

- **Symptom:** in Kismet, all BTLE devices show channel 37 / 2402 MHz. Per-device packet counts, last-seen times and signal stop updating after the first 1-3 packets, while the source counts about 20 packets/s.
  - Pi: 18 devices at 1-3 packets while c5-btle counted 2969.
  - Windows: 16 devices at 1-3 packets, 3443 source packets.
  - `packet_stats.json` over the last minute: packets 1099, dupe 1094, error 0. Pi: dupe_packets_rrd=87 in the last second.
- **Cause:**
  1. The firmware writes rf_channel 0 (advertising channel 37) in every record. The ESP32-C5 controller scans 37/38/39 together and does not report which channel an advert came on.
  2. UPSTREAM: Kismet drops a packet as a duplicate when its frame's CRC32 matches one of the last 1024 packets (packetchain.cc:382-429; phy_btle.cc:195 drops duplicates before dissection). Repeated advertisements are byte-identical.
- **Fix:** nothing to fix. The docs should say that BLE device counts and last-seen times in Kismet only update when an advertisement's contents change, and that the channel is always shown as 37. Changing frames to defeat the dedupe would corrupt them.
- **Status:** known limitation.
- Sources: NOTES (BTLE finding); WIN problems[5]; PI-FLASH problems[2].

### TS-10 `channel=` in a definition was ignored (the source stayed on 6 / 15)

- **Symptom:**
  - Pi (C helper): `-c 'esp32c5:device=<A by-id>,mode=zigbee,name=c5-zb20,channel_hop=false,channel=20'` gave hopping=0 but channel '15', and a 200-frame TXTEST on channel 20 gave num_packets=0.
  - Windows (Python helper): `esp32c5-COM32:mode=zigbee,name=win-zigbee,channel_hop=false,channel=20` left the board on 15, and Kismet sent no CONFIGREQ at all. REST showed channel=15 and hopping=1 (left over from an earlier session of the reused source record).
- **Cause:** both helpers always started on the default channel (Wi-Fi 6, Zigbee 15, BTLE 37) and never read `channel=`. Kismet only adds `channel=` to the channel list and expects the helper to tune to it (kis_datasource.cc:1863; datasourcetracker.cc:1890 returns at once for channel_hop=false).
- **Workaround used:** `POST /datasource/by-uuid/<uuid>/set_channel.cmd` with `{"channel":"20"}`. After it: 200/200.
- **Status:** FIXED-IN-CODE / IN FLUX in both helpers.
  - `channel=<n>` is where the source starts, and with `channel_hop=false` where it stays.
  - It is checked strictly before the port is touched: digits only, ≤177, and valid for the radio. Error text: `<interface>: channel=<n> is not a channel the board can tune to in <mode> mode`.
  - BTLE accepts 37, 38 or 39 and stays on 37.
  - Refs: repo:capture_esp32c5.c:53-55, :1388-1408; repo:remote.py:280-295; CFIX fixes[2]. Fake-board e2e passed: `channel=36,channel_hop=false` gave hopping=0, channel '36', and only 'CHANNELS 36' sent (CFIX tests[13]).
  - Not yet re-run on hardware.
  - UNVERIFIED: whether a reused Kismet source record still shows hopping=1 with channel_hop=false. The Python helper now sends `hopping=src.hopping` in its open report (repo:remote.py:773-774).
- Sources: PI-HW T2; NOTES; WIN checks[10], problems[0]; log:logs/t4lock.log.

### TS-11 Bare `-c esp32c5` with two or more boards: "Unable to find driver"

- **Symptom:** with two boards attached, `-c esp32c5` logs `ERROR: Unable to find driver for 'esp32c5'…`, and the source is never retried.
- **Cause:** the helper cannot pick a board, so its probe fails. Kismet mutes probe errors, the message is lost, and no driver claims the source.
- **Fix:**
  - Name the board: `esp32c5-ttyACM2`, `esp32c5zigbee-ttyACM2`, `device=/dev/serial/by-id/…`.
  - Or add `type=esp32c5`. With `-c 'esp32c5:type=esp32c5'`, Kismet showed the real reason and retried every 5 s. In the field that reason read `2 ESP32-C5 boards found; say which one with device= or a source name like esp32c5-ttyACM2`.
  - IN FLUX: the current text is `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-ttyACM2` (repo:capture_esp32c5.c:444-446).
- **Status:** still present. `probe_callback` returns the parse result, -1 when the device cannot be resolved (repo:capture_esp32c5.c:1297-1311, :1283-1284). Document the workaround, or ask whether a fix is planned (open question).
- Source: NOTES (bare esp32c5 finding).

### TS-12 Two boards "disappear" from the Pi hub

- **Symptom:** the kernel log shows `usb 1-1.2.3: USB disconnect, device number 4` (13:49:51) and `usb 1-1.2.2: USB disconnect, device number 5` (13:49:54), never re-enumerated. The hub ports `/sys/bus/usb/devices/1-1.2:1.0/1-1.2-port2` and `port3` read `state=not attached`, disable=0, over_current_count=0. lsusb shows only two 303a:1001 devices.
- **Cause:** a manual unplug. The 3-second gap looks like a hand, and the two boards (C and D) turned up on the Windows PC as COM32 and COM30 minutes later (same MACs). A firmware hang would leave USB-Serial-JTAG enumerated.
- **Fix, general troubleshooting:**
  - Check `dmesg` for "USB disconnect" and `/sys/bus/usb/devices/<hub>/<hub>-portN/state`.
  - Replug, or power-cycle the hub.
  - `--list` shows only what is on the bus, so a missing board is not a helper bug (PI-BUILD problems[0]).
- **Status:** environment.
- Sources: PI-HW checks[0], problems[0]; NOTES; PI-BUILD problems[0].

### TS-13 Python helper: a `/dev/serial/by-id/…` path gives a different source than the C helper for the same board

- **Symptom:**
  - The Python helper registered `E5C50001-0000-0000-0000-95AA07821E01` (a hash of the by-id path) with hardware 'ESP32-C5' (no MAC).
  - The C helper, for the same definition, gave `E5C50001-0000-0000-0000-10BDA3C87D54` and 'ESP32-C5 (10:BD:A3:C8:7D:54)'.
  - So Kismet saw two different sources for one board and radio.
- **Cause:** the Python helper compared port paths as strings, and pyserial's port list names `/dev/ttyACM3`, never the by-id link.
- **Status:** FIXED-IN-CODE / IN FLUX. Ports are now compared by `os.path.realpath` on POSIX (repo:board.py:484, :570; repo:remote.py:321 `bd.mac_of_port`). Not re-run on hardware.
- Sources: NOTES (by-id finding); PI-HW T6; log:e2e/t6.log.

### TS-14 Python helper against a pseudo-terminal (the fake board, socat, ser2net): 0 packets

- **Symptom:** the helper log shows `<port>: [Errno 25] Inappropriate ioctl for device`, then after 15 s `the board on <port> has not been capturing for 15 s`. Kismet shows `remote connection triggered shutdown: …`.
- **Cause:** after opening, the helper cleared RTS/DTR through pyserial's setters, and those raise ENOTTY on a pty, which has no modem lines. The C helper opens the same pty fine.
- **Status:** FIXED-IN-CODE. EINVAL/ENOTTY from those two calls are now ignored (repo:board.py:401-411). With a shim that did the same, the Python remote checks passed: websocket BTLE 3389 packets with ESP32C5-FAKE seen; TCP Zigbee 401 packets after the reboot. Real /dev/ttyACM ports were never affected.
- Source: PI-WSL problems[0], checks[19-22].

### TS-15 Python helper: a board that cannot be opened showed as "running"

See TS-1, Status. The field behaviour was: the open report succeeded before the port was tried, Kismet showed running=1 with 0 packets for about 15 s of every ~22 s cycle, and error_reason read only `remote connection triggered shutdown: the board on COM99 has not been capturing for 15 s` (WIN-REV W5; verified with COM99 against a live Kismet). FIXED-IN-CODE / IN FLUX.

### TS-16 Python helper: unplugging a board for 20 s or more makes a second Kismet source

- **Symptom:**
  - With `--source esp32c5-COM30:mode=wifi`, a board away for more than about 20 s (15 s sync timeout plus 5 s backoff) came back under a different UUID: `…-9AE7F160D405` instead of `…-10BDA3CF0540`.
  - Kismet then listed two `esp32c5-COM30` sources, one in error, with packets and devices split between them.
  - The same happened when the helper was started before the board was plugged in.
  - Reproduced against a live Kismet: "New remote source esp32c5-COM99 (E5C50001-…-10BDA3CF0540) connected", then later "(E5C50001-…-1DE7F14F5694) connected".
- **Cause:** the helper re-resolved the definition before every connection and fell back to a hash of the port name when the board was not enumerated. Kismet matches remote sources by UUID only and never removes old ones.
- **Status:** FIXED-IN-CODE / IN FLUX.
  - A named port that is absent is now "not there" (BoardNotFound), with the message `<port> is not there; is the board plugged in? (waiting for it)`, and it is not offered to Kismet (repo:remote.py:297-302).
  - Once a board is identified, the source keeps its identity (repo:remote.py:958-980).
  - A definition without a port stays with the board it found first, by MAC: `the board <MAC> is not plugged in (waiting for it)` (repo:remote.py:306-310).
  - If another board now sits on the named port, it logs `… holds board <new> now, not <old>; Kismet will see it as another source`.
- Sources: WIN-REV W1, W4.

### TS-17 Python helper on Linux: after Kismet restarts, the source never comes back and the helper exits 0

- **Symptom:** with websocket-client 1.6.0-1.9.0 on Linux, a Kismet that is killed, crashes or restarts while a busy source streams resets the TCP connection. The helper then prints a traceback ending `OSError: [Errno 107] Transport endpoint is not connected` (from `websocket/_core.py … abort`) and never reconnects. When every source has died that way, the process exits with status 0, so systemd's `Restart=on-failure` does not restart it.
- **Cause:** websocket-client's `abort()` is unguarded before 1.9.1. Distribution packages are older:
  - Ubuntu 24.04 `python3-websocket` is 1.7.0-1;
  - Debian trixie (the Pi) is 1.8.0-2 (PI-REV #8 verdict).
  - Windows was not affected (1.9.2, and Windows `shutdown()` after a RST does not raise).
- **Fix:** `pip install -r requirements.txt` (pulls 1.9.2).
- **Status:** FIXED-IN-CODE. requirements.txt now says `websocket-client>=1.9.1` (repo:requirements.txt), and the helper copes with older versions: each connection's failure is caught, and the loop reconnects (repo:remote.py:994-1007). If every source stops by itself, it logs `every source has stopped by itself` and returns 1 (repo:remote.py:1217-1219).
- Sources: WIN-REV W3; PI-REV #8.

### TS-18 Same board given twice with different spellings (com32 / COM32 / \\.\COM32, by-id vs ttyACM)

- **Symptom:** in the field version, `--source esp32c5-COM32:mode=wifi --source esp32c5:device=com32,mode=zigbee` started without error. One source then failed with `could not open port 'com32': PermissionError(13, 'Access is denied.')` every second and flapped in Kismet every ~20 s. On POSIX both could open the tty, and the board rebooted between radios.
- **Status:** FIXED-IN-CODE / IN FLUX. Ports are canonicalised (COMn upper-cased, `\\.\` stripped, realpath on POSIX) and compared (repo:remote.py:182-186, :327-357). Error texts:
  - `<def1> and <def2> both want <port>`
  - `<def1> and <def2> name no port, so both would take the same board; say which with device= or a source name like esp32c5-<port>`
  - at run time: `<port> is <def>'s port already; a board captures with one radio at a time`

  Across helpers and programs, the port is held exclusively (flock on POSIX, exclusive open on Windows). A second capture gets `<port> is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time` (repo:board.py:69-70, :353-400; repo:capture_esp32c5.c:49-51, :564).
- Sources: WIN-REV W2, W6; CFIX fixes[3], tests[13] (Kismet log 'already in use', add_source.cmd for the same board answered HTTP 500).

### TS-19 Board on older firmware: no answer to START, or BTLE packets but no BTLE devices

- **Symptom:**
  - (a) The board streams (you can see SSIDs in the raw bytes) but never answers START, so the helper never syncs (boards A and B before flashing).
  - (b) BTLE: the source counts packets, but Kismet creates no devices and raises no error.
- **Cause:**
  - (a) Old app builds do not implement the nonce START.
  - (b) The published Wireshark-project firmware leaves the "CRC checked/valid" flags clear and the CRC bytes zero. Kismet then checks the CRC itself with a different initial value (0x555555 unreflected) and drops the packet.
- **Fix:** flash the current merged image (section 3).
- **Status:** FIXED-IN-CODE / IN FLUX for (b). Both helpers now fill in the CRC and flags and log once: `<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary` (repo:capture_esp32c5.c:830-836; repo:remote.py:867-868). Fake-board e2e with `--old-firmware` passed (CFIX tests[15]).
- Sources: PI-FLASH boards[2-3].before; PI-REV #10; CFIX fixes[7].

### TS-20 Kismet log: `ERROR: Tried to re-register duplicate alert FLIPPERZERO`

UPSTREAM and harmless. It appears at every start of Kismet cfe427074, with or without this source. Do not treat "ERROR" lines in the Kismet log as failures (PI-WSL problems[4]; DD).

### TS-21 `kismet --version` exits 1; `kismet_cap_esp32c5 --list` prints to stderr and exits 2; `--help` exits 255

UPSTREAM, by design (section 2.4). Scripts should check the text, not the exit code (DD fix (1): the image self-check greps the version text and runs the helper's `--version`, which exits 0).

### TS-22 Kismet shows an old error message on a running source

UPSTREAM display quirk. After a reconnect or re-open, `error_reason` keeps the last error text while running=1 and error=0 (WIN checks[16]; PI-HW T4).

### TS-23 Kismet's Data Sources panel: one row per board, and Enable always opens Wi-Fi

- **Symptom (field version):** `--list` gave three lines per board with the same name (`esp32c5-ttyACM2:mode=wifi`, `…:mode=zigbee`, `…:mode=btle`; PI-BUILD list_output). Kismet keeps only the name of a listed interface, so the web UI showed one row, "Available Interface: esp32c5-ttyACM0 (esp32c5)". Enable Source posted `esp32c5-ttyACM0:type=esp32c5` and opened Wi-Fi, rebooting a board stored in another radio.
- **Status:** FIXED-IN-CODE / IN FLUX. The listing now names each radio: `esp32c5-<tty>` (Wi-Fi), `esp32c5zigbee-<tty>` and `esp32c5btle-<tty>`. The radio comes from the word between "esp32c5" and the first '-', and `mode=` wins (repo:capture_esp32c5.c:30-51, :1313-1359; repo:remote.py:8-19, :189-208).
  - Mode aliases: zigbee = 802154, 802.15.4, thread; btle = ble, bluetooth.
  - Only one of the three can run at a time; enabling another fails with "already in use" (CFIX problems[3]).
  - UNVERIFIED: the exact `--list` text and the UI rows after the change; not seen on hardware yet.
- Sources: PI-REV #1; CFIX fixes[1]; PI-BUILD list_output.

### TS-24 The Available Interfaces list keeps offering a board that is in use

- **Field version:** a source defined by `device=` or bare `esp32c5` reported its capture interface as the raw path, so Kismet's in-use check missed it, and the UI kept offering the board as available (PI-REV #11).
- **Status:** FIXED-IN-CODE / IN FLUX. capif is now `esp32c5-<tty>` (e.g. `esp32c5-ttyACM0`, or `esp32c5-pts/3` for the fake), so the Wi-Fi row shows as in use. The zigbee and btle rows of the same board are still offered, and enabling one fails cleanly with "already in use" (CFIX fixes[8], problems[3]).

### TS-25 Two sources on one board

See TS-18. Also Kismet-side (C helper): a second `add_source` for a board in use now fails (HTTP 500), and the Kismet log shows "already in use" (CFIX tests[13]).

### TS-26 Channels 169, 173 and 177 never visited (firmware flashed today)

- **Symptom:** a host that sends a range such as `CHANNELS 1-177` gets 39 channels. 169, 173 and 177 are silently dropped, and the firmware logs "scanning 39 channel(s)".
- **Cause:** the scan list held 14 + 25 = 39 entries while 42 channels are valid (PI-REV #19). Both Kismet helpers send one channel per hop, so Kismet's hopping is not affected. The sibling Wireshark extcap passes a typed range through and is affected.
- **Status:** FIXED in the repo firmware (`#define MAX_SCAN_CHANNELS (14 + 8 + 12 + 8)`, repo:firmware/main/esp32c5_sniffer.c:342). The boards flashed at 13:09 predate the fix (see Timeline) and need re-flashing. UNVERIFIED on hardware.

### TS-27 Docker image will not start after a Windows checkout (CRLF)

- **Symptom:** the image cannot start its shell scripts.
- **Cause:** `core.autocrlf=true` turned the scripts to CRLF.
- **Status:** FIXED. `.gitattributes` has `* text=auto eol=lf` (repo:.gitattributes). Keep it in mind for anyone copying the scripts by other means (DD problems[2]).

### TS-28 Memory of each capture helper grows with packet count

- **Symptom:** RSS grows by about 32 bytes per packet for the life of the helper. The review extrapolated about 115 MB/hour at 1000 frames/s; that is an estimate, not a measurement.
- **Cause:** UPSTREAM: Kismet's `cf_commit_packet` never frees the metadata holder, and every Kismet capture helper leaks.
- **Status:** FIXED by add-to-kismet.sh, which patches capture_framework.c (idempotent, skipped once Kismet has the fix). Measured with mallinfo2 over 200,000 sends: 6,400,000 bytes (32.0 bytes/packet) before, 0 after (CFIX fixes[6], tests[6]; repo:kismet/add-to-kismet.sh:16-20). The field builds (Pi 12:59, WSL earlier) predate the patch. The Pi rebuild in progress should include it (UNVERIFIED).

### TS-29 A refused channel set crashed the C helper

In the field version, an explicit set to a channel the helper rejected crashed it (strlen(NULL) in the framework's CONFIGRESP) (PI-REV #6). FIXED-IN-CODE: the refused set is reported as an error and the channel stays (CFIX fixes[5]). Not seen in the field runs themselves.

### TS-30 Killing a local helper by board path does not work

A local helper's command line holds only `--in-fd`/`--out-fd`, not the board path, so `pkill -f /dev/ttyACM…` cannot find it. Use the source's `ipc_pid` from REST (`/datasource/all_sources.json`) instead. Test and ops note (PI-HW summary harness notes, T4).

---

## 9. Demo and fake board facts (for the demo pages)

- Fake Wi-Fi APs: `ESP32C5-FAKE-24` (2.4 GHz), `ESP32C5-FAKE-5LOW` and `ESP32C5-FAKE-5HIGH` (5 GHz). They only show when hopping reaches their channels (PI-WSL checks[6-7]).
- Fake BTLE: `C6:00:00:C5:E5:5A` named `ESP32C5-FAKE`. Fake 802.15.4: devices 10:01, 25:01, FF:FF (PI-WSL checks[12], [15]).
- Test-only fake options (IN FLUX):
  - `--garble N`: damage every Nth record;
  - `--inject N`: frames carrying the restart signature (BSSID 02:E5:C5:00:00:99, SSID 'FAKE-INJECT<<START>>\nxD4');
  - `--restart-every N`: the cut-short records show up as garbage devices such as 0A:3C:3C:53:54:41;
  - `--vanish`; `--old-firmware`.
  - The fake sends about 100 records/s and reboots in place in about 0.53 s like a real board (CFIX fixes[13], tests[8-15]; PI-WSL problems[2]).
- Demo login: demo / demo on http://localhost:2501 (repo:compose.yaml:9; DD).

## 10. Test counts seen today (they change as tests are added; IN FLUX)

| Suite | Count | Where | Source |
|---|---|---|---|
| tests/test_board.py | 49 PASS, 1.7 s (Pi, Python 3.13.5 aarch64); 49 PASS (WSL, CFIX); 24 PASS in an earlier WSL run | Pi, WSL | PI-HW T7; CFIX tests[2]; PI-WSL checks[23] |
| tests/test_kismet_v3.py | 132 PASS, 3.3 s (Pi); 39 PASS in an earlier WSL run | Pi, WSL | PI-HW T7; PI-WSL checks[24] |
| tests/c (C parser harness, `sh tests/c/run.sh /root/src/kismet`) | 188 checks, ALL OK | WSL gcc 13 | CFIX tests[0] |
| tests/kismet_e2e.sh | 8 cases, 49 checks, ALL OK (earlier version: 12/12) | WSL | CFIX; PI-WSL checks[16] |
| tests/docker_smoke.sh | 21/21 PASS | Docker Desktop | DD |

---

## 11. IN FLUX summary (verify before publishing)

1. All timings and counts are from the pre-fix helpers and the 13:09 firmware; re-measure on the rebuilt Pi. The radio-switch time will change with `MODE_SETTLE_S = 0.8` s.
2. Hardware string: `Espressif USB-Serial-JTAG (<MAC>)` now, `ESP32-C5 (<MAC>)` in the field logs and screenshots.
3. Source names: `esp32c5-<port>`, `esp32c5zigbee-<port>`, `esp32c5btle-<port>` (new) versus `esp32c5-<port>:mode=…` (field). Exact `--list` output after the change is unverified.
4. `channel=` honoured by both helpers (not re-run on hardware).
5. Exclusive port lock and the "already in use" message (C: fake e2e passed; Python: not run).
6. Python helper: `localhost` → 127.0.0.1 first; stop handlers (SIGINT/SIGTERM/SIGBREAK plus clearing the inherited ignore-Ctrl+C); open failures reported to Kismet; identity pinning; port canonicalisation and claims; by-id MAC; BTLE CRC fix-up; env login. Code is present, but none of it has been re-run on Windows or the Pi.
7. C helper: env login (`KISMET_CAP_*`), BTLE CRC fix-up, capif `esp32c5-<tty>`, no-sysfs message on macOS/BSD (not compiled there), MAC re-find after tty swap (untested: needs two boards whose tty names swap).
8. add-to-kismet.sh's upstream leak patch (the field builds lack it).
9. Firmware: 42-channel scan list in the repo; the boards need re-flashing.
10. Test counts.

## 12. Open questions

1. Did the replug fix COM30 for good? The logs show only "opens fine again now" (WIN-REV W5 verifier), and the orchestrator says replug; no log of the replug itself.
2. The four-boards-at-once run (two Wi-Fi, one Zigbee, one BTLE) never happened. Should the docs claim four simultaneous sources on a Pi 4? Suggest re-running T1e on the rebuilt Pi.
3. Which apt packages did the Pi need for the Kismet build? Configure found nothing missing because they were already installed. The install page needs the list from somewhere other than this run.
4. Is the bare `esp32c5` "Unable to find driver" (TS-11) going to be fixed in the C helper, or documented with `type=esp32c5`?
5. Are Git Bash `kill -INT` and Ctrl+Break effective with the new stop handlers on Windows (TS-3, TS-4)?
6. Does `channel_hop=false` now clear a stale hopping=1 on a reused Kismet source record (TS-10)?
7. Should neighbours' SSIDs seen in the field ('osvc-52', 'Cudy-C223-5G', 'MEIRAV', 'Dayan', 'cohen') appear in the docs? I suggest not.
8. Will the published merged firmware be the 14:56 build or a newer one? The flashed boards differ from the repo build (see Timeline).
9. Should the firmware's BLE CRC wording and the ChSel caveat (4.6) go into the user docs or only the developer notes?
10. Minor, not field: the firmware log line at repo:firmware/main/esp32c5_sniffer.c:809-810 prints "Wi-Fi" when switching to BLE (it only distinguishes 802.15.4 from everything else). It goes to UART0, which users do not see over USB.
