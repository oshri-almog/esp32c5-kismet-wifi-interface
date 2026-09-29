# Firmware fact sheet — esp32c5-kismet-wifi-interface/firmware

Gathered 2026-09-28, read-only. Paths are relative to the repo root
`C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface` unless they say otherwise.
`FW` = `firmware/main/esp32c5_sniffer.c`. `SIB` = the sibling repo
`C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-wireshark-sniffer`.

Markers:
- **[file:line]**: taken from the source.
- **[run: …]**: taken from a build log, a binary or a command I ran (read-only).
- **IN FLUX**: may still change; write the behaviour described here and mark it for verification.
- **UNVERIFIED**: could not be confirmed from code or from a run. Nothing here was tested on a board: no COM port was opened.

The firmware source is **not** listed as in flux by the orchestrator. The two helpers that talk to it are:
the C helper is in final review and the Python helper is being changed to match it. Helper facts that appear here are
there only for context.

---

## 1. At a glance

| | |
|---|---|
| Chip | ESP32-C5 only. Target `esp32c5`. The build fails on a chip without USB-Serial-JTAG [FW:52-54] |
| Framework | ESP-IDF **v5.5.5** [run: `build/project_description.json` `"git_revision": "v5.5.5"`; `IDF_VERSION 5.5.5` in `build/config.env`] |
| Project / app name | `esp32c5_sniffer` [firmware/CMakeLists.txt:5] |
| Source files | one C file, `firmware/main/esp32c5_sniffer.c`, 1316 lines |
| Radios | Wi-Fi 2.4 + 5 GHz (radiotap), IEEE 802.15.4 (Zigbee/Thread, 802.15.4 TAP), Bluetooth LE advertising (LL + pseudo-header). **One per boot**, chosen by `MODE` and stored in NVS [FW:257-270, 1271-1301] |
| Host link | the native USB port (USB-Serial-JTAG, USB ID `303a:1001`). It carries **only** the capture stream plus the host's command lines [firmware/sdkconfig.defaults:4-9; FW:9-10] |
| Logs | UART0, 115200 baud, TX = GPIO11, RX = GPIO12 [sdkconfig.defaults:5-7; run: `sdkconfig` `CONFIG_ESP_CONSOLE_UART_BAUDRATE=115200`; `C:\esp\v5.5.5\esp-idf\components\soc\esp32c5\include\soc\uart_pins.h:15-16`] |
| Licence | MIT (firmware/ is not under kismet/'s GPL) — from the orchestrator brief |
| Origin | copied from SIB `firmware/`; `CREDITS.md:8-12` |

---

## 2. Building

### 2.1 Toolchain actually used [run: `firmware/build/log/*`, `firmware/build/CMakeCache.txt`]
- ESP-IDF at `C:/esp/v5.5.5/esp-idf`, Python venv `C:\Espressif\tools\python\v5.5.5\venv`.
- GCC `riscv32-esp-elf` 14.2.0 (`esp-14.2.0_20260121`), Ninja 1.12.1, ccache 4.12.1, CMake generator Ninja.
- esptool bundled with the ESP-IDF 5.5.5 venv: **4.12.0** [run: `esptool-4.12.0.dist-info`; build log line `esptool.py v4.12.0`].
- esptool in the ESP-IDF v6.1 venv on this machine: **5.4.0** (for the v5 syntax below) [run: `C:\Espressif\tools\python\v6.1\venv\...\esptool\__init__.py:41`].

### 2.2 Commands
From an ESP-IDF 5.5 shell (`export.sh` / `export.ps1` / the "ESP-IDF 5.5 PowerShell" shortcut):
```
cd firmware
idf.py set-target esp32c5      # once; sdkconfig.defaults:1-2 also makes esp32c5 the default target
idf.py build
```
- The cmake step that was run: `cmake -G Ninja -DPYTHON_DEPS_CHECKED=1 -DPYTHON=...\venv\Scripts\python.exe -DESP_PLATFORM=1 -DIDF_TARGET=esp32c5 -DCCACHE_ENABLE=1 ...\firmware` [run: `build/log/idf_py_stdout_output_26680`].
- Configuration: `firmware/sdkconfig.defaults` is applied when there is no `firmware/sdkconfig`. `firmware/sdkconfig`, `firmware/sdkconfig.old`, `firmware/build/`, `firmware/managed_components/`, `firmware/dependencies.lock` are git-ignored [.gitignore:1-6]. So a fresh clone builds from `sdkconfig.defaults`.
- Project options live in `idf.py menuconfig` → **Packet Sniffer Configuration** [main/Kconfig.projbuild:1]. See 2.4.
- Components the app pulls in: `esp_wifi esp_event esp_timer esp_ringbuf nvs_flash esp_driver_usb_serial_jtag ieee802154 bt` [firmware/main/CMakeLists.txt:3-4].

### 2.3 Warnings a user will see (all harmless)
- `warning: ignoring malformed line '﻿# Target: ESP32-C5 (run \`idf.py set-target esp32c5\` once; ...)'` — because `firmware/sdkconfig.defaults` starts with a UTF-8 BOM (bytes `EF BB BF`) and the first line is a comment [run: `od -c`; `build/log/idf_py_stderr_output_26680`]. The line is only a comment, so nothing is lost. (Fix: save the file without BOM — see §17.)
- `git describe returned 'fatal: bad revision 'HEAD''` / `Could not use 'git describe' to determine PROJECT_VER` — the repo had no commits at build time, so the app version became **`1`** [run: log 26680; `build/project_description.json` `"project_version": "1"`]. Once the repo has commits, PROJECT_VER will be the `git describe` output (standard ESP-IDF behaviour; nothing in the project sets PROJECT_VER). See open questions.
- `Component directory C:/esp/v5.5.5/esp-idf/components/esp_blockdev does not contain a CMakeLists.txt file` — from this machine's IDF install, not the project [run: log 26680].

### 2.4 Menuconfig options (Packet Sniffer Configuration) [main/Kconfig.projbuild; sdkconfig.defaults; resolved values from run: `firmware/sdkconfig:709-720`]

| Option | Kconfig default | Range | This project's value | What it does |
|---|---|---|---|---|
| `SNIFFER_CHANNEL_HOPPING` | y [Kconfig:3-5] | bool | **n** [defaults:15] | Built-in Wi-Fi list = every channel of the bands (y) or just the start channel (n) |
| `SNIFFER_HOP_INTERVAL_MS` | 250 [Kconfig:12-15] | **50–60000** | 250 | Boot-time dwell. Runtime `DWELL` accepts **20**–60000 (see §9.5), a wider range than menuconfig |
| `SNIFFER_START_CHANNEL` | 1 (36 if 5 GHz only) [Kconfig:19-25] | 1–177 (1–14 if 2.4 only, 36–177 if 5 only) | **6** [defaults:16] | Channel after boot; the whole list when hopping is off. A channel outside the chosen band fails the build [FW:324-330] |
| `SNIFFER_2G_MAX_CHANNEL` | 13 [Kconfig:30-33] | 1–14 | 13 | Top of the 2.4 GHz part of the built-in hop list (only used when hopping is on) |
| `SNIFFER_BAND` choice | DUAL on 5 GHz chips [Kconfig:36-52] | 2G / 5G / DUAL | **DUAL** [defaults:14] | Band mode given to the driver at boot (AUTO / 5G_ONLY / 2G_ONLY) [FW:1114-1127] |
| `SNIFFER_LINKTYPE` choice | RADIOTAP [Kconfig:54-67] | RADIOTAP (127) / IEEE802_11 (105) | RADIOTAP | Wi-Fi link type. **Both helpers expect 127**; a 105 build would be refused ("the board sends link type 105, not 127") [capture_esp32c5.c:1014-1019] |
| `SNIFFER_CAPTURE_CTRL_FRAMES` | y [Kconfig:70-78] | bool | y [defaults:19] | Also capture control frames (ACK, RTS, CTS, Block Ack, PS-Poll, CF-End) |
| `SNIFFER_RINGBUF_SIZE` | 65536 [Kconfig:80-86] | 32768–262144 | 65536 | Capture ring buffer, bytes |
| `SNIFFER_USB_TX_BUF_SIZE` | 32768 [Kconfig:88-91] | 16384–131072 | 32768 | USB-Serial-JTAG driver TX buffer, bytes |

Other settings in `sdkconfig.defaults` worth knowing:
- Console on UART0 only, no secondary console, USB-Serial-JTAG enabled as a peripheral [defaults:7-9].
- Wi-Fi RX buffers raised: static 24, dynamic 64, management 10 [defaults:22-24].
- Bluetooth: NimBLE, **observer role only**; central, peripheral, broadcaster off [defaults:32-37]. Extended scanning is off (`# CONFIG_BT_NIMBLE_EXT_SCAN is not set`) [run: sdkconfig:908].
- Custom partition table `partitions.csv` [defaults:41-42].
- Resolved flash settings: DIO, 80 MHz, **2 MB** [run: sdkconfig:664-681]. CPU 240 MHz [run: sdkconfig:1698]. 802.15.4 RX buffers 20 [run: sdkconfig:2020].

---

## 3. Build outputs, sizes, partition layout

### 3.1 `firmware/build/flash_args` [run: file content]
```
--flash_mode dio --flash_freq 80m --flash_size 2MB
0x2000 bootloader/bootloader.bin
0x10000 esp32c5_sniffer.bin
0x8000 partition_table/partition-table.bin
```
`build/flasher_args.json` adds `"before": "default_reset"`, `"after": "hard_reset"`, `"stub": true`, `"chip": "esp32c5"`.

The **ESP32-C5 bootloader sits at 0x2000**, not 0x0 or 0x1000.

### 3.2 Sizes [run: `ls -l`, build log `idf_py_stdout_output_50412`, check_sizes output]

| File | Bytes | Hex | Notes |
|---|---|---|---|
| `build/bootloader/bootloader.bin` | 22,112 | 0x5660 | "0x9a0 bytes (10%) free" |
| `build/partition_table/partition-table.bin` | 3,072 | 0xC00 | |
| `build/esp32c5_sniffer.bin` (app) | 1,083,040 | 0x1086A0 | "Smallest app partition is 0x1f0000 bytes. 0xe7960 bytes (47%) free." |
| `build/esp32c5-kismet-merged.bin` | **1,148,576** | 0x1186A0 | = 0x10000 + app; ~1.10 MiB; flashes at 0x0 |

I checked the merged file byte for byte: bootloader at 0x2000, partition table at 0x8000 and app at 0x10000 each match the separate
files. 0x0–0x2000 and every gap are 0xFF. The merged file is current: the app was built at 14:56:18 from source saved at
14:40, and the merged image was written at 14:56:52 [run: python compare, mtimes].

Values in the app's `esp_app_desc` [run: parsed at merged+0x10020]: project `esp32c5_sniffer`, version **`1`**, compile date `Sep 28 2026`, IDF `v5.5.5`.

### 3.3 Partition table [firmware/partitions.csv:5-8; run: build log "Partition table binary generated"]
```
# Name,     Type, SubType,  Offset,   Size
nvs,        data, nvs,      0x9000,   0x6000     (24K)
phy_init,   data, phy,      0xf000,   0x1000     (4K)
factory,    app,  factory,  0x10000,  0x1F0000   (1984K)
```
- Why: the default single-app table gives the app 1 MB, and the Wi-Fi, 802.15.4 and BLE stacks together do not fit in it. This table gives the app the rest of a 2 MB flash [partitions.csv:1-3; sdkconfig.defaults:40].
- **Minimum flash: 2 MB.** 0x10000 + 0x1F0000 = 0x200000. Works on any ESP32-C5 module with 2 MB or more [partitions.csv:2-3]. On a larger flash the image still says 2 MB and uses 2 MB.
- No OTA partitions, so there is no over-the-air update.

---

## 4. Producing the merged image

### 4.1 `idf.py merge-bin` exists in ESP-IDF 5.5.5 — verified
[`C:\esp\v5.5.5\esp-idf\tools\idf_py_actions\serial_ext.py:269-316` (callback), `:658-699` (action definition)]
- Syntax: `idf.py merge-bin [-o FILE] [-f raw|hex|uf2] [--md5-disable] [-t/--flash-offset OFF] [--fill-flash-size 256KB..128MB] [merge-args...]`
- It depends on `all`, so it **builds first** [serial_ext.py:698].
- It runs `python -m esptool --chip <target> merge_bin -o <output> [-f fmt] ... @flash_args` in the build directory. Without `-o` the output is `merged-binary.bin` (raw/uf2) or `merged-binary.hex`, **in `firmware/build/`** [serial_ext.py:282-316].
- Default format is `raw` [serial_ext.py:667-670].

What produced this repo's image at 12:42 [run: `build/log/idf_py_stdout_output_35456`]:
```
Command: ...\python.exe -m esptool --chip esp32c5 merge_bin -o esp32c5-kismet-merged.bin -f raw @flash_args
esptool.py --chip esp32c5 merge_bin -o esp32c5-kismet-merged.bin -f raw --flash_mode dio --flash_freq 80m --flash_size 2MB 0x2000 bootloader/bootloader.bin 0x10000 esp32c5_sniffer.bin 0x8000 partition_table/partition-table.bin
esptool.py v4.12.0
SHA digest in image updated
Wrote 0x118690 bytes to file esp32c5-kismet-merged.bin, ready to flash to offset 0x0
```
So the documented command is:
```
cd firmware
idf.py merge-bin -o esp32c5-kismet-merged.bin      # -> firmware/build/esp32c5-kismet-merged.bin
```
(The 14:56 re-merge left no idf.py log. It was probably esptool run directly: UNVERIFIED. The result is verified as in §3.2.)

### 4.2 esptool directly (run inside `firmware/build/`)
- **esptool v4** (4.12.0, the one ESP-IDF 5.5 ships): subcommands exist **only with underscores**: `merge_bin`, `write_flash`, `read_flash`, `erase_flash`. Flash options are `--flash_mode/-fm`, `--flash_freq/-ff`, `--flash_size/-fs` [run: `esptool/__init__.py` 4.12.0 lines 276-305, 328, 579, 646].
  ```
  python -m esptool --chip esp32c5 merge_bin -o esp32c5-kismet-merged.bin @flash_args
  ```
- **esptool v5** (5.4.0 checked): subcommands are hyphenated (`merge-bin`, `write-flash`, `read-flash`, `erase-flash`). The v4 underscore names are **still accepted, with a "Deprecated: Command '…' is deprecated" warning** [run: 5.4.0 `cli_util.py:301-315`]. `--flash_mode/--flash_freq/--flash_size` are also accepted with a warning (mapped to `--flash-mode` etc.), and `--fill-flash-size` has become `--pad-to-size` [cli_util.py:262-270].
  ```
  esptool --chip esp32c5 merge-bin -o esp32c5-kismet-merged.bin @flash_args
  ```
- **Portable spelling:** the underscore forms (`merge_bin`, `write_flash`, `read_flash`) work on v4 and v5 (v5 warns). The hyphen forms work on v5 only.
- **Portable invocation:** `python -m esptool` works with both. The console-script name differs: v4 packages register `esptool.py` [run: 4.12.0 `entry_points.txt`], while v5 uses `esptool`. Which names are on PATH in a given shell: UNVERIFIED.

---

## 5. Flashing

### 5.1 From source with ESP-IDF
```
cd firmware
idf.py -p <PORT> flash          # e.g. COM14, /dev/ttyACM0
```
- Writes bootloader (0x2000), partition table (0x8000) and app (0x10000) with `dio / 80m / 2MB`, `--before default_reset --after hard_reset` [build/flasher_args.json].
- idf.py's default baud is **460800** (env `ESPBAUD`) [serial_ext.py:29-36].
- It does **not** write the NVS region, so the board **keeps its stored radio** (§8).
- `idf.py monitor` on the native USB port shows the binary capture stream, not logs. The logs are on UART0 (§7.3).

### 5.2 Prebuilt merged image at 0x0
```
# esptool v4 (ESP-IDF 5.5 environment)
python -m esptool --chip esp32c5 -p <PORT> -b 460800 write_flash 0x0 esp32c5-kismet-merged.bin
# esptool v5 (pip install esptool)
esptool --chip esp32c5 -p <PORT> -b 460800 write-flash 0x0 esp32c5-kismet-merged.bin
```
- Offset **0x0**. The file already has the bootloader at +0x2000 [§3.2].
- esptool's own default baud is **115200** (env `ESPTOOL_BAUD`) [4.12.0 `__init__.py:128-132`, `loader.py:263`]. On the native USB-Serial-JTAG port the baud value does not set the link speed (the C helper's comment: "The USB-Serial-JTAG port ignores the speed" [capture_esp32c5.c:583-585]; the Python helper: "ignored by the USB-Serial-JTAG port" [board.py:369]). Whether a higher `-b` speeds up flashing here: UNVERIFIED. `-b 460800` matches idf.py and is safe.
- esptool recognises PID 0x1001 and uses its USB-Serial-JTAG reset sequence by itself [4.12.0 `loader.py:299, 738-739`], so no BOOT button is needed normally.
- **Flashing the merged image resets the stored radio to Wi-Fi.** The image is 0xFF from 0x8C00 to 0x10000, which covers the whole NVS partition (0x9000–0xF000) and phy_init (0xF000) [run: byte check]. With NVS blank, `load_mode()` returns Wi-Fi [FW:1225-1238]. This follows from the image contents; it was not tested on a board.
- A `write_flash` of a 2 MB-header image onto a bigger flash is fine. `write_flash` keeps the header's flash parameters by default (4.12.0 `add_spi_flash_subparsers(..., allow_keep=True)`).
- **Stop Kismet or the helper first.** esptool opens the port with `exclusive=True` [4.12.0 `loader.py:342-344`; 5.4.0 `loader.py:444`], and both helpers hold an exclusive `flock` on it while they run [capture_esp32c5.c:555-571; board.py:391-400]. On Linux one of them will fail to open the port. On Windows a COM port is always one-process-only [board.py:356-361]. Exact esptool error text: UNVERIFIED.
- The Docker image contains no firmware and no flashing tools. `.dockerignore` lets in only `kismet/`, `docker/`, `tools/fake_board.py`; a grep of `Dockerfile`, `entrypoint.sh`, `compose.yaml` and `docker.yml` finds no `esptool`, `flash` or `firmware`. Flash from a host.

