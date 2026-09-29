This page covers remote capture: boards plugged into one machine feeding a Kismet server on another. It explains the two ways the Kismet server accepts remote sources, the two helpers that can send them, how to log in with an API key, what happens when a connection drops, and how to keep it secure. It is for anyone whose boards and Kismet server are not on the same machine, including every Windows user, since Kismet does not run on Windows.

> **Note:** Only capture on networks and devices you own or are authorised to test. This holds for the machine with the boards too: a helper at another site records what is around it, and its packets cross the network unencrypted (see "Security and firewalls").

## When you need it

- **Boards on a Windows PC.** The Python remote helper feeds them to Kismet in WSL2, in Docker Desktop, on a Raspberry Pi or on a Linux PC. See [Install on Windows](Install-on-Windows).
- **Kismet in Docker Desktop.** Its containers do not see USB boards. Attaching them to WSL with usbipd should pass them in, but that has not been tested, so the tested set-up keeps the boards on Windows and a helper feeds them in.
- **Boards on one machine, Kismet on another.** For example, a Raspberry Pi with the boards in one room and the Kismet server elsewhere, or several machines feeding one Kismet.

When the boards and Kismet are on the same Linux machine you do not need any of this. Kismet starts the C helper itself for each local source ([Source Definitions](Source-Definitions)).

## How it fits together

```mermaid
flowchart LR
    subgraph near["Machine with the boards"]
        B1["board on COM14 or ttyACM0"] -->|USB| H["helper: kismet_cap_esp32c5 --connect, or python -m esp32c5_kismet.remote"]
        B2["board on COM15 or ttyACM1"] -->|USB| H
    end
    H -->|"websocket on TCP 2501, API key with the datasource role"| K["Kismet server: web UI, REST API and remote capture on port 2501"]
    H -.->|"legacy TCP 3501, no login, loopback only by default"| K
```

The helper does everything a local source's helper does. It opens the port, switches the board to its radio, moves it from channel to channel on Kismet's schedule, and sends every frame on. To the Kismet server a remote source is a source like any other: it appears under **Data Sources**, it can be locked or hopped ([Channel Control](Channel-Control)), and its packets are logged. The difference is that Kismet does not start or restart it. The helper connects, and reconnects when the connection drops.

**The Kismet server must know the `esp32c5` source type.** Build it with [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support), or run the project's Docker image ([Install with Docker](Install-with-Docker)). A stock Kismet refuses these sources with `Kismet could not find a datasource driver for incoming remote source 'esp32c5' ...`; Step 0 below checks the server before you start a helper.

## The two helpers

| | The C helper | The Python remote helper |
|---|---|---|
| Command | `kismet_cap_esp32c5 --connect HOST:PORT --source DEF` | `python -m esp32c5_kismet.remote --connect HOST:PORT --source DEF` |
| Runs on | Linux, installed with Kismet. Also what the Docker image's `helper` role runs. macOS and the BSDs are untested. | Any system with Python 3.10 or newer and `pyserial`, `msgpack` and `websocket-client`. Tested on Windows 11 and Linux. Run it from the project folder; there is no package to install. |
| Boards per process | One `--source` | Any number: repeat `--source`. Each source gets its own connection. |
| Finds boards by | Linux sysfs | pyserial's port list |
| Board away for 15 s | Its capture ends, and the capture framework starts it again 5 s later | It tells Kismet, then reconnects 5 s later by itself |
| Login from the environment | Yes | Yes |

Both use the same source names, UUIDs, `channel=` rules and port lock, and both fill in the CRC for BTLE boards on older firmware. [Command-Line Reference](Command-Line-Reference) lists every option of both.

## Websocket or legacy TCP

The Kismet server takes remote sources two ways:

| | Websocket (the default) | Legacy TCP (`--tcp`) |
|---|---|---|
| Port | Kismet's web port, **2501** | **3501** |
| Login | **Required**: an API key with the `datasource` role, or a Kismet login | **None at all** |
| Where Kismet listens | Wherever the web UI does: all interfaces by default (`httpd_bind_address`) | `127.0.0.1` only by default (`remote_capture_listen`) |
| Turned on by | Always on with the web UI | `remote_capture_enabled=true`, the default |
| Encryption | None in Kismet itself; `--ssl` through a TLS proxy | None |

Use the websocket with an API key. Use `--tcp` only where Kismet and the helper share a machine, or through an SSH tunnel (see "Security and firewalls" below).

