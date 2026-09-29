A source definition tells Kismet, or one of this project's remote helpers, which board to open and which radio to capture with. This page is the full reference. It covers every form of the name, the options both helpers read, the Kismet options that matter, how the radio and the port are worked out, and where definitions go. Read it when a quick-start example does not fit your setup.

## The shape of a definition

```text
<interface>:<option>=<value>,<option>=<value>,...
```

- The **interface** is everything up to the first `:`. For these boards it must start with `esp32c5`, exactly, in lower case. `ESP32C5-COM14` is not a source of this project.
- The **options** follow the `:`, separated by commas. Write option names in lower case: Kismet lower-cases most of them, but not `type=`.
- A value that holds a comma must be in double quotes: `channels="1,6,11"`. Without the quotes, Kismet reads `channels=1` plus two junk options, `6` and `11`.
- A colon inside a value is fine, because only the first `:` splits the interface from the options. This works:
  `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee`
- A comma before the first `:` is refused. Kismet says `Found a ',' in the source definition '<def>'. Sources should be defined as interface:option1,option2,...`. It is usually a typo, such as `esp32c5,mode=zigbee` for `esp32c5:mode=zigbee`.
- Kismet rewrites a definition before it passes it to the helper and prints it in its logs: option names sorted, quotes removed. `esp32c5-ttyACM0:name=lab,channel=20` shows up as `esp32c5-ttyACM0:channel=20,name=lab`. Both helpers treat the rewritten form as the same source.

## The forms of the name

The name alone can say which radio and which port. The table uses a board on `/dev/ttyACM0`; on Windows, with the Python remote helper, write `COM14` or whatever port your board has instead.

| Definition | Radio | Port |
|---|---|---|
| `esp32c5-ttyACM0` | Wi-Fi | `/dev/ttyACM0` |
| `esp32c5zigbee-ttyACM0` | 802.15.4 (Zigbee, Thread) | `/dev/ttyACM0` |
| `esp32c5btle-ttyACM0` | Bluetooth LE advertising | `/dev/ttyACM0` |
| `esp32c5-ttyACM0:mode=zigbee` | 802.15.4 (`mode=` wins over the name) | `/dev/ttyACM0` |
| `esp32c5zigbee-ttyACM0:mode=wifi` | Wi-Fi (`mode=` wins) | `/dev/ttyACM0` |
| `esp32c5:device=/dev/ttyACM1,mode=btle` | Bluetooth LE | `/dev/ttyACM1`, given outright |
| `esp32c5` | Wi-Fi | the only board plugged in |
| `esp32c5zigbee`, `esp32c5btle` | 802.15.4, Bluetooth LE | the only board plugged in |
| `esp32c5-kitchen` | Wi-Fi | `kitchen` is a name, not a port: the only board plugged in, or add `device=` |
| `esp32c5btle-kitchen:device=/dev/ttyACM3` | Bluetooth LE | `/dev/ttyACM3` |
| `esp32c5ble-ttyUSB1`, `esp32c5thread-ttyACM2`, `esp32c5802154-ttyACM2` | the radio aliases below also work in the name | as named |

The two helpers use the same names and rules. The C helper `kismet_cap_esp32c5` runs inside Kismet on Linux; the Python remote helper runs anywhere Python does, mainly Windows. Where they differ, this page says so.

### Radio words

The radio is written the same way in the name and in `mode=`. Case does not matter.

| Radio | Words |
|---|---|
| Wi-Fi | `wifi` |
| 802.15.4 (Zigbee, Thread) | `zigbee`, `802154`, `802.15.4`, `thread` |
| Bluetooth LE advertising | `btle`, `ble`, `bluetooth` |

This page and the helpers' messages call the three radios **wifi**, **zigbee** and **btle**.

## How the radio is chosen

1. `mode=` with a value decides.
2. Otherwise, the text between `esp32c5` and the first `-` is read as a radio word.
3. If that text is empty (`esp32c5-ttyACM0`, bare `esp32c5`) or is not a radio word (`esp32c5foo-ttyACM0`), the radio is Wi-Fi.

A `mode=` value that is not a radio word stops the source. The two helpers word it differently:

```text
esp32c5-ttyACM0: mode must be wifi, zigbee or btle                                   # C helper
unknown mode 'lora': use wifi, zigbee (802154, 802.15.4, thread) or btle (ble, bluetooth)   # Python remote helper
```

