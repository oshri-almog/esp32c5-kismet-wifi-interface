# Fact sheet: the C capture helper (kismet_cap_esp32c5) and building Kismet with it

Gathered 2026-09-28, read-only. Repo: `esp32c5-kismet-wifi-interface` (working tree, no commits yet).
Kismet reference tree: upstream `kismetwireless/kismet` at `cfe427074b7ffcfcbc055a123c1df3b3cde60d59`
("Merge branch 'shrout1-ble-uuid-manufacturer-data'", 2026-09-16), unpatched, in the session scratchpad.

**Version of the helper this sheet describes:** `kismet/capture_esp32c5/capture_esp32c5.c` as of 17:31 local time,
1748 lines, sha1 `7a824c1c6d6c21d841b84770f37c68b9e6434a23`; `kismet/datasource_esp32c5.h` as of 17:28, sha1
`72df1a15f9debd8200be5169f21899b0cc1bc861`; `kismet/add-to-kismet.sh` as of 15:09, sha1
`03a165a5a46ca01fe38d6c74fb123f6e78852020`. The helper changed twice while this sheet was being written
(1596 lines at 15:03 -> 1746 at 17:23 -> 1748 at 17:31, the last only a comment); if the hash differs when you
write, re-check the IN FLUX items, the messages and the line numbers.

Citations:
- `c:NNN` = `kismet/capture_esp32c5/capture_esp32c5.c` line NNN (the 1748-line version).
- `ds:NNN` = `kismet/datasource_esp32c5.h`, `add:NNN` = `kismet/add-to-kismet.sh`, `mk:NNN` = `kismet/capture_esp32c5/Makefile.in`.
- `T:NNN` = `tests/c/test_parser.c` (17:23 version).
- `K/file:NNN` = file in the upstream Kismet tree at cfe427074.
- `Dockerfile:NNN`, `entrypoint:NNN`, `compose:NNN` = `docker/Dockerfile`, `docker/entrypoint.sh`, `compose.yaml`.
- "Pi run" = the Raspberry Pi build/test workflow of 2026-09-28 (result in the session transcript; logs in the
  scratchpad `e2e/*.log`, `pi-run-notes.txt`). It ran an **older build of the helper**; message texts in its logs that
  are quoted below are ones the current code still produces. "WSL run" = WSL2 Ubuntu 24.04 (`scratchpad/cfix/*`).

Markers: **IN FLUX** = may change before the docs are published (another workflow is editing the helpers).
**UNVERIFIED** = read from code or inferred, not confirmed by a run. Everything else is quoted from the code at the
lines given or was observed in the run named next to it.

---

## 0. Status of the code, and what is in flux

The C helper is in final review in another workflow.

| # | Item | State (17:31 version) | Doc impact |
|---|------|-------|-----------|
| F1 | A definition named the helper's way whose board cannot be found right now (bare `esp32c5`, `esp32c5-kitchen`, `esp32c5zigbee`, `esp32c5btle` ... with no board or several) | **Now in the code, still in review (IN FLUX).** Probe claims it (local sources only), so the open reports the real reason and Kismet retries every 5 s (c:57-65, 1440-1446; tests T:1082-1133; a new e2e case "a bare esp32c5 with no board plugged in", tests/kismet_e2e.sh header). **UNVERIFIED on hardware** and in the e2e run (the e2e case was added at 17:27; no run result seen). Before this change: Kismet said only `Unable to find driver for '<definition>'...` and never retried; `type=esp32c5` was the workaround. | Troubleshooting, source definitions |
| F2 | TIOCEXCL on the port, so the lock also holds between a container and the host, or between two containers | **Proposed, not in the code.** The lock is `flock` only (c:678-694; the comment still says "unlike TIOCEXCL it also holds against a helper running as root"). flock does not cross the container boundary: each container makes its own `/dev/ttyACMn` node, a different inode (Docker review, transcript ~14:16Z). | Docker page, one-radio-at-a-time |
| F3 | Drop all capabilities instead of Kismet's `cf_drop_most_caps` | **Proposed, not in the code** (c:1743 still calls `cf_drop_most_caps`). Today that call is why a container running the helper needs `NET_ADMIN` (compose:40-43, entrypoint:134-137). If F3 lands, NET_ADMIN is no longer needed. | Docker page, security |
| F4 | The Python helper is being changed to match | IN FLUX (see the Python fact sheet). | Cross-references |
| F5 | Every user-visible message text below | Exact for the 17:31 version; treat as IN FLUX until review ends. | Quote sparingly |

---

## 1. What the pieces are

- Binary: `kismet_cap_esp32c5` (mk:5; `set_int_source_ipc_binary("kismet_cap_esp32c5")` ds:55).
- Kismet source type: `esp32c5` (ds:95; `cf_handler_init("esp32c5")` c:1711).
- Description Kismet shows: `ESP32-C5 sniffer board: Wi-Fi (2.4/5 GHz), 802.15.4, or BTLE advertising` (ds:96).
- Builder flags (ds:98-104): probe yes, list yes, local yes, remote yes, passive **no**, tune yes, hop yes.
- The server side has no packet code; the helper hands Kismet link types it already decodes; the DLT is set per
  source by the open report because it follows the radio (ds:38-44).