### 5.3 Board quirks after flashing (from SIB, same boards)
- "Some boards come up latched in download mode and never run the new firmware. Unplug it and plug it back in, or press its BOOT button once. This is a quirk of the board, not the firmware — it happened on two of the three boards this tool was developed against." [SIB docs/index.html, "If the board does not start sniffing after flashing"]
- Use a **powered** USB hub for several boards: "an unpowered one browns out under four sniffers and produces failures that look like firmware bugs" [SIB README.md:19-21]. Also use a known-good data cable [SIB docs/index.html Troubleshooting].
- Hardware seen in SIB: Seeed Studio XIAO ESP32C5, four on a powered USB 3.0 hub [SIB README.md:17-19]. Flash size of that board: UNVERIFIED (only ≥2 MB matters).

### 5.4 The sibling's browser flasher (for context)
- URL `https://oshri-almog.github.io/esp32c5-wireshark-sniffer/`. It uses ESP Web Tools **10.4.0** from unpkg [SIB docs/index.html `<script ... esp-web-tools@10.4.0 ...>`].
- Manifest [SIB docs/manifest.json]: name "ESP32-C5 Wireshark Sniffer", `"version": "1.2.0"`, `"new_install_prompt_erase": true` (it offers to erase the whole flash), one part `firmware/esp32c5-sniffer-1.2.0-merged.bin` at offset 0, `chipFamily "ESP32-C5"`.
- Browsers: "Chrome / Edge 89+, Firefox 151+, Chrome for Android. Not Safari." [SIB docs/index.html].
- This repo has **no flasher page and no published binary**. `firmware/build/` is git-ignored, so `esp32c5-kismet-merged.bin` is not in the repo. See open questions.