## How the port is chosen

### The C helper (Kismet on Linux)

The first rule that applies wins:

1. **`device=`**, used as given. The helper does not check that it exists, and a `/dev/serial/by-id/...` link works.
2. **The part of the name after the first `-`**, if it looks like a serial port: it starts with `tty`, `cu.`, `cua`, `dty` or `pts/` and contains no `..`. It is taken as `/dev/<part>`, as written, without checking that it exists. This is on purpose: a board that is rebooting right now is waited for rather than swapped for another.
3. **The only Espressif USB-Serial-JTAG device plugged in** (USB ID `303a:1001`), found through Linux sysfs.

Any other text after the `-` is a name for the source, not a port. The helper never opens `/dev/<name>` for it. So `esp32c5-serial1` does not open the Raspberry Pi's Bluetooth UART `/dev/serial1`, and `esp32c5-watchdog` does not open `/dev/watchdog`, which reboots the machine if it is opened and not properly closed. Both look for the only board plugged in, like `esp32c5-kitchen`.

When step 3 cannot pick one board, the open fails with one of these reasons:

| Situation | Message |
|---|---|
| No board | `no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition` |
| Several boards | `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-ttyACM0` |
| No Linux sysfs (macOS, the BSDs) | `finding a board by itself needs Linux sysfs (/sys/class/tty), which this system does not have; name the port with device=/dev/... or a source name like esp32c5-cu.usbmodem1101 or esp32c5-cuaU0` |

> **Note:** Every Espressif chip with a native USB-Serial-JTAG port has the USB ID `303a:1001`: the ESP32-C3, C5, C6, H2, S3, P4 and others. The helpers cannot tell an ESP32-C5 sniffer from any other ESP32 on native USB. If other ESP32 boards are plugged in, name the port.

### The Python remote helper

It follows the same order, with these differences:

- **On Windows**, only `COM<n>` after the `-` is a port, in any case: `esp32c5-com7` means `COM7`. Any other text, `esp32c5-ttyACM0` included, is a name. In `device=`, `com14`, `COM14` and `\\.\COM14` are the same port.
- **Elsewhere**, the same rule as the C helper: only `tty*`, `cu.*`, `cua*`, `dty*` or `pts/N` after the `-` is a port, taken as `/dev/<name>` whether or not it is there now. A name containing `..` is never taken as a port, and any other name (`esp32c5-kitchen`, `esp32c5-serial1`) is only a name: nothing under `/dev` is opened for it.
- **A definition without a port that has found its board before follows that board by its MAC**, wherever it is plugged in now. It waits for that board (`the board <MAC> is not plugged in (waiting for it)`) and does not fall back to "the only board".
- **A named port that is not there** is waited for, not replaced: `COM99 is not there; is the board plugged in? (waiting for it)`. The source is not offered to Kismet until the port appears. `uuid=` skips this check.
- It finds boards with pyserial, so the bare `esp32c5` and `--list` also work on Windows, not only on Linux. They should work on macOS too, which has not been tried.

<!-- VERIFY: Python remote helper naming, port and MAC-pinning rules above behave this way on real boards on Windows and Linux (offline and fake-board tests pass; not re-run on hardware since the change); board discovery on macOS -->


### Port names per platform

| Platform | Port | Source name | Tested |
|---|---|---|---|
| Linux, Raspberry Pi | `/dev/ttyACM0` | `esp32c5-ttyACM0` | yes |
| Linux, stable name | `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00` | `esp32c5:device=/dev/serial/by-id/...` | yes |
| Windows (Python remote helper) | `COM14` | `esp32c5-COM14` | yes |
| macOS | `/dev/cu.usbmodem1101` | `esp32c5-cu.usbmodem1101` | no |
| FreeBSD, OpenBSD | `/dev/cuaU0` | `esp32c5-cuaU0` | no |
| NetBSD | `/dev/dtyU0` | `esp32c5-dtyU0` | no |
| The fake board | `/tmp/esp32c5-fake` (a link to a pseudo-terminal) | `esp32c5:device=/tmp/esp32c5-fake` | yes |

<!-- VERIFY: macOS and BSD port names; neither helper has been built or run on macOS or a BSD -->

