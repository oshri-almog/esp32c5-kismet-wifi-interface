This page covers the parts of Kismet's configuration that matter when you run it with ESP32-C5 boards: where the files are, how to change settings without editing Kismet's own files, sources, the web login, the web port, remote capture, logging, API keys, and what the Docker image sets. It is for anyone who runs the Kismet server, natively or in Docker.

Everything here was checked against Kismet at commit `cfe427074`, the commit this project builds (see [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)). Kismet's own guide to its config files is on [kismetwireless.net](https://www.kismetwireless.net/docs/readme/configuring/configfiles/).

## Where the files are

Kismet reads two sets of files: the global configuration in its config directory, and a per-user directory, `.kismet`, in the home directory of the user it runs as.

| Install | Config directory | Programs (`kismet`, `kismet_cap_esp32c5`) | Per-user directory |
|---|---|---|---|
| Built with `--prefix=$HOME/kismet-install`, as on the tested Raspberry Pi | `~/kismet-install/etc/` | `~/kismet-install/bin/` | `.kismet/` in the home of the user running Kismet |
| Built with Kismet's default prefix, `/usr/local` | `/usr/local/etc/` | `/usr/local/bin/` | the same |
| The Docker image | `/etc/kismet/` | `/usr/bin/` | `/root/.kismet/`, a volume |

The config directory holds the files `make install` puts there:

| File | What it holds |
|---|---|
| `kismet.conf` | The main file. It includes the others and holds the source, hopping and remote-capture defaults. |
| `kismet_httpd.conf` | The web server: port, and where the login file and API keys are kept |
| `kismet_logging.conf` | Which logs are written, where, and what goes in them |
| `kismet_filter.conf` | Device and packet filters, such as `btle_ignore_random` |
| `kismet_memory.conf`, `kismet_alerts.conf`, `kismet_80211.conf`, `kismet_uav.conf`, `kismet_wardrive.conf` | Other areas. Nothing in them needs changing for these boards. |
| `kismet_site.conf` | **Not installed: you create it.** Your changes go here (next section). |

`make install` never replaces a config file that already exists. It prints `<file> already exists; it will not be automatically replaced.` `make forceconfigs` replaces them all with the stock versions.

The per-user directory holds:

| File | What it holds |
|---|---|
| `kismet_httpd.conf` | The web admin login, in plain text |
| `session.db` | The API keys |
| `kismet_server_id.conf` | The server's UUID, made at the first start |

Kismet creates the directory at its first start, with mode 0700.

> **Note:** "Home" here is the home directory that the system's user database gives for the user running Kismet, **not** `$HOME`. Started with `sudo`, Kismet uses `/root/.kismet`. Under systemd with `User=kismet`, it uses that user's home. `kismet --homedir <dir>` makes it use `<dir>/.kismet` instead. A test that set `HOME=` had its login file ignored for exactly this reason.

Other ways to point Kismet at other files:

| Option | Effect |
|---|---|
| `KISMET_CONF=<dir>` (environment) | Read `<dir>/kismet.conf` as the main file |
| `-f <file>`, `--config-file <file>` | Read `<file>` as the main file |
| `--confdir <dir>` | Look for the included files and `kismet_site.conf` in `<dir>`. It does not move `kismet.conf` itself; combine it with `-f <dir>/kismet.conf`. |
| `--override <flavour or file>` | Read one more file last (next section) |

## Put your changes in kismet_site.conf

Kismet reads its files in this order:

1. `kismet.conf`, top to bottom. Each `include=` line is read where it appears: `kismet_httpd.conf`, `kismet_memory.conf`, `kismet_alerts.conf`, `kismet_80211.conf`, `kismet_logging.conf`, `kismet_filter.conf`, `kismet_uav.conf`. A missing include is fatal.
2. The override files, if they exist: `kismet_package.conf` (from a distribution package), then **`kismet_site.conf`**.
3. The file named with `--override`, if any: a path, or `kismet_<flavour>.conf` from the config directory (`--override wardrive` reads `kismet_wardrive.conf`).