---

## 6. Backup, restore, erase

```
# back up everything that is on the board now (v4 / v5)
python -m esptool --chip esp32c5 -p <PORT> read_flash 0 ALL backup.bin
esptool --chip esp32c5 -p <PORT> read-flash 0 ALL backup.bin
# put it back
python -m esptool --chip esp32c5 -p <PORT> write_flash 0x0 backup.bin
# wipe (also forgets the stored radio)
idf.py -p <PORT> erase-flash      |  python -m esptool --chip esp32c5 -p <PORT> erase_flash  |  esptool ... erase-flash
```
- `read_flash <address> <size> <file>`; `ALL` = "read to the end of flash" [4.12.0 `__init__.py:579-593`; 5.4.0 `read-flash` `__init__.py:1055-1077`].
- How long a full read of a 4–16 MB flash takes over USB-Serial-JTAG: UNVERIFIED.

---

## 7. USB and UART

### 7.1 Native USB (the host link)
- USB VID `303A`, PID `1001`: the Espressif USB-Serial-JTAG ID. **Every** Espressif chip with native USB-Serial-JTAG shares it (ESP32-C3, C5, C6, H2, S3, P4 …), so a host cannot tell a C5 sniffer from another ESP32 by USB ID [capture_esp32c5.c:74-81; board.py:450-453].
- The board reports its **MAC as its USB serial number**. Both helpers use it to recognise a board across re-enumeration [capture_esp32c5.c:67-72, 328-362]. Which of the chip's MACs it is: UNVERIFIED.
- Port names: `COMn` (Windows), `/dev/ttyACMn` (Linux), `/dev/cu.usbmodem…` (macOS), `cuaU0` style (BSD) [capture_esp32c5.c:39-44, 433-436].
- DTR/RTS drive reset and boot mode on this port. "Releasing DTR while RTS is still up resets it" [capture_esp32c5.c:593-599]. pyserial's defaults "can reboot the chip or leave it in the ROM download mode" [board.py:372-373]. So a serial terminal that toggles the lines may reset the board or put it in download mode. Behaviour of specific terminals: UNVERIFIED.
- The line settings are ignored on this port (any baud works) [capture_esp32c5.c:583-586].
- The firmware installs the driver with TX buffer 32768 and RX buffer 256 [FW:69, 1097-1101]. It stops ROM `printf` from mirroring to USB (`esp_rom_install_channel_putc(2, NULL)`) [FW:1094-1095].
- Text before the first marker: the helpers ignore everything before `<<START>> <their nonce>` ("Anything before it is boot text or an older stream" [capture_esp32c5.c:921-922]). Whether the ROM prints boot text on the USB port at reset: UNVERIFIED.

### 7.2 Reboots and the USB port
- When the board reboots (on `MODE` to another radio), "its USB port usually stays up through that, but it can also go away" [capture_esp32c5.c:65-67]. tty names can swap between boards that reboot together [capture_esp32c5.c:69-71].
- From `MODE` to the boot marker is about **0.53 s** on the real board, with the port staying open [tools/fake_board.py:47-48 `REBOOT_S = 0.53`, comment "From MODE to the boot marker on the real board"]. Both helpers wait `MODE_SETTLE_S = 0.8` s before `START` [capture_esp32c5.c:159-162; board.py:64-67] — IN FLUX (helper constants).

### 7.3 UART0 logs
- 115200 8N1, TX GPIO11, RX GPIO12. On devkits this is the "UART" USB connector [sdkconfig.defaults:4-6]. On boards with only the native USB-C (e.g. XIAO ESP32C5) you need a USB-UART adapter on those pins. Which header pins that is on the XIAO: UNVERIFIED.
- Log level INFO [run: sdkconfig:2047-2050]. Tag `sniffer`. Format `I (<ms since boot>) sniffer: <text>`.
- Standard ESP-IDF boot lines include `app_init: App version:      <ver>`, `Project name:     esp32c5_sniffer`, `Compile time:     <date> <time>` [run: strings in esp32c5_sniffer.bin]. This is how to read the firmware version (§16.5).
- All firmware messages are listed in §9.7.

---

## 8. Boot sequence and the stored radio

- NVS namespace **`sniffer`**, key **`mode`**, type u8: `0` = Wi-Fi, `1` = 802.15.4, `2` = BLE [FW:265-270, 275-276, 1248].
- Missing namespace, missing key, read error or value > 2 → **Wi-Fi**. "A board that has never been told reports Wi-Fi, so firmware flashed onto a fresh board comes up as a Wi-Fi sniffer" [FW:1223-1238].
- If `nvs_flash_init` reports no free pages or a new NVS version, the NVS partition is erased and re-initialised [FW:1263-1268]. That also forgets the mode.
- `app_main` order [FW:1259-1316]:
  1. USB driver install.
  2. NVS init, default event loop.
  3. Load mode and set the link type in the PCAP global header (127 / 283 / 256).
  4. Ring buffer (`SNIFFER_RINGBUF_SIZE`, NOSPLIT), a start queue of length 1, the scan mutex; `out of memory` + abort on failure.
  5. Default channel list for the mode (§10.4).
  6. Writer task (prio 6, stack 4096). **It immediately sends `"\n<<START>>\n"` + a PCAP global header, with no nonce, timestamps counting from boot** ("Sent once at boot like the Arduino sketch did, so resetting the board also (re)starts a capture" [FW:691-693]).
  7. **Only the radio of this boot is initialised**; the other drivers never start [FW:1295-1301].
  8. Hop task (prio 4), command task (prio 5).
  9. Log `capturing with the <Wi-Fi|802.15.4|Bluetooth LE> radio`.
  10. A status line every 10 s (§13.4).