On Linux, udev gives each board a stable link named after its MAC, which it reports as its USB serial number. A ttyACM number can change when a board is plugged in again, and two boards that reboot together can come back with their numbers swapped. The by-id link stays with the board. List them with:

```bash
ls -l /dev/serial/by-id/
```

The C helper also checks, whenever it reopens a port, that the port still holds the same board, and finds a board that moved by its MAC. The by-id link is still the plainest way to say which board you mean.

<!-- VERIFY: the C helper's MAC re-find after two boards swap tty names (untested: needs two boards whose names swap) -->


## Options the esp32c5 helpers read

| Option | Values | Default | What it does | Helper |
|---|---|---|---|---|
| `mode=` | a radio word | from the name | The radio. Wins over the name. | both |
| `device=` | a port path | from the name, else the only board | The serial port. Wins over the name. | both |
| `channel=` | a channel number | Wi-Fi 6, zigbee 15, btle 37 | The channel to start on, and with `channel_hop=false` the one to stay on. | both |
| `name=` | text | the interface | The source's name in Kismet and in the helper's messages. | both |
| `uuid=` | `8-4-4-4-12` hex | worked out from the board's MAC | A fixed Kismet UUID for the source. | both |
| `dwell=` | 20 to 60000 (ms) | 250 | Checked, then has no effect: the helper only ever gives the board one channel at a time, and Kismet's hop rate sets the timing. | Python only |

The Python remote helper also reads Kismet's `channel_hop=`, only to know whether Kismet will hop the source. It ignores every other option and leaves it to Kismet. A repeated option counts once: the first one wins.

### channel= in detail

- It must be plain decimal digits, at most 177, and a channel the radio can tune to:

  | Radio | Channels |
  |---|---|
  | wifi | 1-14; 36-64, 100-144 and 149-177 in steps of 4 (42 channels) |
  | zigbee | 11-26 |
  | btle | 37, 38 or 39 are accepted; the source stays on 37, because the board scans all three advertising channels together |

- Anything else stops the source before the port is touched: `esp32c5-ttyACM0: channel=15 is not a channel the board can tune to in wifi mode`. Values such as `+6`, `6.0` and `6HT40` are refused too.
- **`channel=` alone does not lock the channel.** Kismet adds it to the hop list and then hops the whole list. To stay on one channel, add `channel_hop=false`:

  ```text
  esp32c5zigbee-ttyACM0:channel=20,channel_hop=false
  ```

<!-- VERIFY: channel= is honoured by both helpers on real boards (start channel, and channel_hop=false keeps it there); it was fixed after the last hardware run -->

Earlier builds of both helpers ignored `channel=`, and the source stayed on 6, 15 or 37. If you see that, update the helpers ([Guide: Updating](Guide-Updating)), or set the channel from the web UI or the REST API ([Channel Control](Channel-Control)).

## Kismet's options that matter here

Kismet reads these from every definition, whichever helper opens it. Everything else goes to the helper.

| Option | Values | What it does |
|---|---|---|
| `type=esp32c5` | the source type | Skips probing and opens with this project's driver. See the next section for when it helps. |
| `name=` | text | The name Kismet shows. |
| `uuid=` | `8-4-4-4-12` hex | A fixed UUID. A malformed one fails with `Invalid UUID for data source <name>/<interface>`. |
| `channel=` | a channel | Added to the hop list. See above. |
| `channels="a,b,c"` | quoted list | Hop only these channels. |
| `add_channels="a,b"` | quoted list | Add channels to the helper's list. Ignored when `channels=` is given. |
| `block_channels="a,b"` | quoted list | Remove channels from the helper's list. Ignored when `channels=` is given. |
| `channel_hop=` | `true` or `false` | `false`: Kismet never hops this source. |
| `channel_hoprate=` | `<n>/sec`, `<n>/min` or `<n>/dwell` | A hop rate for this source, **only honoured when Kismet splits the channel list between this source and at least one other running source of the same type that can tune to the same channels** (a different `channels=` list does not prevent that; a different `block_channels=` list does). A lone source hops at the global `channel_hop_speed`. |
| `retry=` | `true` or `false` | Re-open a local source after an error. Default `true`. Kismet never re-opens a remote source; the remote helper reconnects. |
| `timestamp=` | `true` or `false` | Remote sources only: `true` (the default) replaces packet times with Kismet's arrival time. |
| `metagps=` | a name | Attach a named GPS to the source. |
| `info_antenna_type=`, `info_antenna_gain=`, `info_antenna_orientation=`, `info_antenna_beamwidth=`, `info_amp_type=`, `info_amp_gain=` | notes | Free-form notes about the antenna, shown with the source. |