Why `kismet_site.conf` and not the stock files:

- In the stock files, the **first** value of a setting wins. `httpd_port=2502` added at the end of `kismet.conf` is ignored, because `kismet_httpd.conf`, included earlier, already set `httpd_port=2501`.
- In `kismet_site.conf`, a setting replaces whatever the stock files said.
- A reinstall, or `make forceconfigs`, leaves `kismet_site.conf` alone.

At start Kismet logs `Loading config override file '/home/you/kismet-install/etc/kismet_site.conf'` whether the file exists or not. The line after it tells you which:

- `Loading optional sub-config file: /home/you/kismet-install/etc/kismet_site.conf`: the file was found and read.
- `Optional sub-config file not present: /home/you/kismet-install/etc/kismet_site.conf`: there is no such file.

How lines in `kismet_site.conf` combine with the stock files:

| In kismet_site.conf | Effect |
|---|---|
| `key=value` (one or more lines) | Replaces every earlier value of `key`. Several `key=` lines in this file all apply together. |
| only `key+=value` lines | Adds to the earlier values |

So `source=` lines in `kismet_site.conf` replace any in the stock files (there are none), `log_types=kismet,pcapng` replaces the default list, and `log_types+=pcapng` adds to it. Take care with `helper_binary_path`: `helper_binary_path=<dir>` drops Kismet's own `bin` directory, where `kismet_cap_esp32c5` lives. Use `helper_binary_path+=<dir>` to add one.

### Syntax

- One `key=value` per line. A line whose first non-blank character is `#` is a comment.
- There are **no comments at the end of a line**: `log_prefix=/data # logs` makes the value `/data # logs`.
- Keys can be in any case; values keep their case.
- True and false are `true`, `t`, `false` or `f`. Anything else, such as `yes`, `1` or `on`, quietly falls back to the setting's default.
- A key with no value (`key=`) is skipped, with `Illegal config option in '<file>' line <n>: <line>`.
- Paths can use these expansions: `%h` the home directory described above, `%E` the config directory, `%S` the data directory, `%B` Kismet's `bin` directory. Log names also use `%p` (log prefix), `%n` (log title), `%D` (date, `YYYYMMDD`), `%t` (time, `HH-MM-SS`), `%i` (log number) and `%l` (log type). **Dates and times are UTC.**

### A complete example

For a Raspberry Pi with three boards. Change the MACs to your boards' (`ls -l /dev/serial/by-id/` lists them), and `/home/you` to your home directory:

```ini
# ~/kismet-install/etc/kismet_site.conf

# The boards, by their stable names
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=c5-wifi
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=zigbee,name=c5-zigbee
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:05-if00,mode=btle,name=c5-btle

# Logs always go here, wherever Kismet is started; the folder must exist
log_prefix=/home/you/kismet-logs/
# A kismetdb and a pcapng log
log_types=kismet,pcapng
```

This file was checked as a whole with three simulated boards behind links named like these, with Kismet started without `-c` from `/`: all three sources captured, and the kismetdb and pcapng logs went to `log_prefix`. The hardware runs gave their sources with `-c`.

Then start Kismet without `-c`, since any `-c` makes it ignore the `source=` lines:

```bash
mkdir -p ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses
```

## Sources

A source is written `source=<definition>`, one line per source. [Source Definitions](Source-Definitions) has every form and option.