- Licence: `kismet/` is GPL-2.0-or-later (kismet/COPYING.md; Kismet's GPL header in each file; `SPDX-License-Identifier:
  GPL-2.0-or-later` add:2). Rest of the repo MIT.
- Modelled on Kismet's `capture_freaklabs_zigbee_v2` and `capture_catsniffer_zigbee` (CREDITS.md).

---

## 2. Source definitions

Kismet syntax: `interface:flag=value,flag=value`; the interface runs to the first `:` (K/capture_framework.c:139-154);
flag names match case-insensitively; a value may be double-quoted (K/capture_framework.c:156-209). Colons inside a
value are fine; the Pi runs used
`esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:D8:0C-if00,mode=zigbee,name=c5-zigbee`
(`Found type 'esp32c5' ... launched successfully`, e2e/t1mix.log:64-66).

### 2.1 The forms (header c:30-46; tests T:723-746, T:1087-1102)

| Definition | Meaning |
|---|---|
| `esp32c5-ttyACM0` | board on `/dev/ttyACM0`, Wi-Fi |
| `esp32c5zigbee-ttyACM0` | same board, 802.15.4 (Zigbee/Thread) |
| `esp32c5btle-ttyACM0` | same board, BTLE advertising |
| `esp32c5-ttyACM0:mode=zigbee` | 802.15.4: `mode=` wins over the name |
| `esp32c5zigbee-ttyACM0:mode=wifi` | Wi-Fi (mode= wins) |
| `esp32c5:device=/dev/ttyACM1,mode=btle` | any name, explicit device |
| `esp32c5` | the only board plugged in (Linux) |
| `esp32c5zigbee`, `esp32c5btle` | the only board plugged in, that radio |
| `esp32c5-kitchen` | a name, not a port: the only board plugged in, or add `device=` |
| `esp32c5-kitchen:device=/dev/ttyACM3`, `esp32c5btle:device=/dev/ttyACM3` | explicit device |
| `esp32c5ble-ttyUSB1`, `esp32c5thread-ttyACM2`, `esp32c5802154-ttyACM2` | radio aliases in the name |
| `esp32c5-cu.usbmodem1101` | macOS `/dev/cu.usbmodem1101` |
| `esp32c5-cuaU0` | FreeBSD/OpenBSD `/dev/cuaU0` |
| `esp32c5zigbee-dtyU0` | NetBSD `/dev/dtyU0` |
| `esp32c5-pts/7` | `/dev/pts/7` (pseudo-terminal; the tests use it with the fake board) |
| `esp32c5-serial1`, `esp32c5-watchdog`, `esp32c5zigbee-null`, `esp32c5-pts/../watchdog` | **names, not ports**: `/dev/serial1` (the Pi's Bluetooth UART), `/dev/watchdog` (reboots the machine if opened and not properly closed) etc. are never opened; these look for the only board like `esp32c5-kitchen` (c:469-489, T:738-741) |
| `esp32c5-ttyACM0:mode=lte` | refused: `esp32c5-ttyACM0: mode must be wifi, zigbee or btle` |
| `esp32c5-ttyACM0:channel=15` | refused: 15 is not a Wi-Fi channel (2.2 step 3) |
| `wlan0` | not ours |

### 2.2 Parsing rules, in order (parse_definition c:1385-1424)

1. **Ours or not** (c:1395-1402): the interface must start with the exact, case-sensitive text `esp32c5`. Otherwise
   "not ours" (`not an esp32c5 source`; in open `not an esp32c5 source definition`, c:1520).
2. **Radio** (parse_mode c:312-324, words c:287-292): `mode=` with a non-empty value decides; accepted words,
   case-insensitive: `wifi`; `zigbee`, `802154`, `802.15.4`, `thread`; `btle`, `ble`, `bluetooth`. Anything else:
   `<interface>: mode must be wifi, zigbee or btle` (c:1406). Without `mode=`, the text between `esp32c5` and the
   first `-` is read with the same words; empty (`esp32c5-ttyACM0`, bare `esp32c5`) or not a radio word
   (`esp32c5kitchen`) means **Wi-Fi**.
3. **`channel=`** (parse_channel c:345-374), checked in probe and open, before the port is touched: plain decimal
   digits only (`+6`, `abc` refused), at most 177, a channel the radio can tune to (section 5); BTLE accepts 37, 38 or
   39 and stays on 37. Error: `<interface>: channel=<value> is not a channel the board can tune to in <wifi|zigbee|btle> mode`
   (c:367-368). It is where the source starts; with `channel_hop=false` where it stays. Kismet itself only adds
   `channel=` to the hop list and never tunes to it (K/kis_datasource.cc:1863-1869), which is why the helper does it.
   History: the Pi run found the older helper ignored `channel=` (`channel_hop=false,channel=20` stayed on 15; 0 of 200
   test frames; pi-run-notes.txt:6). Fixed since; covered by T and by tests/kismet_e2e.sh; **UNVERIFIED on hardware.**
4. **Device** (resolve_device c:491-533), first match wins:
   1. `device=` value, as given, no existence check (c:501-502). A `/dev/serial/by-id/...` link works.
   2. The part after the first `-`, if it is a serial port name (serial_name c:469-489): starts with `tty`, `cu.`,
      `cua`, `dty` or `pts/`, and contains no `..`. Taken as `/dev/<part>` as written, not checked for existence, "so
      that a board that is rebooting right now is waited for rather than swapped for another" (c:476-477).
   3. Otherwise the only Espressif USB-Serial-JTAG device plugged in (Linux sysfs). Messages:
      - none: `no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition` (c:522-523)
      - several: `<n> Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-<first tty>` (c:525-527)
      - no sysfs: `finding a board by itself needs Linux sysfs (/sys/class/tty), which this system does not have; name the port with device=/dev/... or a source name like esp32c5-cu.usbmodem1101 or esp32c5-cuaU0` (c:514-517)
      These three are the "no board now" case (F1, section 4.1).
5. **`uuid=`** overrides the helper's UUID (c:1417-1420). Kismet also reads `uuid=` and rejects a malformed one with
   `Invalid UUID for data source <name>/<interface>` (K/kis_datasource.cc:786-799).
6. **`name=`** (open, c:1524-1527): the name in the helper's status messages (default: the interface text). Kismet also
   uses `name=` as the source's display name (K/kis_datasource.cc:780-784).

### 2.3 Standard Kismet options that apply (server side)

Kismet reads from the definition: `type=` (skip probing, open with that driver, K/datasourcetracker.cc:1324-1365),
`name=`, `uuid=`, `channel=`, `channels=`, `add_channels=`, `block_channels=` (K/kis_datasource.cc:1850-1875),
`channel_hop=` (K/datasourcetracker.cc:1890), `channel_hoprate=` (K/datasourcetracker.cc:1855-1857),
`retry=` (K/kis_datasource.cc:804), `timestamp=`, `metagps=`, `info_antenna_*`, `info_amp_*`.
Defaults (K/conf/kismet.conf:147-164): `channel_hop=true`, `channel_hop_speed=5/sec`, `split_source_hopping=true`,
`randomized_hopping=true`, `retry_on_source_error=true`.
Sources given with `-c` replace the config's `source=` lines (`Data sources passed on the command line (via -c source),
ignoring source= definitions in the Kismet config file.`, e2e/t3.log:54).

---

## 3. Board discovery, identity, and `--list`

### 3.1 How a board is recognised (c:88-94, 393-467)

- USB ID `303a:1001` (c:138-139), read from sysfs `/sys/class/tty/<tty>/device/..` (`idVendor`, `idProduct`); only tty
  names starting `ttyACM` or `ttyUSB` are looked at (c:454).
- Every Espressif chip with a native USB-Serial-JTAG port has that ID (ESP32-C3, C5, C6, H2, S3, P4 ...). The helper
  cannot tell an ESP32-C5 sniffer from any other ESP32 on native USB: `--list` and bare `esp32c5` count them all; with
  other ones plugged in, name the port (c:88-92).
- The MAC is the USB serial number (`.../serial`), kept as 12 upper-case hex digits, `:` and `-` ignored; anything else,
  or not exactly 12 digits, means "no MAC" (c:413-425).
- Discovery, `--list` and re-finding a moved board need Linux sysfs; on macOS and the BSDs, name the port
  (`device=/dev/cu.usbmodem1101`, `esp32c5-cuaU0`) (c:92-94).
- Order: ttyACM2 before ttyACM10 (c:429-438).
- The MAC of a given device is found by its device number (`/sys/dev/char/<major>:<minor>`), so a by-id link, the
  tty name, or any other name for it give the same answer (rdev_board c:535-555, board_mac c:557-564).
- Stable names: udev gives each board `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC with colons>-if00`
  (observed on the Pi, e.g. `..._38:44:BE:BF:D8:0C-if00`). Not available inside the Docker container (Docker review #7).

### 3.2 Identity reported to Kismet

- **UUID** (c:566-584): `E5C5000<M>-0000-0000-0000-<MAC>`, M = 1 Wi-Fi, 2 802.15.4, 3 BTLE (c:141-143): one board has
  three UUIDs, one per radio, stable across tty renames. Observed: `E5C50001-0000-0000-0000-10BDA3C87D54` (Wi-Fi),
  `E5C50003-0000-0000-0000-3844BEBFD80C` (BTLE) (e2e/t5.log:62, e2e/t6.log:63). Without a MAC (non-Linux, fake board,
  board absent at that moment): a 48-bit FNV-1a hash of the device path instead. `uuid=` overrides.
- **Hardware string** (c:586-595): `Espressif USB-Serial-JTAG (38:44:BE:BF:D8:0C)`, or `ESP32-C5` without a MAC. It names
  the USB device on purpose, not the chip.
- **capif** (c:1543-1553): `esp32c5-<tty>`, from the real path of the device relative to `/dev` (a by-id link,
  `device=` or bare `esp32c5` all report e.g. `esp32c5-ttyACM0`), so Kismet can match the listed Wi-Fi row with this
  source. If the path cannot be resolved: the device path as given.
- **chanset**: the start channel (c:1536-1537).

### 3.3 `--list` (c:1453-1502; framework K/capture_framework.c:757-820, 914-917)

- Every board **three times**, once per radio, each name with its `mode=` flag, because Kismet keeps only the name of
  a listed interface (c:1455-1458, 48-50). Alternatives, not sources to run together.
- **A board whose port is locked (in use by a source, this helper's or the Python helper's) is left out entirely,
  all three names** (c:1473-1480, header c:51-55, ds:35-36). The check reads `/proc/locks` for a FLOCK on the device
  node's file system device and inode, without opening the port (opening it would move DTR/RTS and reset the board)
  (port_locked c:631-661). Without `/proc/locks` nothing counts as locked. Reason given in the code: Kismet can only
  mark one of the three names as in use (the one matching the running source's name or capif). **UNVERIFIED in the
  web UI.**
- Containers (c:635-637): "/proc/locks shows the locks of the processes this one can see, so a lock taken in another
  container is missed, and that board stays listed (its open still fails with "already in use")". Caution for the
  writer: with the current flock-only lock (F2 not landed), an open in a *different* container (or on the host) does
  **not** fail, because each container's `/dev/ttyACMn` is its own inode (Docker review); the comment's parenthesis
  holds only once TIOCEXCL (F2) is in, or where both sides use the same device node. **UNVERIFIED / IN FLUX.**
- Output goes to **stderr** and the process **exits 2** (`KIS_EXTERNAL_RETCODE_ARGUMENTS`, K/kis_external_packet.h:663);
  upstream framework behaviour, confirmed on the Pi. So: `kismet_cap_esp32c5 --list 2>&1`.
- It only reads sysfs and /proc/locks; it opens no port.
- Format (K/capture_framework.c:790-805): `esp32c5 supported data sources:` then, per entry, 4 spaces and
  `<interface>:<flags> (<hardware>)`. Expected for one idle board on ttyACM0 (**derived from code; not captured from a
  run of the current helper** — the Pi run of an older build printed the same layout with older names,
  `esp32c5-ttyACM2:mode=zigbee (ESP32-C5 (38:44:BE:BF:D8:0C))`):

  ```
  esp32c5 supported data sources:
      esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (38:44:BE:BF:D8:0C))
      esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (38:44:BE:BF:D8:0C))
      esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (38:44:BE:BF:D8:0C))
  ```
- No (free) board, or no sysfs: `esp32c5 - No supported data sources found...` (K/capture_framework.c:786).

---

## 4. Probe, open, capture, recovery

### 4.1 Probe: which definitions the helper claims (c:57-65, 1426-1451; tests T:1082-1133)

Kismet, for a definition without `type=`, asks every helper whether it is theirs, keeps their reasons to itself, and
gives up for good when none says yes (c:57-59). Kismet's message then is:
`Unable to find driver for '<definition>'.  Make sure that any required plugins are loaded, the interface is available, and any required Kismet helper packages are installed.`
(K/datasourcetracker.cc:1418-1427), with no retry (no source object exists).

The helper (17:31 version, **IN FLUX F1**):

| Definition | Probe | What the user sees |
|---|---|---|
| well-formed, board found | claimed | source opens |
| named the helper's way (`esp32c5`, `esp32c5-<name>`, `esp32c5zigbee`, `esp32c5btle-<name>` ...: nothing or a radio word between `esp32c5` and the first `-`, `our_name` c:301-307) but no board now (none or several; no sysfs) | **claimed** (local only) | the open fails with the reason (2.2 step 4.3) and Kismet retries every 5 s until the board is there |
| `esp32c5-ttyACM9` (a port by name, not plugged in) | claimed (as before) | `cannot open /dev/ttyACM9: No such file or directory`, retried every 5 s |
| any `device=` | claimed | open error if the device is missing, retried |
| wrong in itself: bad `mode=` or `channel=` | **not claimed** ("no retry would help it") | without `type=`: `Unable to find driver ...`; with `type=esp32c5`: the reason (`mode must be ...` / `... is not a channel ...`), then Kismet's 5 s retry notice |
| `esp32c5foo` (not a name of the helper's) with no board | not claimed | `Unable to find driver ...` |
| remote helper (`--connect`) whose board cannot be found | **not claimed** (c:1443-1445) | the helper itself stops before connecting with `FATAL: Could not probe local source prior to connecting to the remote host: <reason>` (K/capture_framework.c:2381-2383, 2514-2517) |

With `type=esp32c5` Kismet skips the probe and opens directly (K/datasourcetracker.cc:1328-1365). Pi run (older
build): `-c 'esp32c5:type=esp32c5'` with two boards showed the real reason and retried every 5 s, while `-c esp32c5`
gave only "Unable to find driver" and no retry (pi-run-notes.txt:10). F1 is meant to make `type=` unnecessary.
**UNVERIFIED:** whether a remote helper that stopped this way is restarted by the framework's retry loop every 5 s
(derived from K/capture_framework.c:5055-5124: the capture child ends, the parent sleeps 5 s and tries again unless
`--disable-retry`), and how often it prints the FATAL line.

### 4.2 Open (c:1504-1556)

Order: parse the definition (incl. `channel=`) -> `name=` -> link type -> open and lock the port -> report chanset,
current channel, capif. Kismet shows an open error as the source's error, then its retry notice:
`Source <name> (<uuid>) has encountered an error (<reason>) Kismet will attempt to re-open the source in 5 seconds.  (<n> failures)`
(K/kis_datasource.cc:3655-3657; observed e2e/t3.log:152-153).

### 4.3 The serial port (serial_open c:667-726)

- `open(device, O_RDWR | O_NOCTTY | O_NONBLOCK)`.
- `flock(LOCK_EX | LOCK_NB)` before anything else touches the port (c:678-694). It sits on the device node, so it covers
  `/dev/serial/by-id` links; "unlike TIOCEXCL it also holds against a helper running as root" (c:680-681). The Python
  helper takes the same lock (pyserial `exclusive=True`). Limits: a program that does not use flock is not stopped
  (**UNVERIFIED** which common tools flock); the lock does not cross the container boundary (F2).
- Settings: raw (`cfmakeraw`), `CLOCAL|CREAD`, no `HUPCL`, no `CRTSCTS`, `VMIN=0 VTIME=0`, speed `B115200` (the
  USB-Serial-JTAG port ignores the speed; B921600 does not exist on macOS/OpenBSD; B0 would mean hang up) (c:701-713).
- Clears **RTS first, then DTR**: on USB-Serial-JTAG those lines drive reset and boot mode, and releasing DTR while RTS
  is up resets the chip (c:716-722). Then flushes input (c:724).
- Messages: `cannot open <device>: <strerror>` (c:674; e.g. `No such file or directory`, `Permission denied`);
  `<device> is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time` (c:687-689);
  `cannot lock <device>: <strerror>` (c:692); `<device> is not a serial port: <strerror>` (c:697);
  `cannot configure <device>: <strerror>` (c:711).

### 4.4 One board, one source

One radio at a time per board (c:50-55, ds:35-36). A second source on a board in use fails at open with the "already in
use" message (T, open tests; tests/kismet_e2e.sh "a second source on a board in use"); `--list` stops offering that
board (3.3). During a reconnect the same condition is `<name>: <that message>; waiting for it` (c:1264-1265), retried
until the 15 s limit (4.6).

### 4.5 The line protocol (header c:19-28; c:751-788)

- `MODE WIFI` | `MODE 802154` | `MODE BLE` (c:330-332). Another radio than the current one reboots the board.
- `CHANNELS <n>`
- `START <unix time in microseconds> <nonce>`, nonce = 8 lowercase hex characters, new for every START (c:775-777).
  The board answers `\n<<START>> <nonce>\n`, a 24-byte PCAP global header, then one PCAP record per frame.
- Handshake: `MODE` alone, then after `MODE_SETTLE_S` = 0.8 s `CHANNELS <n>\nSTART ...` in one write under a lock
  (c:176-179, 767-788). MODE is skipped when the last global header from this port had this radio's link type
  (`on_radio`, c:216-218, 1355).
- Sync (c:982-1191): only `<<START>> <our nonce>` + `\n` or `\r\n` counts; then the global header must be
  `d4 c3 b2 a1 02 00 04 00` with the radio's link type at offset 20 (Wi-Fi 127, 802.15.4 283, BTLE 256); a wrong link
  type means the board is still on another radio, so MODE is sent again (c:1138-1142). Records must have
  `ts_usec < 1000000`, `0 < incl_len <= 16384`, `incl_len <= orig_len` (c:1159). Nothing inside a record is read as
  protocol, so a frame whose payload holds `<<START>>` and a PCAP header is passed on as data (tested: fake board
  `--inject`, tests/kismet_e2e.sh). Receive buffer 64 KiB (c:181).
- Writes: all or nothing within 1 s (c:728-749).

### 4.6 Timeouts, reconnect and recovery (c:169-179, 1215-1379)

| Constant | Value | Meaning |
|---|---|---|
| `START_RETRY_S` | 2.0 s | while not synced, the handshake is repeated every 2 s (even while bytes arrive) |
| `MODE_SETTLE_S` | 0.8 s | MODE to CHANNELS+START (a board switching radio hears nothing for about 0.5 s) |
| `STALL_TIMEOUT_S` | 6.0 s | not synced and no byte for 6 s: port dropped (`no answer`) and reopened; once synced, silence is just a quiet channel |
| `RECOVER_TIMEOUT_S` | 15.0 s | not synced for 15 s: error to Kismet, helper ends; Kismet retries a local source 5 s later |
| reopen interval | 0.5 s | c:1298 |
| poll | 100 ms | c:1303 |

- The port is dropped and reopened on: poll error, `POLLERR|POLLHUP|POLLNVAL` or a 0-byte read (`port closed`), a read
  error (strerror), a failed write (`write failed`), 6 s of silence before sync (`no answer`) (c:1303-1369).
- A rebooting board usually keeps its USB port open; it can also vanish and return, possibly under another tty name (c:79-86).
- **MAC tracking on reopen** (reopen_port c:1238-1275, fd_is_board c:616-629): the configured path first, kept only if
  the open fd (by device number) still holds the same board; otherwise
  `<name>: <device> now holds another board, looking for <MAC>`, then the board is searched by MAC; found elsewhere:
  `<name>: board <MAC> is on <path> now` (for this attempt only; the configured path, e.g. a by-id link, stays first).
  Without sysfs the path is trusted.
- Final error (c:1288-1292):
  `<name>: no capture from the board on <device> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?`
- Observed on the Pi (older build, same recovery logic): `IPC connection closed` -> Kismet's retry notice ->
  `Attempting to re-open source c5-switch` -> `SOURCEOPEN Source c5-switch (...) successfully re-opened` ->
  `c5-switch capturing (wifi)` (e2e/t3.log:151-156).

### 4.7 Status and error messages

Informational messages pass through `status()`, which drops a message identical to the previous one (c:794-808). In
Kismet's log: `INFO: <text>` for a local source (`INFO: c5-zigbee capturing (zigbee)`, e2e/t1mix.log:70) and
`INFO: <source name> - <text>` for a remote one (`INFO: remote-c - remote-c capturing (wifi)`, e2e/t5.log:63).

| Text (exact format) | When | Line |
|---|---|---|
| `<name> capturing (<wifi\|zigbee\|btle>)` | synced | c:1202 |
| `<name>: lost sync (bad PCAP global header)` | | c:1137, 1181 |
| `<name>: lost sync (the board sends link type <X>, not <Y>)` | board still on another radio | c:1141 |
| `<name>: lost sync (the board restarted the stream)` | board rebooted / answered another START | c:1154 |
| `<name>: lost sync (damaged PCAP record)` | | c:1162 |
| `<name>: <reason>, reconnecting` | reason `port closed`, `write failed`, `no answer`, or an strerror | c:1235 |
| `<name>: <device> now holds another board, looking for <MAC>` | | c:1249 |
| `<name>: board <MAC> is on <path> now` | | c:1261 |
| `<name>: <already-in-use message>; waiting for it` | | c:1265 |
| `<name>: <n> 802.15.4 frames with a malformed TAP header dropped` | 1st, then every 1000th | c:894 |
| `<name>: <n> BTLE records of impossible length dropped` | 1st, then every 1000th | c:965 |
| `<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary` | once, old firmware | c:955-958 |
| `unable to parse channel '<s>'; esp32c5 channels are plain numbers` | non-numeric channel | c:1564-1565 |
| `<name> cannot tune to channel <n> in <mode> mode` | channel set refused | c:1589-1590 |
| error, ends the helper: `<name>: no capture from the board on <device> for 15 seconds; ...` | | c:1290-1292 |
| error, ends the helper: `unable to send a packet to the Kismet server` | | c:830 |

---

## 5. Radios, channels, link types

### 5.1 Channels (c:248-276)

| Radio | Channels offered to Kismet | Start channel |
|---|---|---|
| Wi-Fi | 1-14; 36-64 step 4; 100-144 step 4; 149-177 step 4 = **42** | 6 |
| 802.15.4 | 11-26 (16) | 15 |
| BTLE | 37 only | 37 |

- Kismet hops; the board is told one channel at a time (c:71). Hop shuffle spacing 4 (c:1727-1729). At Kismet's default
  5 hops/s a full Wi-Fi pass is about 8.4 s (42/5, arithmetic).
- Channel sets outside the list are refused (4.7). A write failure during a hop is not an error: the capture thread
  reopens and sends the current channel with its START (c:1594-1602).
- BTLE: the three advertising channels are scanned together; every packet reported on 37; channel sets accepted and
  ignored (c:67-69, 1583-1586).
- Split hopping between same-type sources is upstream (Pi run: two Wi-Fi boards never on the same channel at once,
  pi-run-notes.txt:14).
- **UNVERIFIED:** that every board hears on 14, 144 and 169-177 (regulatory/firmware). The firmware's range list keeps 39
  of 42 Wi-Fi channels, which does not affect one-channel-at-a-time use (pi-review-findings #19).

### 5.2 Link types (c:145-148, 334-343, 838-980)

| Radio | Board sends | Helper sends to Kismet |
|---|---|---|
| Wi-Fi | 127 radiotap | 127, unchanged |
| 802.15.4 | 283 IEEE 802.15.4 TAP | 230 802.15.4 without FCS + signal block |
| BTLE | 256 LE LL with PHDR | 256, unchanged or CRC-filled (older firmware) |

- **802.15.4 rewrap** (c:838-897): Kismet reads TAP as a fixed 28-byte header with three TLVs; the firmware's is longer
  (48 bytes per the project memory note). The helper walks the TLVs: channel (TLV 3, must be 11-26), RSS (TLV 1,
  float32 dBm); sends the bare MAC frame as DLT 230 (the radio never hands over the FCS) with channel, frequency
  `2405 + 5*(ch-11)` MHz and rounded dBm in the signal block. Malformed headers are dropped and counted.
- **BTLE fix-up for older firmware** (c:920-968): Kismet trusts the CRC only when the pseudo-header says "CRC checked"
  (0x0400), otherwise checks it and drops failures. Current firmware sets "CRC checked" + "CRC valid" (0x0800) and
  writes the CRC. Older firmware (published esp32c5-wireshark-sniffer builds) leaves both clear with a zero CRC, so
  Kismet would drop everything; the helper computes the advertising CRC (24-bit, init 0x555555), writes it, sets both
  flags, and says so once. Records outside 19..274 bytes are dropped and counted. Tested (T `test_btle`;
  tests/kismet_e2e.sh "BTLE from older firmware").

---

## 6. Remote capture with the C helper (`--connect`)

Framework options (K/capture_framework.c:837-857, help 1136-1194): `--connect host:port`, `--tcp`, `--ssl`,
`--ssl-certificate <ca file>`, `--user`, `--password`, `--apikey`, `--endpoint <path>` (default
`/datasource/remote/remotesource.ws`), `--source <definition>` (required with `--connect`), `--disable-retry`,
`--daemonize`, `--fixed-gps lat,lon[,alt]`, `--gps-name`, `--list`, `--autodetect[=uuid]`, `--host ip:port` (same as
`--connect`), `--version`, `--help`.

- Default: websocket on Kismet's web port 2501; needs a login or an API key with the `datasource` role. `--tcp`: legacy
  protocol, default port 3501, **no authentication**; Kismet's default `remote_capture_listen=127.0.0.1` keeps it on
  loopback (K/conf/kismet.conf:90-93). Port 3501 without `--tcp` warns
  `WARNING: It looks like you're using a legacy TCP remote capture port, but did not specify '--tcp'; this probably is not what you want!`
  (K/capture_framework.c:1002-1005). Websocket with no login at all: `FATAL: User and password or API key required for remote capture`
  (K/capture_framework.c:1082-1086). Only one of user/password: `FATAL:  Must specify both username and password` (1030-1033).