- Kismet booleans accept only `true`, `t`, `false` and `f`. Anything else, such as `no` or `0`, falls back to the default, so `channel_hop=no` still hops.
- The per-source hop rate is spelled `channel_hoprate`. `channel_hop_rate=`, `hop_rate=`, `hop=`, `split=` and `velocity=` are not Kismet options and do nothing.
- The Wi-Fi list includes channels 12-14 and 169-177, which are not in use everywhere. Drop the ones you do not need with `block_channels=`.

For hopping, splitting and changing channels at run time, see [Channel Control](Channel-Control).

## Probing, and when to add type=esp32c5

For a definition without `type=`, Kismet asks every helper whether the definition is theirs. It keeps their reasons to itself. If no helper says yes, Kismet gives up for good, with no retry:

```text
Unable to find driver for 'esp32c5'.  Make sure that any required plugins are loaded, the interface is available, and any required Kismet helper packages are installed.
```

The C helper answers like this:

| Definition | Claimed? | What you see |
|---|---|---|
| Well-formed, board found | yes | The source opens. |
| Named the helper's way (`esp32c5`, `esp32c5-kitchen`, `esp32c5zigbee`, `esp32c5btle-<name>` ...), but no board can be picked now (none, or several) | yes, for a local source | The open fails with the reason, and Kismet retries every 5 s until the board is there. |
| A port by name that is not plugged in (`esp32c5-ttyACM9`) | yes | `cannot open /dev/ttyACM9: No such file or directory`, retried every 5 s. |
| Any `device=` | yes | An open error if the device is missing, retried. |
| A wrong `mode=` or `channel=` | no | `Unable to find driver ...`. With `type=esp32c5` you see the real reason instead. |
| `esp32c5foo` (not one of the helper's names) with no board | no | `Unable to find driver ...` |

<!-- VERIFY: on real hardware, a bare esp32c5 with two boards plugged in shows the helper's reason and is retried every 5 s without type=esp32c5 (the no-board case passes in tests/kismet_e2e.sh) -->

Helpers built before this behaviour gave only "Unable to find driver" for a bare `esp32c5` with no board or several, and never retried. If you see that, update the helper ([Guide: Updating](Guide-Updating)).

So add `type=esp32c5` when Kismet says only "Unable to find driver" and you want to know why:

```bash
kismet -c 'esp32c5:mode=zigbee,channel=27,type=esp32c5'
```

Kismet then opens the source directly and shows the helper's own reason, here `esp32c5: channel=27 is not a channel the board can tune to in zigbee mode`. If Kismet answers `Unable to find datasource for 'esp32c5'` instead, this Kismet was built without the esp32c5 source; see [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).

A remote C helper (`kismet_cap_esp32c5 --connect ...`) checks its own definition before it connects. A definition that names no port (a bare `esp32c5`, or a free-form name such as `esp32c5-kitchen`) stops it there when there is no board or more than one, with `FATAL: Could not probe local source prior to connecting to the remote host: <reason>`. A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) connects anyway, and Kismet shows the open error as the source's error. The Docker image's `helper` role starts the helper again every 5 s, so a board plugged in later is picked up there.
<!-- VERIFY: that a remote C helper whose named port is missing connects and reports the open error (read from capture_esp32c5.c probe_callback and resolve_device) -->

## What Kismet shows for a source

| Field | Value | Example |
|---|---|---|
| UUID | `E5C5000<M>-0000-0000-0000-<MAC>`, with M = 1 wifi, 2 zigbee, 3 btle | `E5C50002-0000-0000-0000-F0F5BD010203` |
| Hardware | `Espressif USB-Serial-JTAG (<MAC>)`, or `ESP32-C5` when the MAC is not known | `Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03)` |
| Capture interface | C helper: `esp32c5-<tty>`, however the source was defined. Python remote helper: the port. | `esp32c5-ttyACM0`; `COM14` |

<!-- VERIFY: hardware string "Espressif USB-Serial-JTAG (<MAC>)" and the capture interface values in the Kismet UI with the current helpers (older builds showed "ESP32-C5 (<MAC>)") -->