- Kismet defines no sources of its own. With none, it logs `No data sources defined; Kismet will not capture anything until a source is added.` You can still add them from the web UI.
- **Any `-c` on the command line makes Kismet ignore every `source=` line**, and it says so: `Data sources passed on the command line (via -c source), ignoring source= definitions in the Kismet config file.`
- Kismet runs capture helpers only from `helper_binary_path`, which is `%B`, its own `bin` directory. `make install` puts `kismet_cap_esp32c5` there. If the helper is missing from it, a source defined with `type=esp32c5` makes Kismet stop at start with `Uncaught exception "kis_external tried to write with no io handler"`; without `type=`, Kismet says only `Unable to find driver for '<definition>'` ([Troubleshooting](Troubleshooting#kismet-stops-with-kis_external-tried-to-write-with-no-io-handler)).

### Channel hopping defaults

These apply to every source whose definition does not say otherwise. Stock values:

| Setting | Stock value | Meaning |
|---|---|---|
| `channel_hop` | `true` | Hop every source that can, unless its definition has `channel_hop=false` |
| `channel_hop_speed` | `5/sec` | The hop rate: `<n>/sec`, `<n>/min`, or `<n>/dwell` (seconds on each channel). A bare number is refused at start. |
| `split_source_hopping` | `true` | Sources of the same type with the same channel list start from different points of the list |
| `randomized_hopping` | `true` | Shuffle the order of the channel list |
| `retry_on_source_error` | `true` | Re-open a local source 5 s after it fails |

At 5 hops a second, a Wi-Fi board takes about 8.4 s to visit all 42 channels. To slow it down, put `channel_hop_speed=2/sec` in `kismet_site.conf`. [Channel Control](Channel-Control) covers hopping, locking and the per-source `channel_hoprate`, and [Multiple Boards](Multiple-Boards) covers splitting.

## The web server

| Setting | Stock value | Meaning |
|---|---|---|
| `httpd_port` | `2501` | The port for the web UI, the REST API and remote capture over the websocket |
| `httpd_bind_address` | `0.0.0.0`, every interface (not written in the stock file) | The address to listen on. `127.0.0.1` makes the web server reachable from this machine only. |
| `httpd_uri_prefix` | not set | For Kismet behind a reverse proxy under a path, such as `/kismet` |
| `httpd_allow_auth_creation` | `true` | Allow creating API keys |
| `httpd_allow_auth_view` | `true` | Show the keys' tokens in the key list |

To keep Kismet local and on another port:

```ini
httpd_bind_address=127.0.0.1
httpd_port=2502
```

Kismet then logs `HTTP server listening on 127.0.0.1:2502`. A port already in use stops it: `Could not initialize HTTP server on 127.0.0.1:2502, could not bind socket - <error>`.

- Remote helpers connect to this port: with `httpd_port=2502`, use `--connect 192.168.1.50:2502`.
- Behind a reverse proxy with `httpd_uri_prefix=/kismet`, give the helpers `--endpoint /kismet/datasource/remote/remotesource.ws`.
- **Kismet at this commit has no TLS.** Nothing reads the `httpd_ssl` settings that its old `README.SSL` describes. For HTTPS, put a TLS reverse proxy in front of Kismet; the helpers then connect with `--ssl`.
- In Docker, leave `httpd_port` alone and choose the host port instead, with `KISMET_PORT` in compose or `-p` in `docker run`. See [Docker Reference](Docker-Reference).

## The web login

### The first start

Without a login, Kismet logs:

```text
This is the first time Kismet has been run as this user.  You will need to set an administrator username and password before you can use any features of Kismet.  Visit http://localhost:2501/ to configure the initial login, or consult the Kismet documentation at https://www.kismetwireless.net/docs/readme/configuring/webserver/ about how to set a password manually.
```

The address in that message is fixed text; it says `localhost:2501` whatever the real address and port are. The browser then shows **Set Login**, and the login you choose is saved in `.kismet/kismet_httpd.conf` in the home directory of the user Kismet runs as. The dialog names that user.

> **Warning:** Until a login exists, anyone who reaches port 2501 can choose it, and Kismet listens on every network interface by default. Set the login before the first start, as below, or put `httpd_bind_address=127.0.0.1` in `kismet_site.conf` until you have set it.

### Setting it before the first start

As the user who will run Kismet:

```bash
mkdir -m 700 -p ~/.kismet
printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > ~/.kismet/kismet_httpd.conf
chmod 600 ~/.kismet/kismet_httpd.conf
```

Change `admin` and the password. `-m 700` gives the directory the mode Kismet itself would give it, since it also holds the API keys. The file is plain text, in the same format Kismet writes. If one of the two lines is missing, Kismet logs `Found a partial configuration in <file>, resetting login information.` and asks for a login again.

The same login also works for remote capture, whatever characters the password holds: the helpers send it in a request header, where `&`, spaces and `%` get through as they are. The one login that cannot be used there is a user name containing `:` together with an `&` anywhere in the user name or password ([Remote Capture](Remote-Capture#logins-and-the-environment) explains why). An API key with the `datasource` role is the better choice for remote capture anyway (below).

### One login for the whole machine

A login can also go in the global configuration. Put both lines in `kismet_site.conf`:

```ini
httpd_username=admin
httpd_password=choose-a-long-password
```

The per-user file is then ignored, Kismet raises the alert `GLOBALHTTPDUSER`, and the login cannot be changed from the web UI. Both lines are needed: one without the other stops Kismet at start. The password is then in `kismet_site.conf`, so keep that file private.

### Changing it

- In the web UI: **Settings**, then **Login & Password**. It needs the current login.
- Or edit the per-user file and restart Kismet.

The browser keeps the login in its local storage, and asks again (**Login Required**) when it no longer works. A browser login gets a session cookie valid for 24 hours. The cookies do not survive a restart of Kismet unless `httpd_jwt_key` (at least 8 characters) is set; API keys do.

### In Docker

The image's entrypoint always sets a login before Kismet starts: `KISMET_USER` and `KISMET_PASSWORD` if both are given (written at every start), otherwise the one kept in the `/root/.kismet` volume, otherwise a made-up one, printed once:

```text
[esp32c5-kismet] no web login was set, so Kismet's is now: user admin, password <24 hex characters>
```

Find it with `docker compose logs kismet | grep "web login"`. See [Docker Reference](Docker-Reference).

## API keys

An API key lets a program use Kismet without the admin password. This project uses one for remote capture: a key with the **datasource** role can connect a remote source and do nothing else.

| Role | What it can do |
|---|---|
| `admin` | Everything, remote capture included |
| `readonly` | Read-only calls. **Not** remote capture. |
| `datasource` | Only the remote-capture websocket. Any other call gets HTTP 401. |

Kismet's web UI also offers `scanreport`, `ADSB` and custom roles, which this project does not use.

### Creating a key in the web UI

1. Open **Settings**, then **API Keys**.
2. Click **Create API Key**.
3. Enter a name, such as `esp32c5-helper`, and choose the role **datasource**.
4. Copy the token from the table.

These steps follow the web UI's code; they have not been tried in a browser. The tests created their keys with curl, as below.

### Creating a key with curl

Replace `admin:PASSWORD` with your login and `127.0.0.1:2501` with your Kismet server:

```bash
curl -u admin:PASSWORD --data-urlencode 'json={"name": "esp32c5-helper", "role": "datasource", "duration": 0}' http://127.0.0.1:2501/auth/apikey/generate.cmd
```

Kismet answers with the key as plain text: 32 hex characters. This call was run from Git Bash on Windows against Kismet in Docker Desktop, and on the test Pi, and returned the key both times.

- It needs the admin login.
- `name` must be new; a name already in use gives `cannot create duplicate auth`.
- `duration` must be there. It is in seconds, and `0` means "never expires". At this Kismet commit keys never expire, whatever the value.
- Use `--data-urlencode`, not `-d`: in a form body, Kismet turns `+` into a space.

The command works as written in bash and in Git Bash on Windows. Windows PowerShell 5.1 needs two changes:

- `curl` there is another command (Invoke-WebRequest), so call `curl.exe`.
- It removes the double quotes inside a quoted argument before it starts a program, so curl would send `{name: esp32c5-helper, ...}`, which is not JSON. Put a backslash before each inner quote:

```powershell
curl.exe -u admin:PASSWORD --data-urlencode 'json={\"name\": \"esp32c5-helper\", \"role\": \"datasource\", \"duration\": 0}' http://127.0.0.1:2501/auth/apikey/generate.cmd
```

In cmd, put the whole argument in double quotes and escape the inner ones the same way:

```text
curl.exe -u admin:PASSWORD --data-urlencode "json={\"name\": \"esp32c5-helper\", \"role\": \"datasource\", \"duration\": 0}" http://127.0.0.1:2501/auth/apikey/generate.cmd
```

The revoke command below needs the same changes. Both forms, in Windows PowerShell 5.1 and in cmd on Windows 11, created a key and revoked it on a real Kismet, with Windows' own `curl.exe`. Without the backslashes, PowerShell's form gets HTTP 500 and creates no key.

<!-- VERIFY: PowerShell 7 not tried (7.3 and later pass quotes differently, so the backslashes may then arrive as well) -->

List the keys, and revoke one by name:

```bash
curl -s -u admin:PASSWORD http://127.0.0.1:2501/auth/apikey/list.json
curl -s -u admin:PASSWORD --data-urlencode 'json={"name": "esp32c5-helper"}' http://127.0.0.1:2501/auth/apikey/revoke.cmd
```

The list shows each key's name, role, token and expiration (0 for "never"). A revoke answers `revoked`; for a name that has no key it answers HTTP 500 with `ERROR: cannot delete unknown auth record`. Both answers were checked against a Kismet built from this project's commit.

Keys are saved in `session.db` in the per-user directory, so they survive a restart of Kismet. In the Docker image that is the `/root/.kismet` volume; a key survived `docker restart` in the tests.

Give the key to a remote helper with `--apikey`, or in the environment as `KISMET_CAP_APIKEY`, which keeps it out of the process list. The Docker `helper` role takes it as `KISMET_APIKEY`. See [Remote Capture](Remote-Capture).

## Remote capture

Kismet takes remote sources two ways:

| | Websocket (the default) | Legacy TCP |
|---|---|---|
| Port | the web port, `httpd_port` (2501) | `remote_capture_port` (3501) |
| Listens on | `httpd_bind_address`: every interface by default | `remote_capture_listen`: `127.0.0.1` by default |
| Login | required: an API key with the `datasource` role, or the admin login | **none** |
| Helper option | none needed | `--tcp` |
| Path | `/datasource/remote/remotesource.ws` | none |

The stock settings for the legacy port are:

```ini
remote_capture_enabled=true
remote_capture_listen=127.0.0.1
remote_capture_port=3501
```

At start Kismet logs `Launching remote capture server on 127.0.0.1 3501`. These three settings concern the legacy TCP listener only. The websocket is on whenever the web server is: with `remote_capture_enabled=false`, Kismet logs `Remote capture disabled via remote_capture_enabled; no remote capture will be enabled.` and leaves port 3501 closed, but remote sources still connect over the websocket, as a test on the Pi showed. (The comment in Kismet's own config file says the setting disables remote capture completely; it does not.)

To accept legacy TCP connections from other machines:

```ini
remote_capture_listen=0.0.0.0
```

> **Warning:** The legacy TCP port has no authentication at all: anyone who can reach it can feed Kismet data. Kismet's own advice is to keep it on loopback and reach it through an SSH tunnel. Open it only on a network you trust.

Legacy TCP is no faster than the websocket. On the test Pi the C helper's first packet reached Kismet 1.2 to 1.6 s after the helper started over TCP, and 1.2 to 1.4 s over the websocket; the Python remote helper's took 1.4 to 1.8 s over the websocket. What it offers is a connection without a login, for use through an SSH tunnel, for example. See [Remote Capture](Remote-Capture).

Other settings that matter for remote sources:

| Setting | Stock value | Meaning |
|---|---|---|
| `override_remote_timestamp` | `true` | Packets from remote sources get Kismet's arrival time. A source can keep its own with `timestamp=false`; then keep the machines' clocks in step. |
| `remote_capture_allow_http_auth` | `false` | Whether a remote helper may ask Kismet for a web login token. The helpers here do not need it. |
| `server_announce` | `false` | `true` broadcasts the server on UDP port 2501 every 5 s, for helpers started with `--autodetect`. The announcement names the legacy TCP port, so those helpers would need `--tcp` and a `remote_capture_listen` that reaches them. `--autodetect` has not been tried with these boards. |

What Kismet does with a remote source:

- It must know the `esp32c5` source type. A Kismet built without it refuses the source with `Kismet could not find a datasource driver for incoming remote source 'esp32c5' ...`.
- It recognises a source it has seen before by its UUID and logs `Remote source <name> (<uuid>) reconnected`. Within one run of Kismet, such a source keeps every option of its earlier definition that the new definition leaves out (for example `channel_hop=false` or a `name=`); options the new definition gives replace the old ones. To drop an old option, give its opposite (`channel_hop=true`) or restart Kismet.
- When a second connection arrives with the UUID of a source that is running, Kismet closes the running one. That is why, on Linux, the helpers do not offer a board that another capture holds ([Remote Capture](Remote-Capture#when-the-connection-drops)).
- It sends a ping every 5 s, and treats more than 15 s without an answer as an error.
- **It never re-opens a remote source itself.** When the helper goes away, the source stays in error until the helper reconnects.
- **Closing a remote source lasts only until its helper reconnects**, about 5 s later. To stop a remote source, stop its helper.

## Logging

The logging settings live in `kismet_logging.conf`. Stock values:

| Setting | Stock value | Meaning |
|---|---|---|
| `enable_logging` | `true` | `false`, or `-n` / `--no-logging` on the command line, writes no logs at all. Kismet then raises the alert `LOGDISABLED`. |
| `log_prefix` | `./` | The directory for logs. `./` is the directory Kismet was started in. **It must exist**; Kismet does not create it. |
| `log_title` | `Kismet` | The start of each log's name |
| `log_template` | `%p/%n-%D-%t-%i.%l` | The log name, e.g. `Kismet-20260928-14-03-22-1.kismet`; the date and time are UTC, and the number is the first free one from 1 |
| `log_types` | `kismet` | Which logs to write, separated by commas |

The log types:

| Type | File | What it holds |
|---|---|---|
| `kismet` | `.kismet` | The kismetdb, an SQLite database with devices, packets, messages, alerts and source records. One per run. |
| `pcapng` | `.pcapng` | Every packet from every source, each source as its own interface with its own link type. Wireshark opens it directly. |
| `pcapppi` | `.pcapppi` | The legacy PPI pcap format |
| `wiglecsv` | `.wiglecsv` | A WiGLE CSV file |
| `pcapng_ring` | | A ring of pcapng files, for Kismet's ring-buffer feature |

For these boards, a pcapng log holds Wi-Fi as radiotap (link type 127), 802.15.4 as link type 230 (as the helpers hand it to Kismet), and Bluetooth LE as link type 256. Both the kismetdb and the pcapng keep packets Kismet marked as duplicates.

To keep a pcapng next to the kismetdb, in a fixed folder, split into files of at most 1000 MB:

```ini
log_prefix=/home/you/kismet-logs/
log_types+=pcapng
pcapng_log_max_mb=1000
```

`pcapng_log_max_mb=0`, the default, means no limit. Above the limit Kismet logs `Rotating to new pcapng log <path>`.

The command line can set the same things for one run: `-p <dir>` (`log_prefix`), `-T kismet,pcapng` (`log_types`), `-t <title>` (`log_title`), and `-n` for no logs.

> **Warning:** If Kismet cannot create its kismetdb, it stops: `Unable to open KismetDB log at '<path>'; check that the directory exists and that you have write permissions to it.` With the stock `log_prefix=./`, that happens when Kismet starts in a directory it cannot write to. A systemd service starts in `/` unless told otherwise, so set `log_prefix` to a folder that exists and that Kismet's user can write. See [Guide: Running as a Service](Guide-Running-as-a-Service).

<!-- VERIFY: a systemd unit without WorkingDirectory= and with the stock log_prefix fails this way (derived from the code and systemd's documented default) -->

More about the logs:

- The kismetdb is written to disk every 10 s. While it is open, a `-journal` file sits next to it. After a crash or power loss, up to the last 10 s can be missing and the journal stays; `kismetdb_clean -i <file>` tidies it up.
- `kis_log_packets=false` keeps devices, messages and alerts in the kismetdb but no packets. `kis_log_duplicate_packets=false` leaves out the duplicates.
- In the kismetdb's `packets` table, `frequency` is 0 for every 802.15.4 and Bluetooth LE packet, whatever the helper sends: this Kismet fills it in for Wi-Fi, not for those two radios. The device records have the right frequency, for example 2402000 kHz for a BLE advertiser and 2450000 kHz for an 802.15.4 device on channel 20.
- The stock file sets `kis_log_datasources_rate`, but Kismet reads `kis_log_datasource_rate`. The stock value and the code's default are both 30 s, so this does no harm.
- To turn a kismetdb into pcapng files after the fact, see [Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark) and the log tools in [Command-Line Reference](Command-Line-Reference).

## Filters and names

- Kismet's names for the three radios, used in filters, REST calls and the kismetdb, are `IEEE802.11` (Wi-Fi), `802.15.4` (Zigbee and Thread) and `BTLE` (Bluetooth LE).
- `btle_ignore_random=true`, commented out in `kismet_filter.conf`, hides every Bluetooth LE device with a random address from the device list. Their packets are still logged. See [Bluetooth LE Capture](Bluetooth-LE-Capture).
- Kismet drops a packet as a duplicate when it matches one of the last 1024 packets, and no setting turns that off. The `packet_dedup_size` line in `kismet_memory.conf` is not read by this Kismet. This is why Bluetooth LE device counts look low; see [Bluetooth LE Capture](Bluetooth-LE-Capture).

### Logging only your own devices

Kismet can keep devices and packets out of its kismetdb log by MAC, per radio. To log only your own devices, block everything by default and pass yours. In `kismet_site.conf`, with your devices' MACs in place of the examples:

```ini
kis_log_device_filter_default=block
kis_log_device_filter=IEEE802.11,12:34:56:78:9A:BC,pass
kis_log_device_filter=BTLE,D0:12:34:56:78:9A,pass
kis_log_packet_filter_default=block
kis_log_packet_filter=IEEE802.11,any,12:34:56:78:9A:BC,pass
```

- Device filters: `kis_log_device_filter=<radio>,<MAC, MAC/mask or *>,<pass|block>`.
- Packet filters: `kis_log_packet_filter=<radio>,<source|destination|network|other|any>,<MAC>,<pass|block>`.
- The radio names are `IEEE802.11`, `802.15.4` and `BTLE`.
- An 802.15.4 short address is written as Kismet shows it, such as `10:01`.
- They filter what goes into the kismetdb only: not the pcapng log, and not what the web UI shows while Kismet runs. Kismet still tracks the blocked devices.

These lines were checked with simulated boards on all three radios, against a Kismet built from this project's commit.

## The Docker image's configuration

The image has Kismet's stock files in `/etc/kismet/`, and the project's own [docker/kismet_site.conf](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/kismet_site.conf) as `/etc/kismet/kismet_site.conf`. Its settings:

```ini
log_prefix=/data/
mask_datasource_type=linuxwifi
mask_datasource_type=linuxbluetooth
# ... 15 mask_datasource_type lines in all
```

- `log_prefix=/data/` puts the logs in the `/data` volume.
- The `mask_datasource_type` lines keep Kismet from starting its other capture helpers, which the image also has, to list interfaces or to probe a source given without `type=`. Those helpers need NET_ADMIN, which the container does not have, and crash without it, and one that crashed keeps Kismet's list of interfaces, which the web UI's **Data Sources** window asks for, from ever answering. `kismet_cap_esp32c5` needs no such capability and is not masked.
- Its comments explain that the legacy TCP port stays on Kismet's default, loopback only, which inside a container means unreachable from outside.
- Kismet runs as root in the container. Its per-user directory is `/root/.kismet`, a volume (`kismet-home` in compose), which keeps the login and the API keys. Kismet raises the alert `ROOTUSER` about this.
- The entrypoint writes the web login (see [In Docker](#in-docker) above) and passes the sources to Kismet with `-c`, one per board it finds or per definition in `KISMET_SOURCES`. **So whenever it adds a source, Kismet ignores any `source=` lines in a site file.** Give sources with `KISMET_SOURCES` instead.
- To change more, mount your own file over `/etc/kismet/kismet_site.conf`. Start it from a copy of the image's file and keep its lines: `log_prefix=/data/` and all the `mask_datasource_type` lines. Save it with LF line ends: the image cleans carriage returns out of its own copy at build time, not out of a mounted file.

With compose, add the file to the `kismet` service's existing `volumes` list. Keep the two volumes already there: they hold the logs, the web login and the API keys. The list then reads:

```yaml
    volumes:
      - kismet-data:/data
      - kismet-home:/root/.kismet
      - ./kismet_site.conf:/etc/kismet/kismet_site.conf:ro
```

With `docker run`, add `-v "$PWD/kismet_site.conf:/etc/kismet/kismet_site.conf:ro"`.

<!-- VERIFY: mounting your own kismet_site.conf over the image's (not tried), and whether Kismet minds CRLF line ends -->

In the container log, `Loading optional sub-config file: /etc/kismet/kismet_site.conf` shows the file was read. See [Docker Reference](Docker-Reference) for the volumes, ports and variables.

## Checking what Kismet loaded

These lines at start tell you which settings are in force:

| Line | Meaning |
|---|---|
| `Loading config override file '<path>/kismet_site.conf'` | Kismet looks for the site file. Printed whether the file exists or not. |
| `Loading optional sub-config file: <path>/kismet_site.conf` | Your site file was found and read |
| `Optional sub-config file not present: <path>` | That optional file does not exist |
| `HTTP server listening on 0.0.0.0:2501` | The web server's address and port |
| `Launching remote capture server on 127.0.0.1 3501` | The legacy TCP listener's address and port |
| `Setting default channel hop rate to 5/sec` | `channel_hop_speed` |
| `Enabling channel list splitting on sources which share the same list of channels` | `split_source_hopping=true` |
| `Sources will be re-opened if they encounter an error` | `retry_on_source_error=true` |
| `Data sources passed on the command line (via -c source), ignoring source= definitions in the Kismet config file.` | `-c` was given, so `source=` lines are ignored |
| `Opened kismetdb log file '<path>'` | Where the kismetdb is |
| `Opened pcapng log file '<path>'` | Where the pcapng is |

`ERROR: Tried to re-register duplicate alert FLIPPERZERO` appears at every start of this Kismet version and is harmless.

## Settings that do not do what they seem

| Setting | What happens |
|---|---|
| A second value of a setting in the stock files | The first one wins. Use `kismet_site.conf`. |
| `yes`, `no`, `1`, `0` as true or false | Ignored: the default applies |
| `channel=6` in a source definition | Adds 6 to the hop list; the source still hops. Add `channel_hop=false` to stay. |
| `channel_hoprate=` on a source that is not split with another | Ignored: the global `channel_hop_speed` applies |
| `--device-timeout` on the command line | Listed in `--help`, but does nothing. Use `tracker_device_timeout`. |
| `duration` of an API key | Ignored: keys never expire |
| `packet_dedup_size` | Not read |
| `httpd_ssl`, `httpd_ssl_cert`, `httpd_ssl_key` | Not read: no built-in TLS |

## Related pages

- [Source Definitions](Source-Definitions): every form of a source and its options.
- [Channel Control](Channel-Control): hopping, locking and changing channels.
- [Remote Capture](Remote-Capture): helpers on other machines, over the websocket or legacy TCP.
- [Docker Reference](Docker-Reference): the image's roles, variables, volumes and ports.
- [Guide: Running as a Service](Guide-Running-as-a-Service): Kismet under systemd.
- [Command-Line Reference](Command-Line-Reference): every option of every command.
- [Troubleshooting](Troubleshooting): when a setting does not take effect.
