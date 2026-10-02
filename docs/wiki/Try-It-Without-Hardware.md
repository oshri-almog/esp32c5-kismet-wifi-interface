This page runs Kismet with a fake ESP32-C5 board, so you can see what this project does before you buy or flash a board. The first part is the Docker demo, for anyone with Docker; the second is the fake board itself, for developers on Linux or WSL.

## What the demo is

The demo image is the project's Kismet image plus a fake board. When the container starts, it runs the fake board on a pseudo-terminal inside the container and adds it to Kismet as a source named `demo`, read by the same C helper that reads real boards. Nothing is received from the air: the fake board makes up its traffic.

What the fake board sends depends on its radio and on the channel Kismet has tuned it to:

| Radio | What the fake board sends | Channels with traffic |
|---|---|---|
| Wi-Fi (`wifi`, the default) | Beacons from three access points: `ESP32C5-FAKE-24` on 2.4 GHz, `ESP32C5-FAKE-5LOW` and `ESP32C5-FAKE-5HIGH` on 5 GHz | 6, 36 and 149 |
| Zigbee and Thread (`zigbee`) | Data frames from two 802.15.4 nodes | 15 and 25 |
| Bluetooth LE (`btle`) | Advertisements from a device named `ESP32C5-FAKE` | all the time (the radio scans 37 to 39 together) |

Like a real board, the fake board runs one radio at a time and reboots when asked for another one.

The demo needs no USB device, so it runs where real boards cannot reach a container, such as Docker Desktop on Windows. It does not look for boards plugged into the host either, so it will not open a real board by accident: on a Raspberry Pi with four boards plugged in, the demo came up with its one fake source and nothing else.

It has been tested with all three radios on Docker Desktop on Windows 11 (amd64), and on Linux for amd64 and arm64 by the project's CI, which runs the smoke test on every change to the image. On the Raspberry Pi 4 (arm64) it ran with Wi-Fi, with an image from before the last two rounds of changes. Docker Desktop on macOS has not been tried.

## Get the demo image

The images are not published yet: CI builds and tests them, but publishes only for a version tag or a manual run, and there has been neither. Once they are, pull it:

```bash
docker pull ghcr.io/oshri-almog/esp32c5-kismet:demo
```

Until then, build it from the repository. It needs an internet connection, since the build clones Kismet and compiles it:

```bash
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface
cd esp32c5-kismet-wifi-interface
docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
```

The first build took 18.5 minutes on a fast Windows PC (20 cores, 16 GB, Docker Desktop); later rebuilds from the cache took 2 to 39 s. On a Raspberry Pi 4 with 8 GB it took about 80 minutes, almost all of it compiling Kismet, and the Pi needs a 64-bit OS. The finished image is about 227 MB on amd64.

On a Raspberry Pi, put `sudo` before each `docker` command unless your user is in the `docker` group. Membership of that group is equivalent to root, which is why the test Pi uses `sudo` instead. Where a command starts with a variable, such as `KISMET_PORT=2598 docker compose ...` below, `sudo` goes first: `sudo KISMET_PORT=2598 docker compose ...`. [Install with Docker](Install-with-Docker) covers installing Docker itself.

## Run it with docker run

1. Start the container. If you pulled the published image, write `ghcr.io/oshri-almog/esp32c5-kismet:demo` instead of `esp32c5-kismet:demo`:

   ```bash
   docker run --rm --name esp32c5-demo -p 127.0.0.1:2501:2501 -e KISMET_USER=demo -e KISMET_PASSWORD=demo esp32c5-kismet:demo
   ```

2. Open http://localhost:2501 in a browser and log in as `demo`, password `demo`.
3. To stop it, run this in another terminal. `--rm` then removes the container and its volumes:

   ```bash
   docker stop esp32c5-demo
   ```

What the options do:

| Option | Why |
|---|---|
| `--rm` | Remove the container, and the volumes it made, when it stops. |
| `--name esp32c5-demo` | A name, so you can stop it by name. |
| `-p 127.0.0.1:2501:2501` | Publish Kismet's web port on this computer only. If port 2501 is taken, for example by a Kismet in WSL2, change the first number: `-p 127.0.0.1:2601:2501`, then open http://localhost:2601. |
| `-e KISMET_USER=demo -e KISMET_PASSWORD=demo` | The web login. Without them the container makes up a password and prints it once in its log. |