With `--connect HOST:3501` and no `--tcp`, both helpers warn you. The C helper prints, on two lines, `WARNING: It looks like you're using a legacy TCP remote capture port, but` / `did not specify '--tcp'; this probably is not what you want!`, and the Python remote helper prints `port 3501 is Kismet's legacy TCP port; did you mean --tcp, or port 2501?`.

## Step 0: Check that the server knows the esp32c5 type

A Kismet without this project's source cannot take these sources, so check first. With the admin login, from any machine that can reach the server, and with the address and password changed to yours:

```bash
curl -s -u admin:PASSWORD http://192.168.1.50:2501/datasource/types.json | grep -o esp32c5
```

It prints `esp32c5` when the type is there, and nothing when it is not. The type's description in that list reads `ESP32-C5 sniffer board: Wi-Fi (2.4/5 GHz), 802.15.4, or BTLE advertising`. A `datasource` API key cannot read this list (Kismet answers HTTP 401), so use the admin login.

## Step 1: Create an API key

Do this once, on the Kismet server, with Kismet's admin login. Give each machine that runs a helper a key of its own.

Why a key with the `datasource` role: it can feed sources to Kismet and nothing else. In the tests such a key got HTTP 401 when it asked for Kismet's list of sources. An admin login also works for remote capture, but it gives the helper's machine full control of Kismet and keeps the admin password there.

**In the web UI:**

1. Open Kismet's web UI, for example `http://192.168.1.50:2501`, and log in.
2. Open **Settings**, then **API Keys**.
3. Enter a **Name**, for example `windows-helper`, and choose the **Role** `datasource`.
4. Click **Create API Key**. The key appears in the table.

These steps follow the web UI's code; they have not been tried in a browser. The tests created their keys over the REST API, as below.

**Over the REST API**, from any machine that can reach Kismet. Change the address, and change `admin` and `PASSWORD` to your Kismet login's user name and password. On a native Kismet the user name is whatever was chosen at the first login; only the Docker image's made-up login uses `admin`.

```bash
curl -u admin:PASSWORD --data-urlencode 'json={"name": "windows-helper", "role": "datasource", "duration": 0}' http://192.168.1.50:2501/auth/apikey/generate.cmd
```

The answer is the key itself, 32 hex characters such as `3F9A6C1E07B24D58A1C9E2F4608B7D35`. This call was tested against Kismet in Docker.

- **Names must be unique.** A second key with the same name fails with `cannot create duplicate auth`.
- **Keys do not expire** at this Kismet version, whatever `duration` says.
- **Keys are kept** in `.kismet/session.db` in the home directory of the user Kismet runs as, and survive restarts. In Docker they are in the `/root/.kismet` volume; a key survived `docker restart` in the tests.
- **List and revoke** keys with the same login:

  ```bash
  curl -u admin:PASSWORD http://192.168.1.50:2501/auth/apikey/list.json
  curl -u admin:PASSWORD --data-urlencode 'json={"name": "windows-helper"}' http://192.168.1.50:2501/auth/apikey/revoke.cmd
  ```

  Kismet answers `revoked`; for a name it does not have, it answers HTTP 500 with `ERROR: cannot delete unknown auth record`. Both answers were checked against a Kismet built from this project's commit.

> **Note:** On Windows, run these `curl` lines in Git Bash or WSL, or create the key in the web UI. They do not work as written in Windows PowerShell 5.1: there `curl` is another command (`Invoke-WebRequest`), and even with `curl.exe`, PowerShell strips the double quotes inside the JSON before `curl.exe` sees them, so Kismet gets invalid JSON and no key is created.