- One board has three UUIDs, one per radio. They stay the same across ttyACM renumbering and across the two helpers, so Kismet recognises a board it has seen before.
- Without a MAC the UUID comes from a hash of the device path, and a different path then means a different UUID. That happens with the fake board, with a board not identifiable at that moment, and with the C helper on macOS and the BSDs, where it has no Linux sysfs to read the MAC from. The Python remote helper reads the MAC from pyserial's port list, which should give it on macOS too; that has not been tried.
  <!-- VERIFY: the Python remote helper gets the board's MAC through pyserial on macOS (and whether pyserial reports USB serial numbers on the BSDs at all); never run on either -->
- Kismet matches remote sources by UUID only, and keeps a source in error in its list. A UUID that changes therefore leaves a second, stale entry. Pin it with `uuid=` if you need to, or name the board by its by-id link.

## One board, one source

A board captures with one radio at a time, and every change of radio reboots it. So a board can be used by one source at a time. Both helpers hold an exclusive lock on the port while they use it. A second source on the same board fails with:

```text
/dev/ttyACM0 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time
```

- To change radio, close the source and open one for the other radio. The board reboots, which took about 1.5 s from "launched" to "capturing" in the last hardware run, against 0.5 s when the board was already on that radio.
  <!-- VERIFY: re-measure the radio-switch time with the current helpers (they now wait 0.8 s between MODE and START) -->
- The C helper's `--list` leaves out a board that is in use, all three of its names. Kismet's Data Sources panel then stops offering it.
  <!-- VERIFY: the Data Sources panel stops listing a board in use with the current C helper -->
- The Python remote helper refuses at startup, with exit code 2, two definitions that want the same port (`esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14`) and two that name no port (`esp32c5:mode=wifi and esp32c5:mode=zigbee name no port, so both would take the same board; ...`).
- The lock is an `flock` on Linux and macOS, and the exclusive open that every COM port has on Windows. The C helper and the Python remote helper take the same lock, so they keep out of each other's way.

> **Warning:** In Docker, the lock does not cross the container boundary: each container makes its own device node. A board used by a container can still be opened from the host or from a second container. Stop the `kismet` service before you use the same boards from the host or from the `helper` service.

<!-- VERIFY: whether TIOCEXCL (F2) has landed in the C helper; if it has, the lock also holds across containers and this warning can be relaxed -->

## Where definitions go

| Where | Form | Lasts |
|---|---|---|
| `kismet_site.conf` | `source=<definition>`, one line per source | every start |
| Kismet's command line | `-c <definition>`, repeatable | this run |
| Kismet's web UI | Data Sources, then Enable Source | this run |
| Kismet's REST API | `POST /datasource/add_source.cmd` | this run |
| The Docker image | `KISMET_SOURCES`, definitions separated by spaces | the container |
| The C helper, remote | `--source <definition>`, one per process | the helper |
| The Python remote helper | `--source <definition>`, repeatable | the helper |

### kismet_site.conf

Put permanent sources in `kismet_site.conf` in Kismet's config directory (for example `~/kismet-install/etc/kismet_site.conf` for a build with `--prefix=$HOME/kismet-install`). Kismet loads it last. Change the device names to your boards':

```ini
source=esp32c5-ttyACM0:name=c5-wifi
source=esp32c5zigbee-ttyACM1:name=c5-zigbee,channel=20,channel_hop=false
source=esp32c5btle-ttyACM2:name=c5-btle
```

- Every `source=` line in `kismet_site.conf` is used. Together they replace any `source=` lines in the base config files (Kismet ships none). Write `source+=` instead if you want to add to base-file sources.
- **Any `-c` on the command line makes Kismet ignore every `source=` line.** Kismet says so: `Data sources passed on the command line (via -c source), ignoring source= definitions in the Kismet config file.`
- There are no inline comments. `source=esp32c5-ttyACM0 # kitchen` puts `# kitchen` into the definition. Put comments on their own line, starting with `#`.

See [Kismet Configuration](Kismet-Configuration) for where the file lives on each install.

### The command line