- Why one radio per boot: switching at runtime "leaves the PHY in a state that no reset clears: two boards switched to 802.15.4 and back captured no Wi-Fi at all afterwards … until they were physically unplugged" [FW:257-264]. In the sibling's measurements, nine of nine mode flips across two boards left Wi-Fi working with this design [SIB commit 8af9077 message].
- Wi-Fi init [FW:1104-1137]: `WIFI_STORAGE_RAM`, mode `WIFI_MODE_NULL` ("receive only", no beacons), start. Band mode set to AUTO (dual) if different. If NVS (left by other firmware) holds a MANUAL country policy, country `"01"` is set with `ieee80211d_enabled=true`, "otherwise [it] would restrict the hop list to that country's channels" [FW:1129-1134]. Then promiscuous mode (§11.3).
- 802.15.4 init [FW:1165-1173]: enable, promiscuous on, coordinator off, rx-when-idle on, channel 15, receive.
- BLE init [FW:1216-1221]: NimBLE port init; on host sync, log `Bluetooth controller ready, scanning all three advertising channels` and start a passive scan [FW:1204-1208].

---

## 9. The line protocol (host → board)

### 9.1 General rules [FW:734-741, 864-891]
- ASCII lines ending in `\n`. Tokens are separated by space, tab or `\r`, so CRLF is fine. Empty lines are ignored.
- **Command words are case-sensitive** (`strcmp`): `START`, `CHANNELS`/`CHANNEL`, `DWELL`, `MODE`, `TXTEST`. A lowercase `start` gets `unknown command 'start'`. `MODE` arguments and `AUTO` are case-insensitive (`strcasecmp`).
- Maximum line: **255 characters** before the `\n` (buffer `char line[256]`). A longer line is **ignored entirely, silently**, up to the next newline [FW:866-889]. (The sibling's 1.2.0 firmware: 63 characters — §16.)
- The board **answers nothing on USB** except to `START`. Every other result (accepted, refused, error) shows up **only as a log line on UART0**. A refused command leaves the previous state unchanged.
- Commands are handled in the order received by one task. `TXTEST` blocks that task while it transmits (§9.6).

### 9.2 `START [<unix time in µs>|0] [<nonce>]` [FW:13-14, 742-757, 658-713]
- **Time argument:** decimal digits only (the whole token must parse), non-zero, ≤ INT64_MAX. When valid, the board sets its clock offset so that from now on packet timestamps are wall-clock: `offset = epoch_us − esp_timer_now` [FW:681-683]. When absent, `0` or invalid, the offset is **left as it was**. After an earlier `START` with a time, `START 0` keeps wall-clock time; after boot, the offset is 0 and timestamps count from boot.
- **Nonce:** 1–16 characters, `[0-9A-Za-z]` only. Anything else is ignored, and the answer then carries no nonce [FW:719-732, 754-756]. To send a nonce without a time, use `START 0 <nonce>`.
- **Effect:**
  1. The request goes into a length-1 queue with overwrite, so of several `START`s close together only the last one counts [FW:757].
  2. The writer task picks it up within about 100 ms (its ring-buffer wait) [FW:695-702].
  3. It **discards every frame already buffered** ("Frames captured before the restart belong to the previous stream") [FW:673-680].
  4. It applies the time.
  5. It sends the answer as one write.
- **Answer** (one USB write, 1 s timeout) [FW:658-671]:
  - with a nonce: `"\n<<START>> <nonce>\n"` followed immediately by the 24-byte PCAP global header;
  - without: `"\n<<START>>\n"` + the header.
  - Note the **leading `\n`**.
  - Then PCAP records follow (§11).
  - If the write fails (nobody reading): UART warning `start marker not sent, is the host reading the port?` [FW:684-686].
  - UART info on every host START: `stream restarted by host` or `stream restarted by host, clock synchronised` [FW:697].
- The helpers send `START <gettimeofday µs> <8 lowercase hex chars>`, preceded by `CHANNELS <n>` in the same write [capture_esp32c5.c:646-665] — IN FLUX (helpers).

### 9.3 `CHANNELS <spec>` (alias `CHANNEL`) [FW:15-17, 758-770, 959-1018]
- `CHANNELS` with no argument, `CHANNELS 0` or `CHANNELS AUTO` (any case) → the **built-in list** of the current radio (§10.4). In this build that means: Wi-Fi **6 only**, 802.15.4 **11–26**, BLE **37**.
- Otherwise `<spec>` is parsed as described in §10.5. If it parses, it **replaces the scan list** at once. The index goes back to the first entry, the "refused" marks are cleared, the hop task is woken ("apply now instead of at the end of the current dwell"), and UART logs `scanning <n> channel(s): <list>` [FW:999-1018].
- A spec that does not parse → UART `cannot use channel list '<spec>'`, and the old list stays [FW:766-768].
- A list of **one** channel is a **lock**: tuned once, then left alone. If the driver refuses it, it is retried **every 1 s** (with a `channel <n> not set: <err>` warning each time) "in case the band mode is still settling" [FW:1059-1065].
- A list of several channels **hops**: `dwell` ms on each, in the order given. A channel the driver refuses is logged once and **skipped for the rest of this list** ("not allowed by the band mode or the regulatory domain") [FW:1066-1080].
- In BLE mode the only valid list is `37`. The hop task's first tune at boot calls `ble_start_scan()` [FW:1034-1038]; the scan also starts when the controller syncs [FW:1204-1208]. After that, `s_channel` is already 37, so a later `CHANNELS 37` changes nothing (the hop task only tunes when `s_channel` differs [FW:1062-1064]).
- Not stored: the list goes back to the built-in one at every boot.

### 9.4 `MODE WIFI|802154|BLE` [FW:19-22, 771-813]
- Accepted words, case-insensitive: `WIFI`; `802154`, `ZIGBEE`, `THREAD`; `BLE`, `BT`, `BLUETOOTH`. `802.15.4` with dots is **not** accepted (→ `unknown mode '802.15.4'`).
- No argument → UART `MODE needs WIFI or 802154` (the message omits BLE; see §17). Unknown word → `unknown mode '<word>'`.
- **Same radio as now → nothing happens**, no reboot ("the common case, and free") [FW:793-795].
- **Another radio:**
  1. Shut the current radio down cleanly: 802.15.4 `esp_ieee802154_disable()`; BLE `ble_gap_disc_cancel()` + `nimble_port_stop()`; Wi-Fi promiscuous off + `esp_wifi_stop()`.
  2. Write the new mode to NVS.
  3. Log `restarting to capture with the <radio> radio`.
  4. Wait 50 ms, then `esp_restart()` [FW:796-813].
  - The board comes back about 0.5 s later (§7.2) and sends its boot marker (no nonce) and a header in the new link type.
- **Send `MODE` before `START`.** The mode decides the link type [FW:772-774], and anything sent while the board reboots is lost [capture_esp32c5.c:159-162].
- If NVS cannot be written: `cannot open NVS to remember the mode: <err>` or `cannot remember the mode: <err>`. It **still reboots**, and comes back in the old mode [FW:1240-1257].
- The stored mode survives resets, power cycles and `idf.py flash`. It is cleared by flashing the merged image at 0x0, by `erase_flash`, and by the web flasher (§5.2, §5.4).

### 9.5 `DWELL <ms>` [FW:18, 848-858]
- Time on each channel of a multi-channel list. Accepts **20–60000** (`MIN_DWELL_MS`/`MAX_DWELL_MS` [FW:57-58]). Decimal digits only (e.g. `250ms` is refused).
- **Default 250 ms** (`CONFIG_SNIFFER_HOP_INTERVAL_MS` [Kconfig:12-15; run: sdkconfig:710]). Not stored: 250 again after every boot.
- Takes effect at once (hop task woken). UART `dwell time <ms> ms`. Out of range or malformed → `DWELL needs a time in ms between 20 and 60000`.
- No effect on a single-channel lock, which re-checks every 1000 ms whatever the dwell [FW:1065].

### 9.6 `TXTEST [n]` [FW:814-847]
- **The only command that makes the board transmit.** Sends 802.15.4 test frames "so a second board can prove the receive path works even when there is no Zigbee or Thread hardware around" [FW:815-816].
- **802.15.4 mode only**. Otherwise UART `TXTEST only works in 802.15.4 mode` and nothing is sent.
- `n` defaults to **10**. It is parsed with `atoi`, and **anything outside 1–1000 (including non-numbers and e.g. 5000) becomes 10**, not an error.
- Each frame, sent **20 ms apart** with CCA off (`esp_ieee802154_transmit(frame, false)`):
  - FCF bytes `41 88` (data frame, PAN ID compression, short dst/src addresses)
  - sequence = i (low byte)
  - dst PAN `0x1234`, dst addr `0xFFFF` (broadcast), src addr `0x0001`
  - payload `"esp32c5-wireshark-sniffer self test"` plus its terminating NUL (36 bytes)
  - hardware-appended FCS
  - PHY length byte 47.
- Sent on the channel the board is on **at that moment**. With the default 802.15.4 list the board is hopping 11–26, so lock a channel first (e.g. `CHANNELS 15`) for a clean test.
- Blocks the command task for n × 20 ms (up to 20 s). A transmit error stops the loop: `transmit failed: <err>`. At the end: `sent <n> test frames on channel <ch>`. This prints the **requested** count even when the loop stopped early.
- What happens to commands sent during a long TXTEST (USB RX buffer 256 bytes): UNVERIFIED.
- Measured in SIB: "200 of 200 transmitted frames received on each of five channels" [SIB commit 8af9077].

### 9.7 Every firmware log message (UART0, tag `sniffer`) [FW, cited lines]
| Level | Text | When |
|---|---|---|
| I | `capturing with the Wi-Fi radio` / `802.15.4` / `Bluetooth LE` | boot [1305-1307] |
| I | `<radio> ch <ch> of <count> (<dwell> ms) \| captured <n> \| dropped: buffer <n>, usb <n>, oversize <n>` | every 10 s [1309-1315]; `<ch>` is `%3u`, e.g. `Wi-Fi ch   6 of 1 (250 ms) \| captured 1234 \| dropped: buffer 0, usb 0, oversize 0` |
| I | `scanning <n> channel(s): <a,b,c>` | new list [1014] |
| W | `cannot use channel list '<spec>'` | bad CHANNELS [767] |
| W | `channel <ch> not set: <esp_err name>` | driver refused a channel [1044] |
| I | `dwell time <ms> ms` | DWELL ok [858] |
| W | `DWELL needs a time in ms between 20 and 60000` | DWELL bad [853] |
| W | `MODE needs WIFI or 802154` | MODE without argument [778] |
| W | `unknown mode '<word>'` | [790] |
| I | `restarting to capture with the 802.15.4 radio` / `… the Wi-Fi radio` | MODE switch [809-810]; **prints "Wi-Fi" also when switching to BLE** (bug, §17) |
| E | `cannot open NVS to remember the mode: <err>` / `cannot remember the mode: <err>` | [1245, 1255] |
| W | `TXTEST only works in 802.15.4 mode` | [818] |
| W | `transmit failed: <err>` | [842] |
| I | `sent <n> test frames on channel <ch>` | [847] |
| W | `unknown command '<word>'` | [860] |
| I | `stream restarted by host` / `stream restarted by host, clock synchronised` | START [697] |
| W | `start marker not sent, is the host reading the port?` | [685] |
| I | `Bluetooth controller ready, scanning all three advertising channels` | BLE boot [1206] |
| W | `Bluetooth scan did not start: rc=<n>` | [1197]; may appear once at BLE boot if the hop task tries before the controller syncs (the scan then starts on sync) — UNVERIFIED whether it happens |
| E | `out of memory` | boot, then abort [1284] |

---

## 10. Channels

### 10.1 Wi-Fi: the 42 channels the firmware accepts [FW:317-322]
- 2.4 GHz: **1–14** (14 channels). Frequency `2407 + 5·ch` MHz; channel 14 = **2484** MHz [FW:381-382].
- 5 GHz, `5000 + 5·ch` MHz [FW:385]:
  - **36, 40, 44, 48, 52, 56, 60, 64** (8)
  - **100, 104, …, 144** (12)
  - **149, 153, 157, 161, 165, 169, 173, 177** (8)
- Total **42** [FW:340-342; run: python enumeration]. 36 = 5180 MHz; 177 = 5885 MHz.
- The **built-in 5 GHz hop list** (used only with `SNIFFER_CHANNEL_HOPPING=y`) is **25** channels: 36–64, 100–144, 149–165. It **leaves out 169, 173, 177** [FW:332-336]. Those three are reachable only by asking for them.
- 20 MHz only in 2.4 GHz (`WIFI_SECOND_CHAN_NONE`). "The driver picks [the secondary] itself in 5 GHz" [FW:1040-1041].
- Whether the driver actually accepts 14 and 169–177 on every board: the firmware skips refused channels (§9.3), and the sibling README claims "2.4 GHz channels 1–14 and 5 GHz 36–177" [SIB README.md:15]. Hardware acceptance of 14/169/173/177 in this build: UNVERIFIED.

### 10.2 802.15.4: channels **11–26** (16), page 0 [FW:182]
- Frequency `2405 + 5·(ch−11)` MHz (the C helper uses this for Kismet [capture_esp32c5.c:758]).
- Out-of-range channels are refused by the parser because the driver would assert and "panic the board" [FW:948-957, 1023-1026].

### 10.3 BLE: **37** only [FW:203-204, 954]
- The controller scans advertising channels **37, 38 and 39 together** and will not be restricted. NimBLE's `ble_gap_set_scan_chan()` says "Currently supported only for ESP32C2 chipset" [`C:\esp\v5.5.5\esp-idf\components\bt\host\nimble\nimble\nimble\host\include\host\ble_esp_gap.h:272`], and on the C5 the controller answers `BLE_ERR_UNKNOWN_HCI_CMD` [FW:1175-1184].
- So 37 stands for all three. `CHANNELS 38` or `39` is refused. `CHANNELS 37-39` gives `[37]`.

### 10.4 Start channels and built-in lists (what `0`/`AUTO` restores) [FW:897-931; sdkconfig.defaults:15-16]
| Radio | At boot | `CHANNELS 0`/`AUTO` | Helpers' initial channel [capture_esp32c5.c:233-235] |
|---|---|---|---|
| Wi-Fi | **locked on 6** (hopping is off in this build) | `6` | 6 |
| 802.15.4 | driver starts on 15 [FW:1171], but the built-in list is **11–26**, so the hop task at once **hops 11,12,…,26 at 250 ms** starting at 11 [FW:902-907, 1066-1080] | `11-26` | 15 |
| BLE | 37 (all three advertising channels) | `37` | 37 |

A host that sends nothing gets exactly this. The Kismet helpers always send `CHANNELS <n>` before `START`, so under Kismet the board sits on one channel at a time and Kismet hops by sending `CHANNELS <n>` [capture_esp32c5.c:57, 1450-1487] — IN FLUX (helpers).

### 10.5 Spec grammar [FW:959-997]
- `spec = item { "," item }`, `item = N | N "-" M`, decimal. **No spaces** inside the spec: the command is tokenised on spaces, so `CHANNELS 1, 6` reads only `1,` and gives `[1]`. A trailing comma is accepted.
- Every number must be **1–177**. `0` inside a list, or a number >177, makes the whole spec invalid (`0` on its own means AUTO).
- **A single number must be a valid channel of the current radio**, or the **whole spec is refused**. For example `CHANNELS 1,6,20` in Wi-Fi mode is refused because 20 is not a Wi-Fi channel.
- **A range keeps only the valid channels inside it** ("quietly"): `36-64` → 36,40,…,64. `1-177` → all 42 in Wi-Fi mode, 11–26 in 802.15.4 mode, 37 in BLE mode. A range needs `M ≥ N`. A range with no valid channel adds nothing, and the spec is refused only if the final list is empty.
- Duplicates are dropped, and the **order given is kept** (first occurrence).
- Capacity is **42 entries**. Going over refuses the whole spec rather than truncating it ("a channel is never dropped without the host hearing of it" [FW:933-946]). With duplicates removed this cannot happen with valid channels.
- Examples from the source: `6`, `1,6,11`, `1-11`, `1-13,36,149-165`, `11-26` (802.15.4) [FW:15, 759, 959].

---

## 11. The stream (board → host)

### 11.1 Framing
```
"\n<<START>>[ <nonce>]\n"           marker line (§9.2)
PCAP global header, 24 bytes          once per stream
{ PCAP record header, 16 bytes; payload } ...
```
- Little-endian throughout. The structs are written as they are on the little-endian ESP32-C5 [FW:75-92].
- **Global header** [FW:288-296]: magic `0xA1B2C3D4` (bytes `d4 c3 b2 a1`, µs timestamps), version **2.4**, thiszone 0, sigfigs 0, **snaplen 65535**, network = link type of the booted radio: **127** Wi-Fi, **283** 802.15.4, **256** BLE [FW:95, 138, 200, 1274-1278].
- **Record header**: `ts_sec u32, ts_usec u32, incl_len u32, orig_len u32`. **`incl_len == orig_len` always**; frames are never truncated [FW:428-431, 491-494, 590-593].
- **Every record is sent whole or dropped whole**, from one task, and a stream restarts only between records (or at a reboot). So "the stream never loses its framing" [FW:419-420, 707-710].
- The helpers resynchronise on the marker plus their own nonce and reject anything that is not a plausible record (`ts_usec < 1000000`, `0 < incl_len ≤ 16384`, `incl_len ≤ orig_len`) [capture_esp32c5.c:859-900] — IN FLUX (helpers).

### 11.2 Timestamps [FW:416-417, 646-656]
- Taken with `esp_timer_get_time()` (µs since boot, 64-bit) when the frame reaches the firmware (Wi-Fi driver callback, 802.15.4 ISR, BLE host task), not the on-air time. Converted to `sec/usec` just before sending, adding the offset from `START <time>` (§9.2).
- Without a `START` time they count from boot. The helpers always send wall-clock time.

### 11.3 Wi-Fi: link type 127, IEEE 802.11 + radiotap [FW:94-118, 365-442, 1139-1163]
- What is captured:
  - Promiscuous filter: management, data, data MPDU, data AMPDU, and control. Control frames need a second filter that "lets nothing through by default", so it is set to ALL: ACK, RTS, CTS, Block Ack, PS-Poll, CF-End [FW:1149-1157].
  - Not captured: MISC packets (no usable payload) and frames with `rx_state != 0` (RX errors / FCS failed) [FW:399-402, 1141-1144]. So a capture never contains bad-FCS frames.
- **FCS stripped**: `len = sig_len − 4`. Frames with `sig_len ≤ 4` are skipped. Frames longer than **11454** bytes after stripping count as "oversize" [FW:64-67, 404-414].
- **Radiotap header, 16 bytes** [FW:97-111, 366-390]:

| Offset | Field | Value |
|---|---|---|
| 0 | it_version | 0 |
| 1 | it_pad | 0 |
| 2 | it_len (u16) | 16 |
| 4 | it_present (u32) | **0x0000006A** = Flags (bit 1) + Channel (3) + dBm Antenna Signal (5) + dBm Antenna Noise (6) |
| 8 | Flags (u8) | 0 ("frame includes FCS" clear) |
| 9 | pad | 0 (aligns Channel) |
| 10 | Channel freq (u16, MHz) | see §10.1 |
| 12 | Channel flags (u16) | 2.4 GHz: `0x0080` + (`0x0020` CCK if the frame is 802.11b, else `0x0040` OFDM); 5 GHz: `0x0100` + `0x0040` |
| 14 | dBm antenna signal (i8) | `rx_ctrl.rssi` |
| 15 | dBm antenna noise (i8) | `rx_ctrl.noise_floor` |

  - Channel = `rx_ctrl.channel`, or the tuned channel if the driver reports 0 [FW:368].
  - The CCK/OFDM test uses `cur_bb_format == RX_BB_FORMAT_11B` on HE-capable chips (the C5) [FW:369-373].
  - **Not included:** rate/MCS, bandwidth, HT/VHT/HE fields, TSFT, antenna index.
- Max Wi-Fi record: 16 + 16 + 11454 = 11486 bytes [FW:278].
- The helpers pass Wi-Fi to Kismet unchanged as 127 [capture_esp32c5.c:855-856].

### 11.4 802.15.4: link type 283, IEEE 802.15.4 TAP [FW:124-183, 444-516]
- Why TAP: the radio gives **no FCS** (the hardware checks it, then overwrites those two bytes with RSSI and LQI). A link type claiming an FCS would make Wireshark mark every frame bad, and there is nowhere else to put the channel [FW:130-135].
- Payload = the MAC frame **without FCS**, `phy_len − 2` bytes, at most **125** [FW:180-181, 481-486]. Frames with PHY length ≤ 2 or too long count as "oversize" [FW:509-511].
- **TAP header, 48 bytes**, all TLVs padded to 4 bytes, `tap_len` counts the 4-byte preamble [FW:147-178, 451-477]:

| Offset | Content |
|---|---|
| 0 | version u8 = 0, reserved u8 = 0, tap_len u16 = **48** |
| 4 | TLV type 0 **FCS type**, len 1, value **0 = none**, 3 pad |
| 12 | TLV type 1 **RSS**, len 4, **float32 dBm** (from the driver's integer RSSI) |
| 20 | TLV type 3 **Channel assignment**, len 3: channel u16, page u8 = 0, 1 pad |
| 28 | TLV type 10 (0x0A) **LQI**, len 1, value, 3 pad |
| 36 | TLV type 5 **Start-of-frame timestamp**, len 8, u64 **ns** = driver timestamp (µs) × 1000 |

- The SOF timestamp is the driver's own µs clock ×1000. It is **not** shifted by `START <time>`; it is boot-relative, unlike the PCAP record time. The driver's clock base: UNVERIFIED.
- Captured in the radio's receive ISR (IRAM, FromISR ring-buffer call). The driver buffer is released on every path [FW:444-516].
- Whether frames that fail the hardware FCS check are ever delivered: UNVERIFIED (the comment says the hardware checks it).
- For Kismet the helpers unwrap it: Kismet "assumes a fixed 28 byte header", so the helper sends the bare frame as **LINKTYPE 230 (802.15.4, no FCS)** and puts channel and signal in Kismet's signal block [capture_esp32c5.c:57-61, 715-774] — IN FLUX (helpers).

### 11.5 BLE: link type 256, LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR [FW:185-255, 518-640]
- Record = **10-byte pseudo-header** + **4-byte access address** + **PDU** (2-byte header + payload) + **3-byte CRC**. `incl_len = 10 + 4 + n + 3`, where n ≤ 45, so at most 62 bytes [FW:586, 210].
- **Pseudo-header** (the same one Nordic's nRF sniffer produces) [FW:212-226, 608-616]:

| Offset | Field | Value |
|---|---|---|
| 0 | RF channel (u8) | **0** always: the RF index of advertising channel 37 (37→0, 38→12, 39→39 [FW:522-533]); "an advertising PDU labelled 37 is read as a data PDU and its type comes out Unknown" |
| 1 | signal (i8, dBm) | RSSI from the HCI report |
| 2 | noise (i8) | 0 (the noise-valid flag is not set) |
| 3 | access address offenses (u8) | 0 |
| 4 | reference access address (u32) | `0x8E89BED6` |
| 8 | flags (u16) | **`0x0C13`** = 0x0001 dewhitened + 0x0002 signal valid + 0x0010 ref. AA valid + 0x0400 **CRC checked** + 0x0800 **CRC valid** |

- Then the access address `0x8E89BED6` (bytes `d6 be 89 8e`).
- **PDU rebuilt from the HCI advertising report** [FW:535-584]:
  - PDU type from the event type: ADV_IND 0x0, ADV_DIRECT_IND 0x1, ADV_NONCONN_IND 0x2, SCAN_RSP 0x4, ADV_SCAN_IND 0x6.
  - TxAdd (bit 6) is set for a random or random-ID advertiser address. RxAdd (bit 7) is set for a directed advertisement with a random target.
  - **ChSel (bit 5) and RFU (bit 4) are always recorded clear**, because the report does not carry them.
  - Payload: AdvA (6 bytes, already in on-air order), then either TargetA (6 bytes, directed) or AdvData (≤31 bytes). Data over 31 bytes counts as "oversize".
- **CRC** [FW:228-255, 602-607, 625]: 24-bit, polynomial x^24+x^10+x^9+x^6+x^4+x^3+x+1, preset 0x555555 (0xAAAAAA in the reflected register), LSB first, sent least significant byte first.
  - It is **computed by the firmware** over the rebuilt PDU; the controller never hands over the received CRC. "The controller only reports advertising packets whose CRC checked out", so the flags are truthful.
  - Caveat: for ADV_IND / ADV_DIRECT_IND from devices using channel selection algorithm #2 (ChSel=1, "many BLE 5 devices"), the header is recorded with ChSel clear. The CRC then matches the **recorded** bytes, not the transmitted ones.
  - Why the flags matter: "Kismet relies on the flags: without them it checks the CRC itself and drops the packet when that fails, which a zeroed CRC always does."
- **Test vector** [tests/c/test_parser.c:639-643; run: recomputed in Python]: PDU `40 0e 11 22 33 44 55 c6 02 01 06 04 09 45 53 50` (ADV_IND, random address, flags + short name "ESP") → CRC **`f1 c0 26`**, "the one Wireshark's btle dissector accepts".
- **Scan** [FW:1185-1201]:
  - `ble_gap_disc` with **passive = 1** ("never transmit"), `filter_duplicates = 0` (every packet, not one per device), filter policy 0 (accept all), interval/window 0 ("let the controller choose; it then listens continuously" — the "continuously" is the comment's claim, UNVERIFIED), duration forever. Own address type public (never used, since nothing is transmitted).
  - **Legacy advertising only**: `CONFIG_BT_NIMBLE_EXT_SCAN` is not set [run: sdkconfig:907-908]. So BLE 5 extended advertising (ADV_EXT_IND/AUX_*, Coded PHY) is not captured. This is derived from the config, not tested on air: UNVERIFIED.
  - With a passive scan, SCAN_RSP normally does not occur (it is sent only in reply to a scan request, and this board sends none). The mapping exists anyway.
- Measured in SIB: "905 advertising packets in 20 seconds from 27 distinct advertisers, zero malformed" [SIB commit 7f260d4].

---

## 12. Data path, throughput and drops

- Path: radio callback → ring buffer (`SNIFFER_RINGBUF_SIZE` = 64 KiB, NOSPLIT; one item = one complete PCAP record) → writer task → USB driver TX buffer (32 KiB) → host [FW:7, 279-286, 419-440, 1280].
- **Throughput:** "The USB-Serial-JTAG link carries a few hundred kB/s" [Kconfig.projbuild:74-78]; the SIB README says the same [SIB README.md:163]. No measured figure exists in either repo: UNVERIFIED.
- **Drop behaviour** (whole records only; the stream stays valid) [FW:423-426, 501-505, 627-631, 707-710]:
  - `buffer`: the ring buffer is full (the host or USB cannot keep up, or a burst).
  - `usb`: `usb_serial_jtag_write_bytes` could not queue the whole record within **100 ms**. This is typical when **no host is reading**. The write is all-or-nothing (a ring-buffer send into a byte buffer; `C:\esp\v5.5.5\esp-idf\components\esp_driver_usb_serial_jtag\src\usb_serial_jtag.c:265-288`).
  - `oversize`: a frame too long for its format (§11.3–11.5).
- `START` flushes the ring buffer [FW:676-680].
- Control frames ("roughly one ACK per data frame") raise the drop rate on busy channels. `SNIFFER_CAPTURE_CTRL_FRAMES=n` turns them off [Kconfig.projbuild:70-78].
- **Counters are visible only on UART0**, in the 10-second status line (§9.7). Nothing reports them over USB, so Kismet cannot see board-side drops [SIB README.md:165 "Drop counters go to UART only"].
- Driver-side RX buffers: Wi-Fi static 24 / dynamic 64 / mgmt 10; 802.15.4 RX buffers 20 [defaults:22-24; run: sdkconfig:2020].

---

## 13. What the firmware never does
- Wi-Fi: mode NULL, promiscuous receive only, **no beacons, no probes, no association** [FW:1110-1111].
- BLE: observer role only, **passive** scan; never advertises, connects or pairs [sdkconfig.defaults:26-37; FW:1192].
- 802.15.4: promiscuous receive, not coordinator [FW:1167-1170]. Whether the driver sends automatic ACKs in promiscuous mode: UNVERIFIED.
- The **only** transmitter is `TXTEST` (§9.6). SIB README.md:104: "Nothing else ever transmits."
- It **stores only the mode**. Channel list and dwell are RAM only.
- **No firmware version query, no MAC query, no status over USB.**

---

## 14. Known limitations (for the docs; compared with SIB README "Known limitations" 157-171 and "Bluetooth LE" 125-148)

| Limitation | This firmware | SIB README says |
|---|---|---|
| One channel at a time per board (single tuner); use several boards for several channels | same | same (159-160) |
| One radio at a time; switching reboots (~0.5 s); the radio is chosen at boot | same | same (120-123) |
| A board remembers its radio. One left on 802.15.4 or BLE sends `<<START>>` + header at boot, then stays silent on Wi-Fi channels, which "reads as a hang". The Kismet helpers always send MODE, so this bites only with a serial terminal or other tools | same | same (166-168); SIB fix there is `--mode wifi`; here: `MODE WIFI` |
| A board that has run 802.15.4 can come back deaf to Wi-Fi; no reset clears it; unplug it. Rare, because the firmware shuts the radio down cleanly before rebooting | same code [FW:796-807] | same (169-171) |
| Malformed Wi-Fi frames: "the Wi-Fi driver reports some MIMO frames with metadata that does not match the payload" | same code | README: "a few per thousand" (161-162). **But** SIB commit 8af9077 reports "the same 2.5% malformed rate". The two SIB sources disagree; the rate for this build is UNVERIFIED |
| Throughput "a few hundred kB/s"; whole frames dropped on busy channels | same | same (163-164) |
| Drop counters only on UART0 | same | same (165) |
| No command replies over USB; a refused CHANNELS/DWELL is silent to the host | (derived from code) | not stated |
| BLE: advertising only, not connections; no Bluetooth Classic; for connections use an nRF52840 with Nordic's nRF Sniffer | same [FW:185-198] | same (132-138) |
| BLE: no channel choice (37/38/39 together); every packet recorded as channel 37 | same | same (142-147) |
| BLE CRC | **computed, flags "checked"+"valid" set (0x0C13)**; ChSel bit recorded clear, so for CSA#2 devices the CRC matches the recorded bytes | README: "no CRC … CRC flags are left clear" (146-148). **No longer true for this firmware** |
| BLE: legacy advertising only (no extended advertising) | derived from `CONFIG_BT_NIMBLE_EXT_SCAN` off — UNVERIFIED | not stated |
| 802.15.4: no FCS in the capture (hardware-checked) | same | implied |
| Wi-Fi radiotap has no rate/MCS/bandwidth fields | same | not stated |
| USB ID shared by all Espressif native-USB chips; the host cannot tell a C5 sniffer from another ESP32 | helpers' docs | README mentions VID/PID only |
| Firmware version not queryable over USB (UART boot log only) | same | not stated |

---

## 15. Numbers in one place
- Channels: Wi-Fi 42 (14 + 8 + 12 + 8); 802.15.4 16; BLE 1 (standing for 3).
- Line buffer 256 (255 chars usable); nonce 1–16 alphanumerics; DWELL 20–60000 ms, default 250; TXTEST 1–1000, default 10, 20 ms apart.
- Lock re-check 1000 ms; START queue depth 1; writer wait 100 ms; USB write timeout 100 ms; START answer write timeout 1000 ms; MODE pre-reset delay 50 ms; status line every 10 s.
- Header sizes: PCAP global 24, record 16, radiotap 16, TAP 48, BLE pseudo-header 10 + AA 4 + CRC 3.
- Max payloads: Wi-Fi 11454 (after FCS strip); 802.15.4 125; BLE PDU 45.
- Buffers: ring buffer 65536; USB TX 32768; USB RX 256.
- Task priorities: writer 6, command 5, hop 4; stacks 4096.
- Image: merged 1,148,576 bytes; app 1,083,040 in a 2,031,616-byte (0x1F0000) partition (47% free); bootloader 22,112 at 0x2000; flash ≥ 2 MB.

---

## 16. Compatibility with the sibling project's firmware

### 16.1 What the sibling's web flasher installs
- `esp32c5-sniffer-1.2.0-merged.bin`, 1,148,464 bytes, sha256 `12123896f9b3cf8514f4c032c93d836b53bf6c45fc813a784f17eab928a03eeb` [run: SIB docs/firmware].
- Its `esp_app_desc`: project `esp32c5_sniffer`, version **`5cdab32-dirty`**, compiled `Sep 18 2026 12:01:24`, IDF `v5.5.5` [run: parsed]. It was built from a working tree at 5cdab32 carrying the BLE work, which was committed as 7f260d4 (the commit that added the 1.2.0 binary) [run: `git log -- docs/firmware`].
- Same partition table as this repo (nvs 0x9000/0x6000, phy_init 0xF000/0x1000, factory 0x10000/0x1F0000) and the same flash header (DIO, 2 MB, 80 MHz) [run: parsed both images].
- SIB HEAD `firmware/main/esp32c5_sniffer.c` equals the source of 1.2.0. This is inferred (SIB tree clean, binary built from it, sizes differ by 112 bytes, in line with the CRC function); not byte-verified by rebuilding.

### 16.2 Source diff: SIB HEAD vs this repo (`diff` run on the two `esp32c5_sniffer.c` files)
Only these four changes. Kconfig, sdkconfig.defaults, partitions.csv and CMakeLists are identical apart from line endings (SIB CRLF, here LF). The resolved `sdkconfig` is identical.
1. **BLE CRC and flags.** 1.2.0 writes CRC `00 00 00` and flags **`0x0013`** (no "CRC checked"/"CRC valid"). This firmware computes the CRC and sets **`0x0C13`** [FW:225-255, 614-615, 625; SIB lines 575, 585].
2. **Command line length.** 1.2.0 `char line[64]` → **63 characters** max, longer lines silently ignored. Here `char line[256]` → 255 [FW:866-869].
3. **Scan list capacity.** 1.2.0 `MAX_SCAN_CHANNELS = 14 + 25 = 39`. Here **42** [FW:340-343].
4. **Overfull list.** 1.2.0 **silently truncates** a list at 39 (so `CHANNELS 1-177` in Wi-Fi mode loses **169, 173, 177**). Here a full list refuses the spec [FW:933-946, 977-985].

Everything else is the same: commands, marker, nonce rules, link types, record layouts, radiotap, TAP, BLE pseudo-header layout, NVS namespace/key/values, default channels (Wi-Fi 6 locked, 802.15.4 hopping 11–26, BLE 37), dwell default and limits, TXTEST (its payload says `esp32c5-wireshark-sniffer self test` in both).

### 16.3 Can a board flashed from the sibling's web flasher (1.2.0) be used with this project? **Yes, all three radios**, with these differences:
- **Wi-Fi and 802.15.4:** identical streams; works as is.
- **BTLE:** Kismet would drop every packet from 1.2.0 (flags clear, CRC zero). **Both helpers detect this** (flag 0x0400 clear), write the CRC into the last three bytes, set 0x0400|0x0800, and say so **once** per source:
  > `<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary`

  [capture_esp32c5.c:797-845; remote.py:442-459, 865-869]. A record that already says "checked" is passed on unchanged. Covered by `tests/c/test_parser.c:662-680` (flags 0x0C13 vs 0x0013) and `tests/kismet_e2e.sh:204-213` (`tools/fake_board.py --old-firmware`); whether those tests were run and passed here: UNVERIFIED by me. The message text and the Python side are IN FLUX (helpers).
- **Long channel lists and >39 channels:** no effect under the Kismet helpers, which send **one channel per `CHANNELS` line** (C: [capture_esp32c5.c:1475]; Python: host-side hopping calling `set_channels([ch])` [remote.py:25, 471-509, 839] — IN FLUX). It matters only when typing lists by hand (a line over 63 characters is ignored; more than 39 channels are cut to 39).
- **Mode memory:** both firmwares use NVS `sniffer`/`mode` with the same values. Switching firmware with `idf.py flash` keeps the radio; the web flasher or a merged-image write resets it to Wi-Fi (§5.2, §5.4).

### 16.4 The other direction
`CREDITS.md:11-12`: "The board speaks the same line protocol in both projects, so a board flashed for one works with the other." A board with this firmware used in Wireshark shows BLE packets with a real CRC and "CRC checked/valid". The SIB README's sentence that the CRC flags are left clear does not describe such a board. Not tested in Wireshark: UNVERIFIED (the CRC value was checked against Wireshark's dissector per test_parser.c:639-640 and CREDITS.md:28-29).

### 16.5 Older sibling firmware still on some boards (no longer offered by the flasher; the manifest lists only 1.2.0)
- **1.0.0** (SIB 62d4a8a): Wi-Fi only; commands START, CHANNEL(S), DWELL; **no MODE, no TXTEST**; line 64; default 1 MB app partition table [run: `git show 62d4a8a:firmware/...`].
- **1.1.0** (SIB 8af9077, rebuilt 5cdab32): Wi-Fi + 802.15.4; MODE WIFI|802154 (no BLE); default partition table [run: `git show`].
- With the Kismet helpers:
  - **Wi-Fi works** on both (`MODE WIFI` is logged `unknown command 'MODE'` by 1.0.0 and ignored; the stream is 127).
  - **zigbee** fails on 1.0.0, and **btle** fails on 1.0.0 and 1.1.0: the board keeps sending the old link type. The helper reports `<name>: lost sync (the board sends link type 127, not 256)` (or `… 283, not 256`), and after 15 s `<name>: no capture from the board on <device> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` [capture_esp32c5.c:1014-1019, 1165-1170]. Derived from code, not run. IN FLUX (helper texts).
- Upgrading 1.0.0/1.1.0 needs the new partition table: flash the **merged image at 0x0** (or `idf.py flash`), not an app-only write. SIB 7f260d4: "it reflashes the partition table, so existing boards need the merged image at 0x0 rather than an app-only update."
- **How to tell which firmware a board runs:** no USB command. Two ways:
  1. The UART0 boot log line `App version:` (this repo's current build: `1`; the SIB 1.2.0 image: `5cdab32-dirty`).
  2. Under Kismet, the one-time BTLE fix-up message above appears only with older firmware.

  A read-back plus `esptool image_info` would also work: UNVERIFIED as a procedure.

---

## 17. In-code documentation issues found (for the "documentation in the code" part; not edited)
1. FW:2 "streams a live PCAP capture to Wireshark (through SerialShark.py)" and FW:60 "The line SerialShark.py waits for" — describe the origin, not this project (Kismet helpers).
2. Kconfig.projbuild:9-10 help: `The host can override this at run time with the "CHANNEL <n>" command (SerialShark.py --channel).` — stale; the command takes a spec, and the hosts here are the Kismet helpers.
3. firmware/CMakeLists.txt:1 "dual-band Wi-Fi sniffer that streams a live PCAP to Wireshark over USB" — undersells three radios and Kismet.
4. FW:778 `MODE needs WIFI or 802154` — omits BLE.
5. FW:809-810 `restarting to capture with the %s radio` prints **"Wi-Fi" when switching to BLE** (the ternary only knows 802.15.4 vs Wi-Fi).
6. FW:826 TXTEST payload `"esp32c5-wireshark-sniffer self test"` — names the sibling project. Changing it is cosmetic, but it is visible in captures.
7. FW:847 `sent %d test frames` reports the requested count even after an early `break`.
8. Kconfig `SNIFFER_HOP_INTERVAL_MS` range 50–60000 vs runtime `DWELL` 20–60000 — inconsistent limits; worth a sentence in the docs or aligning.
9. `sdkconfig.defaults` begins with a UTF-8 BOM, which causes the kconfgen "ignoring malformed line" warning (§2.3).
10. FW header comment [12-22] does not mention `TXTEST`, and does not say that the board never answers except to START.
11. PROJECT_VER is not set, so builds from a commit-less tree say `1` and builds from a dirty tree say `<hash>-dirty` (the sibling had to rebuild 1.1.0 for exactly this, SIB 5cdab32).

---

## 18. Sources read
- Repo: `firmware/CMakeLists.txt`, `firmware/main/CMakeLists.txt`, `firmware/main/Kconfig.projbuild`, `firmware/main/esp32c5_sniffer.c` (all 1316 lines), `firmware/sdkconfig.defaults`, `firmware/partitions.csv`, `firmware/sdkconfig` (grep), `firmware/build/flash_args`, `firmware/build/flasher_args.json`, `firmware/build/project_description.json`, `firmware/build/CMakeCache.txt`, `firmware/build/log/*`, the three `.bin` parts and the merged image (parsed), `CREDITS.md`, `.gitignore`, `.gitattributes`, `.dockerignore`, `kismet/capture_esp32c5/capture_esp32c5.c` (all), `esp32c5_kismet/board.py` (parts), `esp32c5_kismet/remote.py` (grep), `tools/fake_board.py` (header), `tests/c/test_parser.c` (BTLE part), `tests/kismet_e2e.sh` (grep).
- Sibling: `README.md`, `CREDITS.md`, `docs/index.html`, `docs/manifest.json`, `docs/firmware/esp32c5-sniffer-1.2.0-merged.bin` (parsed), `firmware/*` (diffed), `git log` bodies, `git show` of 62d4a8a / 8af9077 / dae1c82 / 5cdab32 firmware.
- ESP-IDF: `C:\esp\v5.5.5\esp-idf\tools\idf_py_actions\serial_ext.py`, `...\soc\esp32c5\include\soc\uart_pins.h`, `...\bt\host\nimble\...\ble_esp_gap.h`, `...\esp_driver_usb_serial_jtag\src\usb_serial_jtag.c`, `...\esp_wifi\include\esp_wifi.h`; esptool 4.12.0 (`C:\Espressif\tools\python\v5.5.5\venv`) and 5.4.0 (`...\v6.1\venv`) sources.