In PowerShell, `curl.exe` with a backslash before each inner quote works instead; [Kismet Configuration](Kismet-Configuration#creating-a-key-with-curl) has this form and the one for cmd:

```powershell
curl.exe -u admin:PASSWORD --data-urlencode 'json={\"name\": \"windows-helper\", \"role\": \"datasource\", \"duration\": 0}' http://192.168.1.50:2501/auth/apikey/generate.cmd
```
<!-- VERIFY: the PowerShell and cmd curl.exe forms against a real Kismet (checked only against a local echo server) -->

## Step 2: Start the helper

On the machine with the boards. The examples feed a Kismet server at 192.168.1.50; change the address, the key and the ports to yours.

**Python remote helper on Windows**, in PowerShell, from the project folder:

```powershell
$env:KISMET_CAP_APIKEY = "3F9A6C1E07B24D58A1C9E2F4608B7D35"
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5-COM14 --source esp32c5zigbee-COM15
```

When Kismet runs in WSL2 or Docker Desktop on the same PC, connect to `127.0.0.1:2501`, or to the port you published. `localhost` also works: the helper tries `127.0.0.1` first. While Kismet is down, though, each refused attempt through `localhost` also tries `::1`, which costs about 2 s more per retry; [Install on Windows](Install-on-Windows) has the details.
<!-- VERIFY: --connect localhost with the current Python remote helper against WSL2 and Docker Desktop, with Kismet up and while it restarts -->

**Python remote helper on Linux**, from the project folder. Install its requirements once, with pip into a virtual environment. Do not use the distribution's packages: Ubuntu 24.04 ships websocket-client 1.7.0, older than `requirements.txt` asks for, and without `pyserial` and `msgpack` the helper stops with `ModuleNotFoundError`. The first line is for Debian, Raspberry Pi OS and Ubuntu, where a fresh install may not have the `venv` module:

```bash
sudo apt-get install -y python3-venv
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Then start it with the environment's Python:

```bash
export KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
.venv/bin/python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5btle-ttyACM0
```

The requirements need Python 3.10 or newer. On the test Raspberry Pi (Raspberry Pi OS, Debian 13) the last two install lines worked as written, with Python 3.13.5 and websocket-client 1.9.2; `python3-venv` was already installed there. The lines have not been tried on Ubuntu.

Two more things a Linux machine with the boards needs:

- The user that runs the helper needs the board's port group, `dialout` on Debian, Ubuntu and Raspberry Pi OS: `sudo usermod -aG dialout $USER`, then log out and in. Without it the open fails with `[Errno 13] ... Permission denied`, and Kismet logs `Error connecting new remote source <name> (<uuid>) - ...` with that reason every 5 s instead of adding the source.
- Name boards by their `/dev/serial/by-id/` link, for example `--source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=btle`. After the helper gives up on a board for 15 s, it waits on the port it was given, so a board that comes back as another `ttyACM` is found again only through its link, or by a definition with no port.

What happens without the group, and a board found again through its link after it came back as another `ttyACM`, have not been tried with the current Python remote helper; both are read from its code.
<!-- VERIFY: dialout and the by-id advice with the current Python remote helper on Linux: the Permission denied path and its Kismet log line, and a board that comes back as another ttyACM found again through its link (inferred from the code, not run) -->

**C helper on Linux**, one board per process:

```bash
export KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
kismet_cap_esp32c5 --connect 192.168.1.50:2501 --source esp32c5zigbee-ttyACM0:name=pi-zigbee
```

**The Docker image's `helper` role** runs the C helper for every board it finds, or for the sources in `KISMET_SOURCES`. It takes the server from `KISMET_SERVER` and the key from `KISMET_APIKEY`, and restarts each helper 5 s after it stops. Both are required: without `KISMET_SERVER` the container stops with `KISMET_SERVER must be HOST:PORT of the Kismet to feed`, and without a key or login with `helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD`.

The steps below need Docker Compose and the project files. Debian's `docker.io` package, which the test Pi used, has no Compose; [Install with Docker](Install-with-Docker) covers installing it, or doing without it with plain `docker run`. If the image cannot be pulled, for example because it has not been published yet, the first start builds it on this machine. On the test Raspberry Pi 4 a first build took about 80 minutes, almost all of it compiling Kismet.
<!-- VERIFY: whether ghcr.io/oshri-almog/esp32c5-kismet:latest is published by the time this page goes live; drop the build sentence if it is -->

1. In the project folder, next to `compose.yaml`, create a file named `.env` with the server's address and the key. Change both to yours:

   ```ini
   KISMET_SERVER=192.168.1.50:2501
   KISMET_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
   ```

   Add a `KISMET_SOURCES=` line to choose the boards and radios. Without it, every board found is fed in the radio `ESP32C5_MODE` names, Wi-Fi unless set.
2. Start the helper service from the same folder:

   ```bash
   sudo docker compose --profile helper up -d helper
   ```

Use `.env` rather than variables typed before the command: `sudo` does not pass your shell's variables on to Docker. [Install with Docker](Install-with-Docker) walks through it, and [Docker Reference](Docker-Reference) lists the variables.

Anything else you would put in a source definition goes in `--source`: `name=`, `channel=` with `channel_hop=false`, Kismet's `channels=`. See [Source Definitions](Source-Definitions).

## Step 3: Check it in Kismet

- Kismet logs `New remote source <name> (<uuid>) connected`, then the helper's `capturing` message, prefixed with the source's name: for example `INFO: pi-zigbee - pi-zigbee capturing (zigbee)`. The C helper's status messages (`capturing`, `lost sync`, the 15 s give-up) appear only there, in Kismet's log. Its own terminal shows the capture framework's lines, such as `INFO: 192.168.1.50:2501 starting capture...`.
- In the web UI the source appears under **Data Sources**, with the helper's address in its **Address** row. Its **Retry on Error** row reads "Remote sources are not re-opened by Kismet, but will be re-opened when the remote source reconnects." (This is read from the web UI's code; the tests checked Kismet over its REST API, not in a browser.)
- The Python remote helper logs, one line per event:

  ```text
  14:02:11 INFO: esp32c5-COM14: connected, offering it to Kismet as E5C50001-0000-0000-0000-F0F5BD010203
  14:02:11 INFO: esp32c5-COM14: opening COM14 for wifi
  14:02:11 INFO: esp32c5-COM14: COM14 opened
  14:02:12 INFO: esp32c5-COM14 capturing (wifi)
  ```

  Add `--debug` to see every protocol message except the packets.
- With several machines feeding one Kismet, give each source a `name=` that says where it is. The default name is the interface, such as `esp32c5-ttyACM0`, which repeats from one machine to the next. The UUIDs do not clash, because each comes from its board's MAC.

## Logins and the environment

| Where the login comes from | Example |
|---|---|
| An API key on the command line | `--apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35` |
| A Kismet login on the command line | `--user admin --password PASSWORD` |
| An API key in the environment | `KISMET_CAP_APIKEY` |
| A Kismet login in the environment | `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`, both |

**Prefer the environment.** Anything on a command line can be read by every user of the machine in the process list. Both helpers read the same three variables. The rules:

- A value on the command line wins over the environment.
- The environment is read only for the websocket, never with `--tcp`, which has no login.
- With no login on the command line, `KISMET_CAP_APIKEY` is used if set, otherwise `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD` together. An empty variable counts as unset.
- Both helpers complete half a login from the environment: `--user` alone takes the password from `KISMET_CAP_PASSWORD`, and `--password` alone takes the user from `KISMET_CAP_USER`. An API key in the environment never completes a login. If the other half is not in the environment either, the C helper stops with `FATAL:  Must specify both username and password`, and the Python remote helper with `give both --user and --password (the one left out may also be in KISMET_CAP_USER or KISMET_CAP_PASSWORD)`.
- With both a login and a key on the command line, the login is used. The C helper warns `WARNING: Ignoring APIKEY and using login information`; the Python remote helper warns `ignoring --apikey and using the login`.
- With no login anywhere, the helper stops. The C helper prints `FATAL: User and password or API key required for remote capture`; the Python remote helper prints `a user and password, or an API key, are required for the websocket protocol (...)` and exits with status 2.

**How the login travels.** Neither helper puts a secret in the websocket's address. A login goes in an `Authorization: Basic` header and an API key in Kismet's session cookie (`Cookie: KISMET=<key>`), so a password with `&`, a space or `%41` in it logs in as it is. There is one exception: a user name that contains `:`, which the Basic header cannot carry. Such a login goes in the address instead (`?user=...&password=...`, percent-encoded), where a proxy's access log keeps it, and if the user name or the password also holds an `&`, it cannot log in at all, because Kismet decodes the whole address before it splits it at `&`. Both helpers warn about that one before they connect, in the same words (the C helper on its standard error, the Python remote helper as a logged WARNING):

```text
WARNING: the Kismet user name holds ':' and the login '&': Kismet reads a user name in an Authorization header only up to its first ':', and cuts a login in the websocket's address at every '&' (after decoding it), so this one cannot log in either way; use an API key (--apikey or KISMET_CAP_APIKEY) instead of the login
```

The Docker `helper` role refuses to start with such a login: `helper: a KISMET_USER with ':' in it cannot log in over remote capture when KISMET_USER or KISMET_PASSWORD holds '&'; use KISMET_APIKEY`. API keys that Kismet makes are 32 hex characters and never have the problem. The header login and the cookie were checked end to end against a real Kismet, with a password holding `&`, a space and `%41` and through a proxy that logs every request, but not yet on the test Pi. A working login whose user name holds `:` has not been tried against a real Kismet (one with `:` and `&` was refused with 401 on the Pi by an earlier build, as expected).
<!-- VERIFY: round-2 Pi check, both helpers: logins with '&', a space and '%41', and API keys, through a logging proxy (no secret in any request line); a ':' user-name login -->

To keep a key out of your shell history on Linux, you can keep it in a file only you can read and load it from there: `export KISMET_CAP_APIKEY=$(cat ~/.esp32c5-apikey)`.

## When the connection drops

**What Kismet does.** Kismet never re-opens a remote source itself; it waits for the helper to come back. It pings every 5 s and puts a source in error when there is no answer for more than 15 s. When a helper stops or loses its connection, the source shows an error with the reason `websocket connection closed`, or `IPC connection closed` over `--tcp`. That is expected.

When the helper comes back with the same UUID, Kismet picks up the same source, with its history and devices:

```text
Matching new remote source 'esp32c5-COM14' with known source with UUID 'E5C50001-0000-0000-0000-F0F5BD010203'
Remote source esp32c5-COM14 (E5C50001-0000-0000-0000-F0F5BD010203) reconnected
```

The UUID comes from the board's MAC and the radio ([Multiple Boards](Multiple-Boards)), so it stays the same across reconnects, restarts and port renames. After a reconnect Kismet may keep showing the old error text, such as `websocket connection closed`, on a running source. That is an upstream display quirk.

Two more things follow from Kismet knowing a remote source by its UUID:

- **It keeps the source's old options.** Within one run of Kismet, a source that reconnects under a known UUID keeps every option of its earlier definition that the new one leaves out, such as `channel_hop=false`, `channels=` or `name=`. Options the new definition gives replace the old ones. So a board once locked with `channel_hop=false` stays locked after you restart its helper without that option: write `channel_hop=true`, or restart Kismet.
- **Closing a remote source lasts only until the helper reconnects.** `close_source.cmd`, which the web UI's **Close** also calls, ends the connection; the helper connects again about 5 s later, and Kismet runs the source again. To stop a remote source, stop its helper.

**Run one helper per board.** The same board and radio give the same UUID wherever they are captured from, and when a second connection arrives with the UUID of a running source, Kismet closes the running one (`... which is still running.  The running instance will be closed ...`). So on Linux both helpers check, before every connection, whether another capture holds the board's port, and while one does they do not offer the source to Kismet: the C helper stops that attempt with `FATAL: Could not probe local source prior to connecting to the remote host: <name>: <device> is already in use by another capture; not offering it to Kismet until it is free (looked at again every 5 seconds)`, and the Python remote helper logs the same `<name>: <device> is already in use ...` text once, as a WARNING. The running capture carries on. On Windows the Python remote helper cannot check first, so a second copy of the same source, such as a helper started by hand next to one started at logon, would knock the running one off. This follows from the code; it has not been tried on Windows.

**The C helper.** Unless you pass `--disable-retry`, Kismet's capture framework runs the capture in a child process and starts it again 5 s after it ends. It logs:

```text
INFO: capture process exited <code> signal <sig>
INFO: Sleeping 5 seconds before attempting to reconnect to remote server
```

That covers a Kismet server that is not up yet (`FATAL: Datasource could not connect websocket`, then the 5 s wait; seen in the Docker tests), a Kismet restart, and a board that stayed away for 15 s. Before each connection the helper checks its definition. When it cannot offer the source, it stops that attempt without connecting, with `FATAL: Could not probe local source prior to connecting to the remote host: <reason>`, and the framework tries again 5 s later, for as long as the helper runs (with `--disable-retry` it exits instead). It cannot offer the source:

- when a definition that names no port (a bare `esp32c5`, or a free-form name such as `esp32c5-kitchen`) finds no board, or more than one;
- when the definition has an unknown `mode=` (not `wifi`, `zigbee` or `btle`) or a `channel=` the radio does not have;
- on Linux, when another capture holds the board (above).

A definition that names a port (`esp32c5-ttyACM0`, `device=`, a `/dev/serial/by-id/` link) whose board is missing connects anyway, and the open fails. Kismet logs why, for example `Error connecting new remote source esp32c5-ttyACM0 (<uuid>) - cannot open /dev/ttyACM0: No such file or directory`, and does not add a source whose first open failed to its list. The helper tries again every 5 s, and the source appears once the board is back. (On the test Pi, opens that failed for another reason, a board in use, were logged this way every 5 s; a missing board has not been tried.)
<!-- VERIFY: a remote C helper whose named board is missing: Kismet logs "Error connecting new remote source ... - cannot open ...", lists no source for it, and the source appears (under the board's MAC UUID, with no second source) once the board is plugged in -->


The Docker `helper` role runs each C helper in a loop that starts it again 5 s after it exits, whatever the reason.

**The Python remote helper.** Each `--source` runs in a loop until you stop the helper: find the board, connect, capture. Whatever goes wrong, it waits 5 s and starts again.

| What happens | What the helper does |
|---|---|
| The Kismet server is down or restarting | Logs the refused connection, such as `[Errno 111] Connection refused` or `[WinError 10061] ...`, and retries every 5 s |
| The board is not plugged in | Does not contact Kismet. Logs the reason every 5 s, for example `esp32c5-COM14: COM14 is not there; is the board plugged in? (waiting for it)` |
| The board stops capturing for 15 s | Tells Kismet (the source's error reads `remote connection triggered shutdown: esp32c5-COM14: no capture from the board on COM14 for 15 seconds (last: ...); is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?`), closes the connection and reconnects 5 s later |
| Kismet refuses the key or login (HTTP 401) | `Kismet refused the websocket: ... (check the login -- --user/--password or KISMET_CAP_USER/KISMET_CAP_PASSWORD -- or the API key -- --apikey or KISMET_CAP_APIKEY; the key needs the datasource role)`, retried every 5 s |

After a Kismet restart the helper connects again at its next try, at most 5 s after Kismet is back, and captures about 1 s later: on the test Pi it was connected 1 to 4.2 s after Kismet's web port answered, and on Windows, with Kismet in Docker Desktop, 7 s after `docker restart`. It exits with status 0 when you stop it (Ctrl+C, Ctrl+Break on Windows, or SIGTERM). A source never ends by itself, so status 1 means an internal error ended every source; a service manager can then restart it.

## Start-up time, latency and timestamps

Measured on the Raspberry Pi with one Wi-Fi board and Kismet on the same Pi, five runs each:

| Helper and transport | From starting the helper to its first packet in Kismet |
|---|---|
| C helper, websocket | 1.2 to 1.4 s (1.2 s in four runs of five) |
| C helper, `--tcp` | 1.2 to 1.6 s |
| Python remote helper, websocket | 1.4 to 1.8 s |

After the first packet, packets kept arriving steadily with all three, in nearly every second (the longest gap was about 2 s), with no 5 s bursts. So the websocket costs nothing in speed over `--tcp`, which has no login. A C helper built before `add-to-kismet.sh` fixed Kismet's capture framework took 5 to 6 s over the websocket and then delivered its packets in bursts every 5 s; rebuilding it with the current script cures that ([Guide: Updating](Guide-Updating)).

**Timestamps.** The Kismet server stamps each packet from a remote source with the time it arrived, not the time the board recorded it (Kismet's `override_remote_timestamp=true`). To keep the board's own times, add `timestamp=false` to the source definition. The helper sets the board's clock from its own machine's clock when capture starts, so that machine's clock should be right. With the C helper and a simulated board whose clock ran an hour behind, the kismetdb held the board's times with `timestamp=false` and the arrival times without it.

## Security and firewalls

Port 2501 carries Kismet's web UI, its REST API and websocket remote capture, and Kismet listens on it on all network interfaces by default.

1. **Set Kismet's admin login before the port is reachable.** Until a login exists, the first visitor to port 2501 chooses it. The project's Docker image always sets one at start. See [Kismet Configuration](Kismet-Configuration) and Kismet's own [web server documentation](https://www.kismetwireless.net/docs/readme/configuring/webserver/).
2. **Use a `datasource` API key per helper machine**, not the admin login. Revoke a machine's key when you retire it.
3. **Firewall the Kismet server.** Allow TCP 2501 only from the machines that run helpers and from where you use the web UI. The machine with the boards needs no inbound rule: the helpers only connect out.
4. **Nothing is encrypted.** Kismet has no TLS of its own at this version. The helpers keep the login and the API key out of the websocket's address, in request headers (see "Logins and the environment"; a user name with `:` is the exception), so a proxy's access log does not record them, but on the network they are plain text like everything else. Across a network you do not trust, put a TLS reverse proxy in front of Kismet and give the helper `--ssl`, plus `--ssl-certificate CAFILE` for a private certificate authority. If the proxy serves Kismet under a path such as `/kismet`, set Kismet's `httpd_uri_prefix=/kismet` and give the helper `--endpoint /kismet/datasource/remote/remotesource.ws`. Or use an SSH tunnel. Both helpers captured through a TLS proxy on the test Pi, with `--ssl-certificate`, and with `--endpoint` through a proxy that serves Kismet under a prefix; that was with a build from before the login moved into headers, and has not been repeated through a real proxy since. The current helpers were checked against stand-in TLS servers only: the C helper sent its API key cookie over `--ssl` with `--ssl-certificate`, and the Python remote helper's TLS test session passes. A login in the Basic header over TLS was not checked for the C helper.
   <!-- VERIFY: --ssl through a real TLS reverse proxy in front of Kismet, both helpers, with the login in the Basic header and the key in the cookie -->

   Neither helper follows a redirect on the websocket. Kismet never answers it with one, and the login would go along to wherever it points. So a proxy that redirects, for example from `http://` to `https://` or to a sign-in page, makes each attempt fail, and the helper tries again 5 s later. The C helper prints `FATAL: The websocket was answered with a redirect, which is not followed: Kismet never redirects it, and the login would go along to wherever it points; check --connect, --endpoint and --ssl`; the Python remote helper logs `the websocket was answered with a redirect (HTTP <status> to <location>), which the helper does not follow: ...` with the same advice. Correct `--connect`, `--endpoint` or `--ssl`. This was tested against a server that redirects, not against a real proxy.

   Both helpers also go through an HTTP proxy set in their environment, and the login goes through its tunnel. The C helper's websocket library (libwebsockets) takes `http_proxy` and ignores `no_proxy`: with `http_proxy` set, every websocket connection goes through that proxy, even one to `127.0.0.1`. When the proxy cannot reach Kismet, the helper prints only `FATAL: Datasource could not connect websocket client`. The Python remote helper takes `http_proxy`, or `https_proxy` with `--ssl`, and leaves out the hosts in `no_proxy` (`localhost` and `127.0.0.1` when `no_proxy` is not set). Neither uses a proxy with `--tcp`. If a proxy is set for other programs, start the helper without it, for example `env -u http_proxy -u https_proxy kismet_cap_esp32c5 --connect ...`. The C helper's use of `http_proxy` was seen against a logging proxy; the Python remote helper's is read from websocket-client's code, not run.
5. **Keep legacy TCP on loopback.** Port 3501 has no login at all: anyone who can reach it can feed Kismet. Kismet listens on it on `127.0.0.1` by default. To use `--tcp` from another machine with a native Kismet, keep it that way and tunnel with SSH, as Kismet's own configuration advises. On the machine with the boards:

   ```bash
   ssh -N -L 3501:127.0.0.1:3501 user@192.168.1.50
   ```

   Change `user` to your login on the Kismet server and `192.168.1.50` to its address. Then, in a second terminal on the same machine:

   ```bash
   kismet_cap_esp32c5 --connect 127.0.0.1:3501 --tcp --source esp32c5btle-ttyACM0
   ```

   Both helpers captured over `--tcp` through SSH tunnels on the test Pi.

   **With the project's Docker image this tunnel reaches nothing.** The image keeps 3501 on the container's own loopback and does not publish it, so nothing outside the container can connect to it. Use the websocket with the image. If you need `--tcp` there, mount your own `kismet_site.conf` over `/etc/kismet/kismet_site.conf` with `remote_capture_listen=0.0.0.0`, keeping the lines of the image's own file (`log_prefix=/data/` and its `mask_datasource_type` lines; [Kismet Configuration](Kismet-Configuration#the-docker-images-configuration)), and publish the port on the host's loopback only, with `-p 127.0.0.1:3501:3501`. The same tunnel then reaches it.
   <!-- VERIFY: --tcp to the Docker image with remote_capture_listen=0.0.0.0 in a mounted kismet_site.conf and -p 127.0.0.1:3501:3501, through an SSH tunnel (not tested) -->

   Setting `remote_capture_listen=0.0.0.0` in `kismet_site.conf` without such a loopback-only publish opens 3501 to the whole network. Do that only on a network you trust completely.
6. **Docker:** a port published with `-p` or in `compose.yaml` bypasses host firewall tools such as ufw. That is general Docker behaviour and was not tested here. See [Install with Docker](Install-with-Docker).

**Discovery.** The C helper also has `--autodetect`, from Kismet's capture framework. It listens for the Kismet server's announcements on UDP 2501. The server does not send them by default (`server_announce=false`), and when it does, they point helpers at the legacy TCP port, so `--autodetect` needs `--tcp` as well. The Python remote helper has no such option. `--autodetect` has not been tested with these boards; name the server with `--connect` instead.

## What was tested

- **Windows 11 to Kismet in WSL2 on the same PC:** the Python remote helper with a Kismet login and a board on COM32, about 3 minutes each for Wi-Fi and BTLE. A Zigbee source with `channel=20,channel_hop=false` showed that the helper then ignored `channel=`; that has been fixed since.
- **Windows 11 to Kismet in Docker Desktop on the same PC:** the Python remote helper, first with a login and then with a `datasource` API key. The Wi-Fi source hopped all 42 channels at 5 a second with no error packets. A channel lock over the REST API worked. After `docker restart` the helper was connected again in 7 s, and the key survived.
- **Raspberry Pi 4 with four boards:** the C helper over the websocket and over `--tcp`, and the Python remote helper over the websocket, each feeding Kismet on the same Pi. Checked there: the start-up times above, logins from the environment and API keys, a second helper for a board in use, stopping a helper, `close_source`, Kismet restarts, a TLS proxy, and `--tcp` through SSH tunnels.
- **Without hardware (WSL2):** `tests/kismet_e2e.sh` runs the C helper with `--connect` against a real Kismet and the fake board, through a relay that logs every request: the login in its Basic header, the API key in the cookie, a redirect refused, a second helper refused, `close_source` and the reconnect after it. `tests/remote_e2e.sh` runs the Python remote helper over the websocket and `--tcp`: its login in the Basic header, the API key in the cookie through a logging proxy, a second source on a board in use not offered, and a Kismet restart that must give back the same UUID. The Python helper's refusal of a redirect was checked separately, against a redirecting server. `tests/docker_smoke.sh` runs the Docker `helper` role, feeding Kismet in a second container. See [Development and Testing](Development-and-Testing).
- **The latest changes have not been on the Pi yet.** The login in headers, the refusal of redirects, a refused channel answered the same way by both helpers, and status messages that start with the source's name were tested only in WSL2, with the fake board and a real Kismet.
- **Not tested: a helper on one machine feeding a Kismet server on another across a real network.** Every run so far had both on one computer.

<!-- VERIFY: a helper feeding a Kismet server on another machine across a LAN -->

## Troubleshooting

| Message | From | Cause | Fix |
|---|---|---|---|
| `FATAL: User and password or API key required for remote capture` | C helper | No login anywhere | Set `KISMET_CAP_APIKEY`, or pass `--apikey` |
| `a user and password, or an API key, are required for the websocket protocol ...` | Python remote helper | No login anywhere | The same |
| `Kismet refused the websocket: ... (check the login -- ... the key needs the datasource role)` | Python remote helper | Wrong key or login, or a key without the `datasource` (or `admin`) role | Create a `datasource` key (step 1) |
| `lws_client_ws_upgrade: got bad HTTP response '401'`, then `FATAL: Datasource could not connect websocket client` | C helper | The same | The same |
| `WARNING: the Kismet user name holds ':' and the login '&': ...` | Both helpers | A user name with `:` and an `&` in the login, which cannot log in | Use an API key |
| `FATAL: The websocket was answered with a redirect, which is not followed: ...`, or `the websocket was answered with a redirect (HTTP ...` | C helper, Python remote helper | Something between the helper and Kismet, usually a proxy, answers with a redirect | Check `--connect`, `--endpoint` and `--ssl` |
| `port 3501 is Kismet's legacy TCP port; did you mean --tcp, or port 2501?` | Python remote helper | Port 3501 without `--tcp` | Use port 2501, or add `--tcp` |
| `[Errno 111] Connection refused`, `[WinError 10061] ...` | Python remote helper | Kismet is not running, or is on another address or port, or a firewall is in the way | Check `--connect` and the firewall. The helper keeps retrying. |
| `FATAL: Could not probe local source prior to connecting to the remote host: ...` | C helper | `--source` names no port and there is no board or more than one; an unknown `mode=` or a `channel=` the radio lacks; or another capture holds the board | Plug it in or name its port; correct the definition; stop the other capture. The helper tries again every 5 s. |
| `Kismet could not find a datasource driver for incoming remote source ...` | Kismet server | Kismet was built without the `esp32c5` source | Build it with `add-to-kismet.sh`, or use the Docker image |
| `Error connecting new remote source <name> (<uuid>) - <reason>` | Kismet server | The helper connected, but could not open the board: the reason says why (missing, in use, no permission) | Fix what the reason names. The helper tries again every 5 s. |
| Source in error: `websocket connection closed` | Kismet server | The helper stopped or lost its connection | Expected. The source resumes when the helper reconnects. |

More on [Troubleshooting](Troubleshooting) and, for Windows, [Install on Windows](Install-on-Windows).

## See also

- [Install on Windows](Install-on-Windows): the Python remote helper step by step
- [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi): a worked example
- [Command-Line Reference](Command-Line-Reference): every option of both helpers
- [Docker Reference](Docker-Reference): the `helper` role
- [Multiple Boards](Multiple-Boards): naming boards, UUIDs, one board per source
- The Python remote helper's source: [esp32c5_kismet/remote.py](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/esp32c5_kismet/remote.py)