The container needs no extra capability such as `NET_ADMIN`: the image's capture helper drops every capability it is given, and Kismet's other capture helpers, which would need it, are switched off in the image.

## Run it with docker compose

[`compose.yaml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/compose.yaml) has a `demo` service. It needs Docker Compose, which Docker Desktop includes; Debian's `docker.io` packages, as on the test Pi, do not, so use `docker run` there or see [Install with Docker](Install-with-Docker). From the repository's root directory:

```bash
docker compose --profile demo up demo
```

- Name the service as well as the profile. `docker compose --profile demo up` on its own also starts the `kismet` service, which looks for real boards and wants the same port.
- If the image cannot be pulled, compose builds it locally. On Docker Desktop this printed `Image ghcr.io/oshri-almog/esp32c5-kismet:demo error from registry: denied`, as the images are not published yet, then built and started it.
- The service listens on http://localhost:2501 only (not on other machines), with the login `demo` / `demo`, and runs Kismet with logging off.
- To use another port, set `KISMET_PORT`. In bash:

  ```bash
  KISMET_PORT=2598 docker compose --profile demo up demo
  ```

  With `sudo`, as on the test Pi, put the variable after `sudo`:

  ```bash
  sudo KISMET_PORT=2598 docker compose --profile demo up demo
  ```

  Written the other way round, `KISMET_PORT=2598 sudo docker compose ...`, the variable never reaches Docker Compose, because `sudo` starts the command with a clean environment; the demo then comes up on port 2501 without a warning. A `.env` file (below) works with or without `sudo`. All three were checked with `docker compose config`, on Ubuntu 24.04 with `sudo`'s default settings, which Debian shares; not on the Pi.

  In PowerShell:

  ```powershell
  $env:KISMET_PORT = "2598"
  docker compose --profile demo up demo
  ```

  The setting lasts until you close this PowerShell window; `Remove-Item Env:KISMET_PORT` goes back to the default. Or put `KISMET_PORT=2598` in a file named `.env` next to `compose.yaml`.

Press Ctrl+C to stop it. The stopped container stays. To remove the demo's container and its anonymous volumes, and nothing else:

```bash
docker compose --profile demo rm -s -v demo
```

It asks before it removes anything. `-s` stops the container first if it still runs, and `-v` removes the anonymous volumes attached to it, the only ones the demo has; named volumes, such as the `kismet` service's `kismet-data` and `kismet-home`, are never removed by `rm`. That is Docker Compose's documented behaviour; this command has not been run in the tests.

> **Warning:** do not clean up with `docker compose --profile demo down -v` if you have ever run the real `kismet` service from this directory. `down` also stops and removes the `kismet` service's container, and `-v` deletes its named volumes, `kismet-data` and `kismet-home`, which hold that service's Kismet logs, web login and API keys.

## Switch the demo radio

The `ESP32C5_DEMO` variable picks the fake board's radio: `wifi` (the default), `zigbee` or `btle`. The container reads it at start, so stop the demo and start it again with the new value.

With `docker run`, add `-e ESP32C5_DEMO=zigbee`:

```bash
docker run --rm --name esp32c5-demo -p 127.0.0.1:2501:2501 -e KISMET_USER=demo -e KISMET_PASSWORD=demo -e ESP32C5_DEMO=zigbee esp32c5-kismet:demo
```

With compose, in bash:

```bash
ESP32C5_DEMO=btle docker compose --profile demo up demo
```

With `sudo`, the variable goes after it, or the demo starts on Wi-Fi:

```bash
sudo ESP32C5_DEMO=btle docker compose --profile demo up demo
```

In PowerShell:

```powershell
$env:ESP32C5_DEMO = "btle"
docker compose --profile demo up demo
```

The setting lasts until you close this PowerShell window; `Remove-Item Env:ESP32C5_DEMO` goes back to Wi-Fi. Or put `ESP32C5_DEMO=btle` in `.env`, which works with or without `sudo`. `802154` works as well as `zigbee`, and `ble` as well as `btle`.

## What you should see

1. **The container log** shows the fake board starting and Kismet starting with it:

   ```text
   [esp32c5-kismet] demo: a fake board on /tmp/esp32c5-demo
   [esp32c5-kismet] Kismet starts with 1 source(s)
   ```

   followed by Kismet's own start-up messages. Among them, three lines that look alarming are normal: `ERROR: Tried to re-register duplicate alert FLIPPERZERO` appears at every start of this Kismet version, `ROOTUSER` warns that Kismet runs as root (it does, inside the container), and `LOGDISABLED` appears under compose, which turns logging off.

2. **Data Sources** (in the web UI's menu) lists one source, `demo`, of type `esp32c5`, running. Its hardware reads `ESP32-C5`: a fake board has no MAC to show. That is what Kismet reports through its REST API; the web UI itself has not been looked at in a browser in the tests.
   - Wi-Fi: Kismet hops 42 channels at 5 hops a second, so one pass takes about 8.4 s. The source's channel field keeps showing `6` while it hops: Kismet shows a hopping source's start channel. Each packet's channel is the real one.
   - Zigbee: 16 channels, 11 to 26, starting on 15.
   - BLE: channel 37 only, which stands for all three advertising channels.

3. **Devices** fill in:

   | Radio | Devices | When |
   |---|---|---|
   | `wifi` | Access points `ESP32C5-FAKE-24` (channel 6, 2.4 GHz), `ESP32C5-FAKE-5LOW` (channel 36) and `ESP32C5-FAKE-5HIGH` (channel 149, both 5 GHz) | Each appears once the hopping reaches its channel; all three within the first 35 s in the smoke test |
   | `zigbee` | 802.15.4 devices `10:01` and `25:01`, and `FF:FF`, the broadcast address they send to | Within about 25 s |
   | `btle` | BTLE device `C6:00:00:C5:E5:5A`, named `ESP32C5-FAKE` | Within about 20 s |

   The BTLE device's packet count stays at a few packets while the source's count keeps rising. Kismet drops packets that are byte-for-byte repeats of recent ones, and the fake board repeats one advertisement, as real devices do. Real boards show the same; see [Bluetooth LE Capture](Bluetooth-LE-Capture).

You can also ask Kismet's REST API, with the demo login, for the source's state:

```bash
curl -s -u demo:demo http://localhost:2501/datasource/all_sources.json
```

Look for `"kismet.datasource.running": 1` and a growing `"kismet.datasource.num_packets"`. In Windows PowerShell 5.1, `curl` is another command; write `curl.exe` instead.

To watch what Kismet tells the fake board, read the fake board's own log inside the container. With the `docker run` command above:

```bash
docker exec esp32c5-demo cat /tmp/fake-board.log
```

With compose, `docker compose --profile demo exec demo cat /tmp/fake-board.log`. On Wi-Fi the log shows one `CHANNELS` line for every hop, five a second: that is Kismet hopping the board.

When you are ready for real boards, [Choosing a Setup](Choosing-a-Setup) helps you pick a setup, and [Install with Docker](Install-with-Docker) covers the plain Kismet image the demo is built on.

## The fake board for developers

[`tools/fake_board.py`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tools/fake_board.py) is the fake board the demo uses. It creates a pseudo-terminal that behaves like a board: it answers the firmware's line protocol, reboots in about 0.53 s when asked for another radio, keeps its port open through the reboot as the real board does, and streams made-up traffic that depends on the channel it is tuned to. It needs Python 3 and nothing else, and runs on Linux and in WSL. It does not run on Windows itself, since Windows has no pseudo-terminals; macOS is untested.

1. Start the fake board, from the repository's root directory. The first argument is the path where it puts the port; the second, optional one is the radio to boot with, `WIFI` (the default), `802154` or `BLE`:

   ```bash
   python3 tools/fake_board.py /tmp/esp32c5-fake
   ```

   ```text
   [fake] booted in wifi mode on /tmp/esp32c5-fake -> /dev/pts/3
   ```

   Leave it running, and use a second terminal for the rest. Start it as the same user as the Kismet or the helper that will read it, with `sudo` when you start Kismet with `sudo`: the pseudo-terminal belongs to whoever starts the fake board, and `kismet_cap_esp32c5` does not override file permissions, even when root starts it.

2. Point a Kismet built with the `esp32c5` source ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)) at it, as a local source:

   ```bash
   kismet --no-ncurses -c 'esp32c5:device=/tmp/esp32c5-fake,mode=wifi,name=fake'
   ```

   Or, instead of that local Kismet, feed the fake board to a Kismet server over remote capture with the Python remote helper. Stop the local Kismet first if it is running: it holds the fake board's port. You need:

   - a Kismet server that knows the `esp32c5` source type, and an API key for it with the `datasource` role ([Remote Capture](Remote-Capture) shows how to make one). It can be the same Kismet, started again with no `-c` source: `kismet --no-ncurses`;
   - the helper's packages, installed into a virtual environment in the repository's root directory, as [Development and Testing](Development-and-Testing) does (`sudo apt install python3-venv` first if `venv` is missing).

   From the repository's root directory, install the packages once, then start the helper. Replace the address and the API key with your own:

   ```bash
   python3 -m venv .venv
   .venv/bin/python -m pip install -r requirements.txt
   .venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5:device=/tmp/esp32c5-fake,mode=wifi
   ```

   The fake board's terminal then shows what the helper sends it. While Kismet hops, that includes one `CHANNELS` line per hop, five a second.

3. Ask for another radio to watch a board switch, while the fake board is still on Wi-Fi. With the local Kismet, stop it and start it again with `mode=btle` in its `-c` definition. With the Python remote helper, stop the helper with Ctrl+C and start it again with `mode=btle` in its `--source`; the Kismet server can keep running. Either way, the fake board logs:

   ```text
   [fake] MODE ble: rebooting
   [fake] rebooted in ble mode, the port stayed open
   [fake] CHANNELS 37: scanning 1 channel(s)
   [fake] START answered
   ```

4. Stop the fake board with Ctrl+C.

On Windows, run both in WSL. If you pass a path such as `device=/tmp/esp32c5-fake` from Git Bash to a Windows program, including `docker`, Git Bash rewrites it into a Windows path; set `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` in that shell first, as the project's Docker smoke test does.

### Options for testing the helpers

These options damage or disturb the stream on purpose, to test how the helpers cope. The tests use them; they are not needed to try things out.

| Option | What it does |
|---|---|
| `--garble N` | Every Nth record gets a header no stream can contain, so the helper has to resynchronise. |
| `--inject N` | Every Nth record is a frame whose payload holds the whole restart signature (`<<START>>` and a PCAP header), as anyone on the air could send. |
| `--restart-every N` | Every Nth record the board restarts its stream in place, as after a reset that keeps the port. |
| `--vanish` | On a radio change the port goes away for two seconds and comes back as a new pseudo-terminal behind the same path. |
| `--old-firmware` | BLE records the way the esp32c5-wireshark-sniffer firmware sends them: no CRC flags, CRC zeroed. |
| `--lacks RADIO` | Firmware without that radio, `BLE` or `802154`, as that project's older versions are: `MODE` for it is ignored, and the board goes on answering in its own radio's link type. |
| `--silent` | Says nothing at all and ignores what it is sent, as a board with other firmware, or stuck in its ROM download mode, does. |

N counts from the last `START` the fake board answered, so the damage lands in a stream a helper asked for and is reading.

### How the fake board differs from a real one

- The traffic is made up: about 100 records a second on a channel with traffic, nothing on the others.
- It has no MAC, so the helpers give its source a UUID made from the port's path, and the hardware reads `ESP32-C5`.
- It accepts command words in any case; the firmware accepts them in capitals only.
- It ignores `TXTEST` and writes no UART log. Its `[fake]` lines on its own terminal take the log's place.

The project's end-to-end tests run the helpers against it: [`tests/kismet_e2e.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tests/kismet_e2e.sh) for the C helper, [`tests/remote_e2e.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tests/remote_e2e.sh) for the Python remote helper, and [`tests/docker_smoke.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tests/docker_smoke.sh) for the Docker image. [Development and Testing](Development-and-Testing) explains how to run them.
