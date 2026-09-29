This guide makes a capture setup start by itself: Kismet with its board sources as a systemd service, the C helper or the Python remote helper feeding a remote Kismet as a service, the Docker containers through their restart policy, and the Python remote helper at logon on Windows. It is for a machine that should capture unattended, such as a Raspberry Pi in a cupboard.

> **Note:** Only capture on networks and devices you own or are authorised to test. A setup that starts by itself keeps recording until you stop it, so decide where the logs go and who can read them. To keep other people's devices out of the log, see [Kismet Configuration](Kismet-Configuration#logging-only-your-own-devices).

**Status:** none of the service set-ups on this page has been tested in this project yet. Kismet's own unit file, the restart policies and the helpers' behaviour are taken from their code and documentation; each untested step is marked for checking. What has run by hand, on the test Pi: Kismet started in a terminal with its sources given by `-c`, and the C helper feeding Kismet over remote capture with `--connect` and a `--user`/`--password` login. Permanent `source=` lines, the login from `KISMET_CAP_APIKEY`, and the current Python remote helper on Linux have not run yet. <!-- VERIFY: set up each of the five parts on the Pi / Windows, reboot, and confirm the sources come back; then remove this paragraph -->

| What | Where it runs | Section |
|---|---|---|
| Kismet with boards plugged into the same machine | Raspberry Pi or Linux, native build | [Kismet as a systemd service](#kismet-as-a-systemd-service) |
| Boards on this machine, Kismet on another | Raspberry Pi or Linux, native build | [The C helper as a service](#the-c-helper-as-a-service) |
| Boards on this machine, Kismet on another, without building Kismet here | Raspberry Pi or Linux, Python | [The Python remote helper as a service on Linux](#the-python-remote-helper-as-a-service-on-linux) |
| Either of the two, in Docker | Raspberry Pi or Linux with Docker | [Docker: restart policies](#docker-restart-policies) |
| Boards on a Windows PC, Kismet elsewhere | Windows | [The Python remote helper at logon on Windows](#the-python-remote-helper-at-logon-on-windows) |

The examples use the user `pi` with home `/home/pi`, Kismet built into `/home/pi/kismet-install` as in [Install on Raspberry Pi](Install-on-Raspberry-Pi), a Kismet server at `192.168.1.50`, and board names from `/dev/serial/by-id/`. Change them to yours.

## Kismet as a systemd service

Kismet's source tree has a systemd unit. `configure` writes it, with your install prefix filled in, to `packaging/systemd/kismet.service`, but `make install` does not install it. As shipped it runs Kismet as root. This section installs it and runs Kismet as your user instead, which is all the boards need: the helper needs read and write access to the serial port and nothing else.

### 1. Put the sources and the log folder in kismet_site.conf

A service has no command line to type `-c` on, and it starts in `/`, where your user cannot write a log. Kismet's default `log_prefix=./` would make it fail with `Unable to open KismetDB log at ...` and exit. So make a log folder:

```bash
mkdir -p /home/pi/kismet-logs
```

Then create `/home/pi/kismet-install/etc/kismet_site.conf` (Kismet reads it last, and its settings win):

```ini
# One source per board, by its stable name. Change the MACs to your boards' (ls -l /dev/serial/by-id/).
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=btle,name=c5-btle

# Logs go here. The folder must exist and belong to the service's user.
log_prefix=/home/pi/kismet-logs/
```

<!-- VERIFY: source= lines in kismet_site.conf start these sources (the field runs used -c only), and Kismet started without -c picks them up -->

Name the boards by their `/dev/serial/by-id/` links, not by `ttyACM` numbers, which follow the order in which the boards come up. A board that is not there yet when Kismet starts is no problem: Kismet reports the source's error and tries to open it again every 5 s until the board appears.

For a Kismet that only receives remote sources, for example from [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi), leave out the `source=` lines and keep `log_prefix`.

### 2. Set the web login

The service runs Kismet as `pi`, so Kismet reads its login from `pi`'s home directory. If you have not set one yet (see [Guide: First Capture](Guide-First-Capture)):

```bash
mkdir -p /home/pi/.kismet
printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > /home/pi/.kismet/kismet_httpd.conf
chmod 600 /home/pi/.kismet/kismet_httpd.conf
```

Without a login, the first person to open port 2501 after boot would choose it.

### 3. Install Kismet's unit

Check that the unit points at your install:

```bash
grep -E 'ExecStart|User' ~/src/kismet/packaging/systemd/kismet.service
```

```text
User=root
ExecStart=/home/pi/kismet-install/bin/kismet --no-ncurses-wrapper
```

<!-- VERIFY: this grep output on the Pi's configured tree (derived from kismet.service.in, not run) -->

Install it, then change the user it runs as:

```bash
sudo cp ~/src/kismet/packaging/systemd/kismet.service /lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl edit kismet
```

`systemctl edit` opens an editor for an override. Put in:

```ini
[Service]
User=pi
Group=pi
SupplementaryGroups=dialout
```

and save. `dialout` is the group that owns `/dev/ttyACM*` on Debian and Raspberry Pi OS. <!-- VERIFY: whether SupplementaryGroups=dialout is needed, or systemd already gives User=pi its groups; harmless either way -->

Kismet's unit also has `Restart=always`, so systemd starts Kismet again if it exits.

### 4. Start it, and at every boot

```bash
sudo systemctl enable kismet
sudo systemctl start kismet
```

Check it:

```bash
systemctl status kismet
journalctl -u kismet -f
```

Kismet's own log lines go to the journal. Look for `Loading config override file '/home/pi/kismet-install/etc/kismet_site.conf'`, one `capturing` line per source (for example `INFO: wifi-a capturing (wifi)`), and `Opened kismetdb log file '/home/pi/kismet-logs/...'`. Ctrl+C stops following the journal, not Kismet. <!-- VERIFY: Kismet's messages under systemd appear in the journal as shown -->

To stop it, for example before flashing a board:

```bash
sudo systemctl stop kismet
```

`sudo systemctl disable kismet` stops it from starting at boot.

Why not keep the shipped `User=root`: Kismet then raises a `ROOTUSER` alert, reads its login from `/root/.kismet`, and runs the helpers as root, which this helper does not need. Kismet's own documentation recommends running it as a normal user.

## The C helper as a service

On a machine with boards but no Kismet server, such as a second Pi, the C helper `kismet_cap_esp32c5` can feed the boards to a Kismet elsewhere over remote capture. It comes with the native build ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)); you do not have to run Kismet on this machine. Each helper takes one `--source`, so run one service per board.

### 1. Store the API key

Create an API key with the `datasource` role on the Kismet server ([Remote Capture](Remote-Capture)), and store it where only root can read it. The helper reads it from the environment variable `KISMET_CAP_APIKEY`, which keeps it off the command line and out of the process list:

```bash
echo 'KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35' | sudo tee /etc/esp32c5-helper.env > /dev/null
sudo chmod 600 /etc/esp32c5-helper.env
```

Change the key to yours. The key then also sits in your shell history; clear that line if it matters.

<!-- VERIFY: the C helper logs in with KISMET_CAP_APIKEY from this EnvironmentFile (in the code, not used in the field runs, which passed --user/--password) -->

### 2. Write the unit

Create `/etc/systemd/system/esp32c5-helper-wifi.service`, for example with `sudo nano`:

```ini
[Unit]
Description=ESP32-C5 board to a remote Kismet (Wi-Fi)
After=network-online.target
Wants=network-online.target

[Service]
User=pi
Group=pi
SupplementaryGroups=dialout
EnvironmentFile=/etc/esp32c5-helper.env
ExecStart=/home/pi/kismet-install/bin/kismet_cap_esp32c5 --connect 192.168.1.50:2501 --source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=pi-wifi
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Change the server address, the board's link and the name. For a second board, copy the file under another name (`esp32c5-helper-btle.service`) with that board's `--source`.

<!-- VERIFY: this unit on the Pi: the helper connects, reconnects after a Kismet restart, and comes back after a reboot -->

How it behaves:

- **Kismet goes away:** the helper reconnects by itself every 5 s until Kismet is back, and Kismet recognises the source by its ID.
- **The board is missing when the helper starts:** with the board named by its `/dev/serial/by-id/` link, as in this unit, the helper connects anyway. Kismet shows the source in error with `cannot open /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00: No such file or directory`, and the helper tries again every 5 s until the board is there. Only a definition that names no port, such as a bare `esp32c5` or a free-form name like `esp32c5-kitchen`, stops before connecting when there is no board or more than one: `FATAL: Could not probe local source prior to connecting to the remote host: ...`. The helper then tries again 5 s later.
- **The board disappears while capturing:** after 15 s without capture the helper gives up on it, and it is started again 5 s later, by the helper's own retry or, if the helper exits, by systemd.

<!-- VERIFY: remote C helper with a missing by-id board: message seen, retry, and whether Kismet lists a second source once the board appears; also how often a bare esp32c5 with no board prints the FATAL line, and whether the helper retries it by itself -->

> **Warning:** A board that is missing when the helper connects can leave a stale second source in Kismet's list. Without the board, the helper cannot read its MAC, so it offers the source under an ID made from the path instead. Once the board is back, the helper reconnects under the board's usual ID, and Kismet, which matches remote sources by ID only and never removes one, keeps the first one listed, in error. This happens at start, and also when the helper reconnects after giving up on an unplugged board. The stale source holds no packets. Kismet has no command to remove it; it goes when Kismet restarts. To avoid it, plug the boards in before the service starts. <!-- VERIFY: the stale source disappears after a Kismet restart -->

### 3. Start it, and at every boot

```bash
sudo systemctl daemon-reload
sudo systemctl enable esp32c5-helper-wifi
sudo systemctl start esp32c5-helper-wifi
journalctl -u esp32c5-helper-wifi -f
```

On the Kismet server the source appears under **Data Sources** as a remote source, and Kismet logs `New remote source pi-wifi (...) connected`. On the test Pi, an earlier build of the C helper took about 3 to 5.4 s over the websocket from connecting to capturing, and delivered its first packets in bursts. <!-- VERIFY: re-measure the websocket start-up delay with the current build -->

Stop the helper before you use the board for anything else, or before flashing it: `sudo systemctl stop esp32c5-helper-wifi`.

## The Python remote helper as a service on Linux

The Python remote helper also runs on Linux, and needs no Kismet build on this machine: only Python and the project's three packages. One process takes several `--source` options, so one service covers all the boards. It exits with status 0 when systemd stops it (SIGTERM), with 1 only when every source has stopped by itself, and with 2 for a mistake on its command line.

### 1. Install it in a virtual environment

In the project folder (clone it there first if this machine has no copy):

```bash
sudo apt-get install -y python3-venv
cd /home/pi/esp32c5-kismet-wifi-interface
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

### 2. Store the API key

Store the key in `/etc/esp32c5-helper.env` exactly as in [step 1 of the C helper section](#1-store-the-api-key). The Python remote helper reads the same `KISMET_CAP_APIKEY` when no `--apikey`, `--user` or `--password` is given.

### 3. Write the unit

Create `/etc/systemd/system/esp32c5-remote-helper.service`:

```ini
[Unit]
Description=ESP32-C5 boards to a remote Kismet (Python remote helper)
After=network-online.target
Wants=network-online.target

[Service]
User=pi
Group=pi
SupplementaryGroups=dialout
EnvironmentFile=/etc/esp32c5-helper.env
WorkingDirectory=/home/pi/esp32c5-kismet-wifi-interface
ExecStart=/home/pi/esp32c5-kismet-wifi-interface/.venv/bin/python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=pi-wifi --source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=btle,name=pi-btle
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=2

[Install]
WantedBy=multi-user.target
```

Change the folder, the server address, the boards' links and the names.

- `WorkingDirectory` matters: the helper runs as `python -m esp32c5_kismet.remote` and is found only from the project folder.
- `Restart=on-failure` starts it again after status 1; `RestartPreventExitStatus=2` keeps a typo on the command line from restarting it every 5 s.
- A board named by its link that is missing is waited for, not offered to Kismet under a stand-in ID, so unlike the C helper this leaves no stale source in Kismet's list.

<!-- VERIFY: this unit on the Pi (the current Python remote helper has not run on Linux with real boards): exit status 0 on systemctl stop, a restart after exit status 1, no restart after status 2, and a missing by-id board waited for without a second source in Kismet -->

### 4. Start it, and at every boot

```bash
sudo systemctl daemon-reload
sudo systemctl enable esp32c5-remote-helper
sudo systemctl start esp32c5-remote-helper
journalctl -u esp32c5-remote-helper -f
```

Stop it before you use a board for anything else, or before flashing: `sudo systemctl stop esp32c5-remote-helper`.

## Docker: restart policies

The project's `compose.yaml` gives the `kismet` and `helper` services `restart: unless-stopped`. Start them once:

```bash
sudo docker compose up -d
```

or, for the helper service on a machine with boards but no Kismet:

```bash
sudo docker compose --profile helper up -d helper
```

From then on Docker starts them again whenever Docker itself starts, including after a reboot, unless you stopped them yourself. `sudo docker compose stop` counts as stopping them: they stay stopped after a reboot until you run `up -d` again. The `demo` service has no restart policy. With plain `docker run`, the same is `--restart unless-stopped` ([Install with Docker](Install-with-Docker)).

Docker's own service has to start at boot for this to work. Check it, and enable it if it prints `disabled`:

```bash
systemctl is-enabled docker
sudo systemctl enable docker
```

<!-- VERIFY: a reboot of the Pi brings the kismet and helper containers back with their sources (not tested); whether Debian's docker.io enables docker.service by default -->

Boards at boot:

- **`kismet` service:** the sources are worked out once, when the container starts. If no board is there yet, the container waits up to 30 s for one, then until no more appear. A board that turns up later is not added by itself. To be safe after a reboot, list the boards in `KISMET_SOURCES` in `.env`: Kismet then keeps retrying a listed source every 5 s until its board appears. <!-- VERIFY: the wait-until-settled start-up of the current entrypoint, and KISMET_SOURCES by /dev/serial/by-id link inside the container, with real boards -->
- **`helper` service:** it runs the C helper, one per source, and starts each one again 5 s after it exits, so a board listed in `KISMET_SOURCES` that comes up late is picked up. As with [the C helper as a service](#the-c-helper-as-a-service), a board that is missing when its helper connects can leave a stale source in Kismet's list until Kismet restarts (see the warning there); plug the boards in before the container starts. With no board at all and no `KISMET_SOURCES`, the container exits and Docker restarts it until a board is there.

Your login, API keys and logs are in named volumes, so they survive restarts and reboots.

## The Python remote helper at logon on Windows

To start the helper when you log on to a Windows PC, have Task Scheduler run a small batch file. This has not been tested, and neither has how the helper behaves when the PC sleeps and wakes. <!-- VERIFY: the whole Windows section: the batch file, the task settings, a logon, and sleep/wake -->

### 1. Write the batch file

Create `start-helper.cmd` in the project folder, for example `C:\Users\you\esp32c5-kismet-wifi-interface\start-helper.cmd`:

```text
@echo off
cd /d C:\Users\you\esp32c5-kismet-wifi-interface
set KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
:again
"C:\Users\you\AppData\Local\Programs\Python\Python313\python.exe" -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5-COM14:name=win-wifi --source esp32c5btle-COM15:name=win-btle
if %errorlevel% equ 1 (
    timeout /t 60 >nul
    goto again
)
```

Change the folder, the key, the server and the sources to yours. The last four lines start the helper again a minute after it exits with status 1, which it does only when every source has stopped by itself. After Ctrl+C it exits with status 0 and the batch file ends; a command-line mistake gives status 2 and also ends it, so a typo does not loop. <!-- VERIFY: the restart loop in start-helper.cmd: exit status 1 restarts after 60 s, Ctrl+C (status 0) ends the file, including after cmd's "Terminate batch job (Y/N)?" question --> Use the full path of `python.exe`, because a task does not always get the same `PATH` as your console. PowerShell prints it:

```powershell
(Get-Command python).Source
```

The file holds the API key, so keep it in your own user folder. A `datasource` key can only feed sources, and you can delete it in Kismet's **Settings → API Keys** if the file leaks.

Run the file once by hand and check that the sources appear in Kismet.

### 2. Create the task

1. Open **Task Scheduler** and choose **Create Task…** (not *Create Basic Task*, which hides the settings below).
2. **General:** name it `ESP32-C5 helper`, and keep **Run only when user is logged on**. The helper then runs in a console window on your desktop, where Ctrl+C stops it.
3. **Triggers → New…:** *Begin the task* **At log on**, for your user.
4. **Actions → New…:** **Start a program**, with the path of `start-helper.cmd`.
5. **Conditions:** untick **Start the task only if the computer is on AC power**, or a laptop on battery will not start it.
6. **Settings:** untick **Stop the task if it runs longer than** (3 days by default).
7. Press **OK**, then right-click the task and choose **Run** to try it.

Do not count on **If the task fails, restart every** to restart the helper. That setting is meant for a task that fails to run, and whether a batch file whose program exited with status 1 counts as failed has not been checked; the loop in the batch file does that job instead. <!-- VERIFY: whether Task Scheduler's "If the task fails, restart every" reacts to start-helper.cmd ending with exit status 1 -->

The helper keeps each source trying on its own: it reconnects every 5 s while Kismet is away, and waits for a board that is unplugged. So the restart in the batch file is only a safety net.

### 3. Stop it

Press **Ctrl+C** or **Ctrl+Break** in the helper's window. It logs `stopping`, releases the COM ports and exits with status 0. cmd may then ask `Terminate batch job (Y/N)?`; with status 0 either answer ends the batch file. Kismet then shows the sources as stopped with `websocket connection closed`, which is expected. Ending the task in Task Scheduler stops it by force; the COM ports are released at once all the same.

## Logs and disk space

A service writes one kismetdb per start, and it grows with every packet: Kismet keeps the packets it marks as duplicates too. For scale, two Wi-Fi boards on the test Pi delivered about 19,000 packets in 4 minutes, and one BTLE board about 20 packets a second, nearly all of them duplicates. How much disk that takes has not been measured. <!-- VERIFY: kismetdb growth per hour for one Wi-Fi and one BTLE board on the Pi -->

To keep the logs smaller, add one of these to `kismet_site.conf`:

```ini
# keep devices, messages and alerts, but no packets
kis_log_packets=false
```

```ini
# keep packets, but not the duplicates (most BLE packets)
kis_log_duplicate_packets=false
```

A pcapng log can be split into files of a set size with `pcapng_log_max_mb=1000`. Kismet's `kismet_logging.conf` also has options that remove old records from a running kismetdb: `kis_log_packet_timeout`, `kis_log_device_timeout`, `kis_log_message_timeout`, `kis_log_alert_timeout` and `kis_log_snapshot_timeout`, each in seconds (86400 for a day), all off by default. Read their comments in that file before you use them. Nothing deletes old log files, so check the free space in `log_prefix` now and then. [Kismet Configuration](Kismet-Configuration#logging) lists the logging options.

<!-- VERIFY: kis_log_packets=false, kis_log_duplicate_packets=false and the kis_log_*_timeout options on a running service (names read from kismet_logging.conf at cfe427074; not run) -->

## See also

- [Install on Raspberry Pi](Install-on-Raspberry-Pi) and [Install on Linux](Install-on-Linux): the native build these services run
- [Install with Docker](Install-with-Docker) and [Docker Reference](Docker-Reference): the services, variables and volumes
- [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi): the Windows side, started by hand
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf` and logging
- [Guide: Updating](Guide-Updating): what to restart after an update