- **Credentials from the environment** (c:96-102, 1619-1699; T:1273-1350), when `--connect`, `--host` or
  `--autodetect` is given and `--tcp` is not; argument scanning stops at `--`:
  - none of `--user`, `--password`, `--apikey` on the command line: `KISMET_CAP_APIKEY`, else `KISMET_CAP_USER` +
    `KISMET_CAP_PASSWORD` (both needed); the API key wins when both kinds are set;
  - `--user` alone on the command line: `KISMET_CAP_PASSWORD` completes it; `--password` alone: `KISMET_CAP_USER`;
  - `--apikey`, or both `--user` and `--password`, on the command line: the environment is not used;
  - empty variables count as unset.
  They are passed to the framework in a copy of argv, right after the program name (so a `--` cannot turn them into
  operands); `/proc/<pid>/cmdline` keeps the original, so they do not show in the process list. Only in builds with
  libwebsockets. A login on the command line is visible to every user in the process list. The Docker `helper` role
  uses this (entrypoint:209-228).
- **Password characters:** the login goes in the websocket URL query (`?user=<u>&password=<p>` or `?KISMET=<key>`,
  K/capture_framework.c:1096-1102), and Kismet decodes the whole query before splitting on `&`
  (K/kis_net_beast_httpd.cc:582, 604-613). So `&`, a space or `%XX` cannot be used in the user or password
  (entrypoint:214-221 refuses them). Use an API key or another password.