Quote each definition for your shell. For PowerShell and cmd, see [The remote helpers](#the-remote-helpers) below. In bash, single quotes keep double quotes inside a value intact:

```bash
kismet -c esp32c5-ttyACM0 -c 'esp32c5zigbee-ttyACM1:channel=20,channel_hop=false'
kismet -c 'esp32c5-ttyACM0:channels="1,6,11",name=c5-24ghz'
```

<!-- VERIFY: the short form "-c esp32c5-ttyACM0" on real hardware (the hardware runs used device= forms and esp32c5-ttyACM2:mode=wifi) -->

### The web UI

Kismet's **Data Sources** panel lists what the helpers can see. The C helper lists each free board three times, once per radio:

```text
esp32c5-ttyACM0    esp32c5zigbee-ttyACM0    esp32c5btle-ttyACM0
```

These are alternatives: pick one. **Enable Source** opens it as `<listed name>:type=esp32c5`, for example `esp32c5zigbee-ttyACM0:type=esp32c5`. The board then drops out of the list, all three of its names. If you enable another of its names from a list that has not refreshed yet, that source fails with "already in use".

<!-- VERIFY: the three rows per board in the Data Sources panel with the current C helper; this was changed after the last hardware run -->

### The REST API

Kismet's `add_source.cmd` takes a definition as JSON. It needs an admin login. Change the address and password to yours:

```bash
curl -s -u admin:PASSWORD --data-urlencode 'json={"definition":"esp32c5-ttyACM0:type=esp32c5,name=c5-wifi"}' http://192.168.1.50:2501/datasource/add_source.cmd
```

<!-- VERIFY: this add_source.cmd call as written (constructed from Kismet's code, not run) -->

On failure Kismet answers HTTP 500, for example when the board is already in use.

#### Closing, reopening and pausing a source

The Data Sources panel's buttons have REST equivalents. They need the admin login, and they address the source by its UUID ([Multiple Boards](Multiple-Boards#identity-in-kismet)):

| Call | Effect |
|---|---|
| `.../close_source.cmd` | Close the source; Kismet does not re-open it. A local source's helper ends, and the board's port is free. |
| `.../disable_source.cmd` | The same; the source's error then reads `Source disabled`. |
| `.../open_source.cmd` | Open a closed source again (`source already running` if it runs). |
| `.../pause_source.cmd`, `.../resume_source.cmd` | Stop and start using its packets without closing it (`Source already paused`, `Source already running`). |

Each call goes after `http://<server>:2501/datasource/by-uuid/<uuid>/`. These two lines move a board from Wi-Fi to Zigbee without restarting Kismet. Change the address, the password, the UUID and the port to yours:

```bash
curl -s -u admin:PASSWORD http://192.168.1.50:2501/datasource/by-uuid/E5C50001-0000-0000-0000-F0F5BD010203/close_source.cmd
curl -s -u admin:PASSWORD --data-urlencode 'json={"definition":"esp32c5zigbee-ttyACM0:type=esp32c5,name=c5-zigbee"}' http://192.168.1.50:2501/datasource/add_source.cmd
```

**Remote sources:** closing one drops its connection, and the helper connects again 5 s later, so the source comes back. To stop a remote source, stop its helper; to keep it connected but ignored, pause it.

<!-- VERIFY: these calls as written (read from Kismet's datasourcetracker.cc:810-882 and kis_datasource.cc disable_source; not run; both GET and POST are registered); that close_source.cmd releases the board's lock on a local source; that a closed remote source comes back when the Python remote helper and the remote C helper reconnect (kis_datasource.cc close_source -> close_external) -->

### Docker

The image's `kismet` role adds one source per board it finds, each in `ESP32C5_MODE` (default `wifi`). The demo image does not look for boards; it adds only its fake board and whatever `KISMET_SOURCES` holds. To choose the sources yourself, set `KISMET_SOURCES`, with the definitions separated by spaces. A definition cannot contain a space. Set it too when other ESP32 boards are plugged in, since the image finds boards by USB ID and would add those as well.

```bash
KISMET_SOURCES="esp32c5-ttyACM0:mode=wifi esp32c5-ttyACM1:mode=zigbee esp32c5-ttyACM2:mode=btle"
```

The container makes the same `/dev/serial/by-id/...` links as the host, so a by-id definition works there too.

<!-- VERIFY: by-id links inside the container with real boards (the entrypoint makes them; no container has been run with real boards yet) -->

Put the line in a `.env` file next to `compose.yaml`, or pass it with `-e` to `docker run`. See [Docker Reference](Docker-Reference).

### The remote helpers

A remote helper sends a board to a Kismet server on another machine. The C helper takes one `--source` per process. The Python remote helper takes `--source` as often as you like, one per board, each with its own connection:

```powershell
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-COM14 --source esp32c5zigbee-COM15:channel=20,channel_hop=false
```

Replace `192.168.1.50` with your Kismet server and `3F9A6C1E07B24D58A1C9E2F4608B7D35` with your API key, one with the `datasource` role. See [Remote Capture](Remote-Capture) and [Command-Line Reference](Command-Line-Reference).

Definitions without double quotes, like both in the command above, pass through PowerShell and cmd unchanged. A value in double quotes needs care on Windows:

- **Windows PowerShell 5.1** removes double quotes inside an argument before it starts a program. `--source 'esp32c5-COM14:channels="1,6,11"'` reaches the helper as `esp32c5-COM14:channels=1,6,11`, which Kismet reads as `channels=1` plus two junk options. The helper warns: `the comma list in channels= is not in double quotes, so Kismet reads only its first item ...`. Put a backslash before each inner quote:

  ```powershell
  python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source 'esp32c5-COM14:channels=\"1,6,11\"'
  ```

- **cmd** also drops quotes that are not escaped. Put the whole definition in double quotes and escape the inner ones:

  ```text
  python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source "esp32c5-COM14:channels=\"1,6,11\""
  ```

Both forms were checked to reach Python as `esp32c5-COM14:channels="1,6,11"`. In Git Bash, the single-quoted form without backslashes arrives intact, as in bash.

<!-- VERIFY: PowerShell 7 (7.3 and later pass inner quotes as they are, so the backslashes may then arrive as well); the helper's unquoted-comma-list warning in its final code -->

## Examples

Change the port names, the address and the key to yours. The first group is for Kismet on Linux with the C helper, the second for remote capture.

| What you want | Definition |
|---|---|
| Wi-Fi on the only board plugged in | `esp32c5` |
| Wi-Fi on one board of several | `esp32c5-ttyACM0` |
| Zigbee or Thread on that board | `esp32c5zigbee-ttyACM0` |
| BLE advertising on that board | `esp32c5btle-ttyACM0` |
| One board by its MAC, whatever its ttyACM number | `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee` |
| A friendly name in Kismet | `esp32c5btle-ttyACM2:name=hall-ble` |
| Zigbee locked on channel 20 | `esp32c5zigbee-ttyACM1:channel=20,channel_hop=false` |
| Wi-Fi locked on channel 36 | `esp32c5-ttyACM0:channel=36,channel_hop=false` |
| Wi-Fi hopping 1, 6 and 11 only | `esp32c5-ttyACM0:channels="1,6,11"` |
| Wi-Fi hopping 5 GHz UNII-1 and UNII-3 only (no DFS channels) | `esp32c5-ttyACM0:channels="36,40,44,48,149,153,157,161,165"` |
| Wi-Fi without 12-14 | `esp32c5-ttyACM0:block_channels="12,13,14"` |
| Show the reason a definition does not open | `esp32c5:type=esp32c5` |
| The fake board | `esp32c5:device=/tmp/esp32c5-fake,mode=wifi` |
| Windows, Python remote helper, Wi-Fi on COM14 | `esp32c5-COM14` |
| Windows, the same board for Zigbee on channel 15, locked | `esp32c5zigbee-COM14:channel=15,channel_hop=false` |
| Windows, port given outright | `esp32c5:device=COM14,mode=btle,name=desk-ble` |
| A remote Linux board, C helper | `--source esp32c5-ttyACM0:mode=zigbee` |

Two Wi-Fi boards on one Kismet hop the same list from different starting points, so they are not on the same channel at once. See [Multiple Boards](Multiple-Boards).

## Related pages

- [Channel Control](Channel-Control): hopping, locking and changing channels while capturing.
- [Multiple Boards](Multiple-Boards): several boards on one Kismet server.
- [Remote Capture](Remote-Capture): boards on one machine, Kismet on another.
- [Kismet Configuration](Kismet-Configuration): where `kismet_site.conf` lives.
- [Command-Line Reference](Command-Line-Reference): every option of every command.
- [Troubleshooting](Troubleshooting): when a source does not open or does not capture.