- **Before connecting** the framework probes the local source; if the board cannot be found the helper stops with
  `FATAL: Could not probe local source prior to connecting to the remote host: <reason>` (4.1).
- **Retry:** unless `--disable-retry`, capture runs in a child that is restarted whenever it exits:
  `INFO: capture process exited <code> signal <sig>`, `INFO: Sleeping 5 seconds before attempting to reconnect to remote server`
  (K/capture_framework.c:5055-5124). Kismet never reopens a remote source itself; it waits for the helper to reconnect
  (K/kis_datasource.cc:3606-3620) and matches it by UUID (`Matching new remote source '<def>' with known source with UUID '<uuid>'`, e2e/t5.log:208-209).
- Measured once on the Pi (older build; suspected upstream cause): websocket about 3-3.6 s from connect to "capturing",
  bursty; `--tcp` about 0.5 s (pi-run-notes.txt:12). **UNVERIFIED** with the current build.
- Example commands (**UNVERIFIED as written**; options are the framework's, variables c:1632-1633):
  ```
  KISMET_CAP_APIKEY=<key> kismet_cap_esp32c5 --connect kismet-host:2501 --source esp32c5-ttyACM0:mode=zigbee
  kismet_cap_esp32c5 --connect 127.0.0.1:3501 --tcp --source esp32c5btle-ttyACM1
  ```

### 6.1 Exit codes and version

- `--version`: `<major>.<minor>.<tiny>-<git commit>`, exit 0 (K/capture_framework.c:876-878; Dockerfile:100-106). For
  cfe427074 presumably `2026.09.0-cfe427074` (**UNVERIFIED**; `kismet --version` printed `Kismet 2026.09.0-cfe427074` on
  the Pi and exits 1, K/kismet_server.cc:568-569).
- `--help`: framework usage (the remote options), exit 255 (c:1736-1738; Pi run).
- `--list`: exit 2 (3.3).

---

## 7. Privileges and platforms

- The helper needs **no root**, only read/write on the tty. On the Pi the nodes are `crw-rw---- root dialout 166, N
  /dev/ttyACMN` and user `osh` was already in `dialout` (`id`: `20(dialout)`); Kismet ran as `osh` from a plain
  `make install` and captured on all three radios (e2e logs). Docs: add the user to `dialout` if needed
  (`sudo usermod -aG dialout $USER`, log in again; **UNVERIFIED here**, standard Debian practice).
- `cf_drop_most_caps` (K/capture_framework.c:4925-4982, called at c:1743): only when the real uid is 0; keeps NET_ADMIN
  and NET_RAW, drops the rest. In a container without NET_ADMIN this fails and the helper crashes (SIGSEGV) before it
  opens the board, which Kismet reports only as a probe timeout (entrypoint:134-137, compose:40-43). **IN FLUX (F3).**
- A setuid-root helper started by a normal user (`make suidinstall`, 9.5) keeps full root: the drop runs only when
  `getuid() == 0` (K/capture_framework.c:4935). The esp32c5 helper does not need setuid (**derived from code**).
- `cf_jail_filesystem` is a no-op upstream (K/capture_framework.c:4984-4986).
- Built and run: Pi 4 Debian 13 arm64; WSL2 Ubuntu 24.04 x86_64; Docker debian:trixie-slim amd64/arm64. **Not tested:**
  macOS, the BSDs, Fedora/Arch. The code prepares for them (B115200 c:706-709; `<sys/sysmacros.h>` only on Linux
  c:131-133; `cu.`/`cua`/`dty` names c:469-489) but whether it builds and runs there is **UNVERIFIED**. add-to-kismet.sh
  adds the helper to every platform's build (add:112-117).
- WSL2 sees USB boards only when attached with usbipd (compose:25-26); the WSL run used the fake board.

---

## 8. add-to-kismet.sh: every change it makes (add:1-199)

Usage: `sh kismet/add-to-kismet.sh <path to Kismet source>`; needs `python3`, `aclocal` (automake) and `autoconf`.
No argument: `usage: <script> PATH_TO_KISMET_SOURCE`. If `<path>/kismet_server.cc` or `<path>/capture_framework.c` is
missing: `<path> does not look like a Kismet source tree`, exit 1 (add:26-32). Idempotent: each edit is skipped when its
marker is there (add:22); verified in WSL (second run changed nothing, cfix/build.log). Each edit prints `  edited <file>`.
A missing anchor stops it with `anchor not found, Kismet has changed: <anchor>` (add:63, 76). Anchors are the CatSniffer
Zigbee helper's lines.

1. Copies `datasource_esp32c5.h` to `<tree>/`, and `capture_esp32c5.c` + `Makefile.in` to `<tree>/capture_esp32c5/`
   (add:34-36). Re-running it is how an updated helper gets into the tree.
2. `kismet_server.cc`: `#include "datasource_esp32c5.h"` after the catsniffer include; registers
   `datasourcetracker->register_datasource(shared_datasource_builder(new datasource_esp32c5_builder()));` after the
   catsniffer builder (add:84-91).
3. `Makefile.in` (add:93-110): `CAPTURE_ESP32C5 = capture_esp32c5/kismet_cap_esp32c5`, `BUILD_CAPTURE_ESP32C5 = @BUILD_CAPTURE_ESP32C5@`;
   rule `$(CAPTURE_ESP32C5): $(DATASOURCE_COMMON_A) FORCE` -> `(cd capture_esp32c5 && $(MAKE))`; copies of **both**
   CatSniffer install blocks (setuid in `binsuidinstall`: `-g $(SUIDGROUP) -m 4550`; plain in `commoninstall`:
   `-g $(INSTGRP)`, no mode); a `clean` entry.
4. `configure.ac` (add:112-131): `BUILD_CAPTURE_ESP32C5=1` + `DATASOURCE_BINS="$DATASOURCE_BINS \$(CAPTURE_ESP32C5)"`
   ("The ESP32-C5 boards only need a serial port, too": no platform test, no new dependency);
   `AC_SUBST(BUILD_CAPTURE_ESP32C5)`; `capture_esp32c5/Makefile` among the generated files; configure summary line
   `              ESP32-C5: yes` (seen in the Docker build log and on the Pi).
5. `.gitignore`: `capture_esp32c5/kismet_cap_esp32c5` (add:133-136).
6. **Upstream bug fix, `capture_framework.c`** (add:16-20, 139-191): `cf_commit_packet` never frees the
   `cf_frame_metadata` holder that `cf_prepare_packet` allocated, about 32 bytes per packet for the life of every capture
   helper. The script adds `int r = -1;`, keeps the commit result in `r`, then `free(meta); return r;` (only the holder;
   `meta->free_record` would commit the ring-buffer region a second time). Diff as applied: cfix/build.log. Skipped when
   the function already frees `meta` (fixed upstream). If the function is missing or changed it prints
   `  capture_framework.c: cf_commit_packet not found, its metadata leak not fixed` or
   `  capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed` and **carries on**. It "goes to
   Kismet as a change of its own", not part of the esp32c5 source (add:18-20). It changes `libkismetdatasource.a`, so
   all helpers relink on the next `make`. The Pi's tree was patched earlier today with a version of the script without
   this step (scratchpad `pi-add-to-kismet.sh`).
7. Regenerates `configure`: `aclocal -I m4 && autoconf` ("autoconf on its own fails with 'possibly undefined macro:
   AC_DEFINE'") (add:194-197). Prints `  regenerating configure (needs autoconf and automake)` and
   `Done. Now: cd <tree> && ./configure && make`. (Its header comment says `./configure && make && sudo make install`, add:7.)

After it, `git -C <tree> status --short` (Pi run, before step 6 existed): `M .gitignore`, `M Makefile.in`, `M configure`,
`M configure.ac`, `M kismet_server.cc`, `?? capture_esp32c5/`, `?? datasource_esp32c5.h`; now also `M capture_framework.c`.
Undo with git in the tree (`git checkout -- . && git clean -fd`; **UNVERIFIED as a documented procedure**).
A tree configured before the script must be configured again; otherwise make says
`'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` (K/Makefile.in:458-459).

`capture_esp32c5/Makefile.in` (mk:1-27): includes `../Makefile.inc`; links `capture_esp32c5.c.o` with
`../libkismetdatasource.a $(DATASOURCE_LIBS)` (= `$(CAPLIBS) $(PTHREAD_LIBS) -lm`; `-lcap -lwebsockets -lpthread -lm` in
the WSL log). `make -C capture_esp32c5` builds only the helper.

---

## 9. Building and installing Kismet with the helper

### 9.1 Kismet version and docs

No Kismet release has this source yet; Kismet is built from source at commit **cfe427074** (Dockerfile:9-11, 26-27).
Kismet's docs: https://www.kismetwireless.net/docs/readme/intro/kismet/ and https://github.com/kismetwireless/kismet-docs
(K/README.md); the tree has no `docs/`; `README.OLD` is legacy. Distro packaging moved to
https://github.com/kismetwireless/kismet-packages (K/packaging/README).

### 9.2 Dependencies (Debian/Ubuntu names)

- Docker build stage (Dockerfile:32-37, `--no-install-recommends`):
  `ca-certificates git build-essential pkg-config autoconf automake python3 libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev libsqlite3-dev libpcre2-dev libssl-dev libusb-1.0-0-dev libdw-dev`
  (with `--disable-libnm --disable-lmsensors --disable-mosquitto`).
- Raspberry Pi, Debian 13 trixie arm64, as run (sudo once; everything else as `osh`):
  `build-essential git pkg-config libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev libnm-dev libdw-dev libsqlite3-dev libsensors-dev libusb-1.0-0-dev libmosquitto-dev libpcre2-dev libssl-dev autoconf automake`
  plus `python3-venv python3-serial curl rsync` for the project's own tools/tests.
- WSL2 Ubuntu 24.04, as run: the same Kismet list without autoconf/automake (added later for add-to-kismet.sh), plus
  `python3-venv python3-pip`.
- Required: `libwebsockets` >= 3.1.0 with client support, unless `--disable-libwebsockets` (then remote capture needs
  `--tcp`; configure's own error text says "--disable-websockets") (K/configure.ac:1163-1186). autoconf + automake only
  because add-to-kismet.sh regenerates configure; python3 for its edits. libcap enables the capability drop (7).
  libusb enables some other helpers, among them `kismet_cap_rz_killerbee`, which matters for install (9.5).
- Fedora/Arch names: **UNVERIFIED** (not tested).

### 9.3 configure flags used

| Where | Command |
|---|---|
| Raspberry Pi (native) | `cd ~/src/kismet && ./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger` (exit 0) |
| WSL2 (native, as root) | `./configure --prefix=$HOME/kismet-install --disable-python-tools` (prefix `/root/kismet-install`) |
| Docker (Dockerfile:57-59) | `./configure --prefix=/usr --sysconfdir=/etc/kismet --localstatedir=/var --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger --disable-libnm --disable-lmsensors --disable-mosquitto` |

Why (Dockerfile:54-55): the left-out pieces are hardware the image is not for (SDRs, Ubertooth, bladeRF) or host
services a container lacks (NetworkManager, lm-sensors, MQTT). Check the summary for `ESP32-C5: yes` and
`Websocket datasources: yes`. Cosmetic upstream bug: `Setuid group: kismet        Prelude  SIEM : no` on one line
(K/configure.ac:2106 lacks `\n`). Without libnm configure prints a NetworkManager warning, irrelevant to these boards.
Clone: `git clone https://github.com/kismetwireless/kismet.git ~/src/kismet && git -C ~/src/kismet checkout cfe427074`
(Pi run; Docker: `git clone --filter=blob:none` + `checkout --quiet`, Dockerfile:40-41).

### 9.4 Compiling: measured time and memory

- **Raspberry Pi 4, 8 GB, Debian 13 arm64:** `nohup nice make -j4 > ~/kismet-build.log 2>&1 &`, 12:59-14:17, **about 78
  minutes**, exit 0, no OOM. Peak: `phy_80211.cc` (2.4 GB), `phy_80211_dissectors.cc` (1.8 GB) and
  `phy_80211_components.cc` (1.7 GB) compiling at once, leaving **about 1.1 GB available**, about 40 MB of swap used.
  76 warning lines, all upstream; none from the helper or the header. (Pi run.)
- **WSL2** (15 GB): `make -j20` thrashed the machine (host at 1.2 GB free) and the distro had to be terminated;
  rebuilt with `-j4` under `nice`. Lesson recorded: never more than `-j4` in WSL. Build time not recorded.
- **Docker:** build arg `JOBS`; empty = `min(cores, 4, MemAvailable / 1.5 GB)`, at least 1 ("Kismet's C++ needs about
  1.5 GB per compiler", "a 2 GB Raspberry Pi gets 1, not an OOM"), logged as `building with -j<N>` (Dockerfile:28-30,
  60-64). Kismet is built with a stand-in helper first so that layer stays cached when only the helper changes
  (Dockerfile:43-52, 66-71). Docker build on the Pi: **in progress, not measured yet.**
- Derived guidance (**UNVERIFIED**): 4 GB Pi `-j2`, 2 GB Pi `-j1`.
- After a helper change: re-run add-to-kismet.sh, then `make` (only the helper rebuilds; all helpers relink once if
  capture_framework.c changed) or `make -C capture_esp32c5`. The Dockerfile uses
  `make -C capture_esp32c5 clean && make -C capture_esp32c5` because a copied source can be older than the object
  file (Dockerfile:66-70).

### 9.5 Install targets (K/Makefile.in, K/Makefile.inc.in, K/configure.ac)

Variables (K/Makefile.inc.in:1-3, 63): `INSTUSR ?= "root"`; `INSTGRP ?= "@instgrp@"` = `root`, or `wheel` without a
root group (K/configure.ac:746-757); `SUIDGROUP = @suidgroup@` = `kismet` (`staff` on macOS; `--with-suidgroup=`)
(K/configure.ac:1884-1890, 1963-1970); `MANGRP ?= "@mangrp@"`, never substituted by configure and used by no install
rule at cfe427074 (only the `rpm` target exports it, K/Makefile.in:831). make command-line values override all of them,
also in the recursive `$(MAKE) -e` calls.

- `make install` (K/Makefile.in:751-777) = `commoninstall` + `configsinstall`; no setuid bit, no groupadd.
  - `commoninstall` (552-690): `kismet`, `kismet_server`, log tools `-o $(INSTUSR) -g $(INSTGRP) -m 555`; each helper
    `-o $(INSTUSR) -g $(INSTGRP)`, install's default mode 0755. **Our helper is installed this way, not setuid**
    (Pi: `-rwxr-xr-x 1 osh osh 410024 ... /home/osh/kismet-install/bin/kismet_cap_esp32c5`). Upstream exceptions:
    `kismet_cap_rz_killerbee` gets `-g $(SUIDGROUP) -m 4550` even here (644-646), the macOS CoreWLAN helper
    `-g $(SUIDGROUP)` (596-598). So a plain `make install` needs the `kismet` group (or `SUIDGROUP=`) whenever libusb
    was found.
  - Also `lib/pkgconfig/kismet.pc`, `share/kismet/httpd/` (web UI), `share/kismet/kismet_manuf.txt.gz`,
    `share/kismet/kismet_adsb_icao.txt.gz`.
  - `configsinstall` (693-719): `kismet.conf kismet_httpd.conf kismet_alerts.conf kismet_memory.conf kismet_logging.conf
    kismet_filter.conf kismet_uav.conf kismet_80211.conf kismet_wardrive.conf` into sysconfdir (`<prefix>/etc` by default),
    `-m 644`, **never replacing an existing file** (`<file> already exists; it will not be automatically replaced.`);
    `make forceconfigs` replaces them.
- `make suidinstall` (721-749): `groupadd -r -f $(SUIDGROUP)`, `commoninstall`, `binsuidinstall` (461-550),
  `configsinstall`. `binsuidinstall` reinstalls helpers `-o $(INSTUSR) -g $(SUIDGROUP) -m 4550`. **With add-to-kismet.sh
  applied this includes `kismet_cap_esp32c5`: setuid root, 4550, group `kismet`** (add:103-106). Users must be in
  `kismet` (log out and in). Not needed for these boards (7).
- `DESTDIR=` honoured (K/Makefile.inc.in:73-79); Docker: `make install DESTDIR=/out INSTUSR=root INSTGRP=root SUIDGROUP=root` (Dockerfile:71).
- Kismet runs helpers only from `helper_binary_path=%B`, its own bindir (K/conf/kismet.conf:62-69): the helper must be
  installed next to `kismet`.

| Where | Command | Result |
|---|---|---|
| Raspberry Pi, no sudo, prefix `~/kismet-install` | `make install INSTUSR=osh INSTGRP=osh SUIDGROUP=osh` | exit 0, nothing needed root; `bin/` (kismet, kismet_server, 19 `kismet_cap_*` incl. ours, kismetdb_* tools, kismet_discovery), `etc/`, `lib/`, `share/` (Pi run) |
| WSL2 as root, prefix `/root/kismet-install` | plain `make install` failed: `/usr/bin/install: invalid group 'kismet'` at `Makefile:596 commoninstall` (the rz_killerbee line); then `make install INSTGRP=root SUIDGROUP=root MANGRP=root` (WSL has no `kismet` group) | exit 0 (cfix/build.log:105-110, cfix/install.sh:5, pi-run-notes.txt:24). `MANGRP=root` is harmless but has no effect at cfe427074; `groupadd kismet` is the alternative |
| Docker | `make install DESTDIR=/out INSTUSR=root INSTGRP=root SUIDGROUP=root` | then `strip --strip-debug` on each ELF (Dockerfile:73-79) |

Sizes: built with `-g`; the installed `kismet` is `-r-xr-xr-x 1 osh osh 489329152` on the Pi (about 470 MB of debug info,
Dockerfile:73-76). `strip --strip-debug` keeps the symbol table for backtraces. Native stripping **UNVERIFIED**. Disk
space for tree + build: **not measured**.

### 9.6 First run (native)

- `~/kismet-install/bin/kismet --version` -> `Kismet 2026.09.0-cfe427074` (Pi), exit 1 (upstream).
- Pi tests ran `kismet --no-ncurses --no-logging -c '<definition>'` (e2e/kis.sh:14). `-c esp32c5-ttyACM0` as a short
  form is **UNVERIFIED on hardware** (the Pi used `device=` forms; the C tests cover the parsing).
- `<prefix>/etc/kismet_site.conf` is loaded last and overrides everything (`Loading config override file
  '/home/osh/kismet-install/etc/kismet_site.conf'`, e2e/t3.log:10; K/conf/kismet.conf:21-28). Permanent sources:
  `source=esp32c5-ttyACM0:mode=zigbee,name=zb` (**UNVERIFIED example**).
- Web UI on 2501 (K/conf/kismet_httpd.conf:23). Login in `~/.kismet/kismet_httpd.conf`, `~` = passwd home, not `$HOME`
  (`--homedir` overrides) (pi-run-notes.txt:20). Without a login the first visitor sets one (entrypoint:106-109).
- Upstream noise: `ERROR: Tried to re-register duplicate alert FLIPPERZERO` at every start of cfe427074, harmless
  (pi-run-notes.txt:26).

### 9.7 systemd and udev (upstream packaging, **not tested here**)

- configure turns `packaging/systemd/kismet.service.in` into `packaging/systemd/kismet.service`: `User=root Group=root`,
  `ExecStart=@prefix@/bin/kismet --no-ncurses-wrapper`, `Restart=always`, `ConditionPathExists=@prefix@/bin/kismet`.
  `make install` does not install it: copy to `/lib/systemd/system/`, `sudo systemctl edit kismet` to set `User=`/`Group=`,
  `sudo systemctl enable kismet` (K/packaging/systemd/README).
- udev: Kismet ships rules for other devices (e.g. `99-kismet-ticc2531.rules`: `MODE="660", GROUP="plugdev"`), none for
  ESP32. Not needed: boards come up `root:dialout 0660` with `/dev/serial/by-id` links (Pi).

---

## 10. Tests that build or exercise the helper

- `tests/c/run.sh [KISMET_TREE]` (default `$KISMET_SRC`, else `~/src/kismet`): needs a tree through add-to-kismet.sh,
  configure and make (uses its `config.h`, `capture_framework.h`, `libkismetdatasource.a`); compiles the repo's helper
  with stubs; covers the stream parser, radios, names, `channel=`, the probe, `--list`, finding a board by MAC, the port
  lock and the remote login, on a made-up sysfs tree under /tmp (so plugged-in boards do not matter). Prints `ALL OK`.
  Linux. (17:22 version.)
- `tests/kismet_e2e.sh` (`KISMET=~/kismet-install/bin/kismet tests/kismet_e2e.sh`): fake board -> helper -> real Kismet on
  port 2501 (stop any other Kismet); each radio, damaged records, injected restart signatures, in-place restart, radio
  switch with and without the port vanishing, `esp32c5zigbee-<port>`, `channel=` + `channel_hop=false`, a second source
  on a busy board, BTLE from older firmware, and (new) a bare `esp32c5` with no board, which Kismet must hand to the
  helper and retry (skipped when an Espressif USB-Serial-JTAG device is plugged in).
- `tests/docker_smoke.sh esp32c5-kismet:demo`: demo image, all radios, plus the helper role.
- CI `.github/workflows/docker.yml`: amd64 + arm64 on native runners (`ubuntu-24.04`, `ubuntu-24.04-arm`), smoke test,
  publish on `v*` tags to `ghcr.io/<owner>/esp32c5-kismet` (`latest`, `X.Y.Z`, `X.Y`, `demo`, `X.Y.Z-demo`); 120 min per job.

---

## Open questions

1. **F1 on hardware:** confirm that bare `esp32c5` with two boards (and with none) now shows the reason and retries every
   5 s, and decide whether to keep `type=esp32c5` as a tip (still needed for a wrong `mode=`/`channel=` to show its reason).
2. **F2/F3:** will TIOCEXCL and "drop all capabilities" land before publishing? The Docker NET_ADMIN instructions and the
   "lock does not cross the container boundary" warning depend on them.
3. **`make install` + `dialout` rather than `suidinstall`?** The helper needs no root and a setuid-root helper keeps full
   root (7); the upstream README favours suidinstall for its Wi-Fi/Bluetooth helpers. The user should decide.
4. **Current `--list` output** has not been captured from a run (3.3 derived from code), nor the new "locked board is
   left out" behaviour in the web UI. One `kismet_cap_esp32c5 --list 2>&1` on the Pi, idle and with one source running,
   would settle both.
5. **MANGRP=root** in the WSL instructions: keep (harmless) or drop (no effect at cfe427074)?
6. **The Pi's tree predates the capture_framework.c fix and today's helper changes.** Re-apply the current script and
   rebuild there before quoting "as installed on the Pi"? (A relink, not a 78-minute rebuild.)
7. **Docker on the Pi:** build time, image size and memory still being measured.
8. **Disk space** for a native build not measured (unstripped `kismet` alone ~489 MB).
9. **macOS/BSD** untested: say "untested" and give only the `device=` / `esp32c5-cu.*` / `esp32c5-cuaU0` naming.
10. **Remote helper without a board:** confirm the framework restarts it every 5 s after
    `FATAL: Could not probe local source ...` (4.1) rather than exiting.
11. **Websocket latency** (3-3.6 s vs 0.5 s over `--tcp`) was measured once with an older build; re-check before
    recommending `--tcp`, which has no authentication.
