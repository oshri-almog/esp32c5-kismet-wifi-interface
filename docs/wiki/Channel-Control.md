This page covers how an ESP32-C5 source's channel is chosen and changed: Kismet's hopping and its settings, channel lists, splitting a list across several boards, locking a source on one channel, and changing channels while Kismet runs, from the web UI or the REST API. It is for anyone who wants a board somewhere other than where Kismet's defaults put it.

> **Note:** Only capture on networks and devices you own or are authorised to test.

## Who moves the board

Kismet decides which channel a source is on, and the helper carries it out. Each time the channel changes, the helper sends the board `CHANNELS <n>` with one channel. Changing channel does not reboot the board; only changing radio does.

- **A local source** (the board and Kismet on the same machine) runs the C helper, `kismet_cap_esp32c5`. Kismet hands it the hop list and the rate, and Kismet's capture framework inside the helper walks the list on its own timer.
- **A remote source** ([Remote Capture](Remote-Capture)) works the same way over the network. Kismet sends the list and the rate, and the helper hops the board itself. The Python remote helper copies the capture framework's walk: the same order, the same starting points, and the same minimum of 50 ms per channel.

The firmware also has a built-in channel list and a dwell time of its own (Wi-Fi: locked on 6; 802.15.4: 11-26 at `DWELL 250`, 250 ms per channel; BLE: 37). They matter only when you talk to the board directly, as in [Firmware Protocol](Firmware-Protocol#channels). Under Kismet the board is always given a single channel.

## Channels per radio

| Radio | Channels | Count | Starts on |
|---|---|---|---|
| Wi-Fi | 1–14 (2.4 GHz); 36–64, 100–144 and 149–177 in steps of 4 (5 GHz) | 42 | 6 |
| Zigbee/Thread (802.15.4) | 11–26 | 16 | 15 |
| Bluetooth LE | 37, standing for advertising channels 37, 38 and 39, which are scanned together | 1 | 37 |

- **Channels are plain numbers.** When Kismet sets or hops to a Wi-Fi channel name such as `6HT40` or `36HT80`, both helpers take the number it starts with, 6 or 36, and ignore the rest; Kismet then shows the name as the source's channel. A channel that does not start with a number, such as `abc`, tunes nothing, and the helper says `unable to parse channel 'abc'; esp32c5 channels are plain numbers`. Only `channel=` in a source definition has to be digits alone.
- **A single channel the radio does not have** is refused the same way by both helpers: the board stays where it was, the change is answered as a success (`set_channel.cmd` returns HTTP 200), and Kismet's messages show the error `<name> cannot tune to channel <n> in <mode> mode`. Setting a single channel stops hopping first, so a hopping source that is refused stays on the channel it had reached. This was checked on the test Pi with a BTLE board and channel 40, with the C helper, local and remote, and with the Python remote helper: each answered HTTP 200, and the source kept capturing on 37.
- **In a hop list, the C helper** drops a channel it cannot tune after one pass. If none can be tuned, the capture ends after that pass: Kismet shows a local source's error as `IPC connection closed` and re-opens it 5 s later with the channels of its definition, and a remote helper connects again 5 s later.
- **In a hop list, the Python remote helper** drops such channels at once and tells Kismet, for example `Removed 2 channels from the channel list because the source could not tune to them: 15, 38`. A hop list with no channel it can tune fails the change: the connection closes, and the helper reconnects 5 s later.

## Hopping

Out of the box every source hops. Four Kismet settings control it. They apply to every source, whatever its type:

| Setting | Default | What it does |
|---|---|---|
| `channel_hop` | `true` | Hop every source that can change channel. |
| `channel_hop_speed` | `5/sec` | How fast: `<n>/sec` is channels per second, `<n>/min` channels per minute, `<n>/dwell` seconds on each channel. |
| `randomized_hopping` | `true` | Walk the list in a spread-out order instead of in sequence. |
| `split_source_hopping` | `true` | Start sources of the same radio at different points of their lists (see "Several boards on one radio" below). |

At the default rate the board spends 200 ms on each channel. A full pass takes about 8.4 s over the 42 Wi-Fi channels and 3.2 s over the 16 802.15.4 channels. The fastest either helper goes is 20 channels a second: a faster rate is held to 50 ms per channel.

In the test runs, Kismet reported a Wi-Fi source as `hopping=1`, `hop_rate=5`, `hop_shuffle=1` and `hop_shuffle_skip=4` over 42 channels, and the helper sent the board a new channel every 200 ms. A Zigbee source started on 15 and hopped 11–26 at 5 channels a second.

While a source hops, Kismet keeps showing its start channel (6, 15 or 37) as the source's channel; the test runs saw this with both helpers. Each packet and device still records the channel the board was really on.

### Changing the rate

Put the setting in `kismet_site.conf`, the file Kismet reads last ([Kismet Configuration](Kismet-Configuration)). For example, to stay one second on each channel:

```ini
channel_hop_speed=1/sec
```

- A bare number such as `channel_hop_speed=2` is refused, and Kismet does not start: `Could not parse channel_hop_speed= config: Expected [value]/sec or [value]/min or [value]/dwell`.
- The same line added to the end of `kismet.conf` is ignored, because in Kismet's own files the first value of a setting wins. `kismet_site.conf` overrides them.

Kismet also has a per-source rate, `channel_hoprate=` in the source definition, which takes the same formats. At this Kismet version it is only honoured for a source that is split with at least one other source (next section). A source on its own always hops at `channel_hop_speed`: in a test, a lone source with `channel_hoprate=1/sec` still changed channel every 200 ms. To change one source's rate while Kismet runs, use the REST API (below).

### Shuffle

With `randomized_hopping=true` the helper walks the list in jumps of 4, so it goes 1, 5, 9, 13 and on rather than 1, 2, 3. Neighbouring 2.4 GHz channels overlap, so this keeps it from visiting them back to back. Each time the walk runs off the end of the list it starts one place further along, so every channel is visited once in four laps. The jump of 4 is set by the helper. With shuffle off the walk goes through the list in order, but each time it runs off the end it restarts at the next of four starting places (the first, second, third or fourth channel, counted round a list shorter than four), so the later channels come round more often: in a test, `1,6,11` was walked 1, 6, 11, 6, 11, 11, 1, 6, 11, 1, 6, 11 and so on. In the config, shuffle is one setting for all sources (`randomized_hopping`). While Kismet runs, `set_channel.cmd` can turn it on or off for one source (`"shuffle": 0` or `1`; see the REST API section below).

## Channel lists

Kismet's own source options pick the channels a source hops over. They go in the source definition:

| Option | Effect |
|---|---|
| `channels="1,6,11"` | Hop over these channels only. |
| `block_channels="12,13,14"` | Hop over every channel except these. Ignored when `channels=` is given. |
| `add_channels=` | Add channels to the list the helper offers. Nothing to add here: the helper already offers every channel the radio can tune to. |

- **Quote the list.** A value with commas must be in double quotes, or Kismet reads `channels=1` and takes `6` and `11` as options of their own. On a shell, put the whole definition in single quotes:

  ```bash
  kismet -c 'esp32c5-ttyACM0:channels="1,6,11",name=wifi-1-6-11'
  ```

  In `kismet_site.conf` no outer quotes are needed:

  ```ini
  source=esp32c5-ttyACM0:name=wifi-1-6-11,channels="1,6,11"
  ```

  With the Python remote helper on Windows, each shell needs the inner quotes typed differently. [Install on Windows](Install-on-Windows) has a tested table for PowerShell, cmd and Git Bash.
- **Plain lists only.** Kismet splits the value at the commas and does not understand ranges such as `1-13`.

**Staying within your country's rules.** The helpers offer every channel the radio can tune to, including 2.4 GHz channels 12–14 and 5 GHz channels 169–177, which are not allowed everywhere. The board only receives. If you want Kismet to keep to a channel plan anyway, block the channels you may not use, for example:

```ini
source=esp32c5-ttyACM0:name=wifi,block_channels="12,13,14,169,173,177"
```

## Several boards on one radio: splitting

When two or more sources of the same type hop, Kismet spreads them out (`split_source_hopping=true`). All three radios have the source type `esp32c5`, but Kismet only splits sources that offer the same channels. So Wi-Fi boards split among themselves, Zigbee boards among themselves and BTLE boards among themselves.

Splitting does **not** give each board a share of the channels. Every board still hops over its whole list, but each starts at a different point: the list length divided by the number of boards, times the board's place in line. Two Wi-Fi boards over 42 channels start 21 apart. Kismet logs:

```text
Splitting channels for interfaces using 'esp32c5' among 2 interfaces
```

In the test run two Wi-Fi boards got offsets 0 and 21. After the first pass they drifted to only 5 positions apart. That is an upstream quirk of Kismet's hop timer, and the Python remote helper copies it. The two boards were still never on the same channel at the same time. Four Wi-Fi boards (offsets 10, 20, 30 and 0) drifted the same way, to 2 or 3 positions apart within 20 to 40 s, and were never two on one channel at once in 1,986 samples over 20 s.

To give each board its own channels, use `channels=` on each. Kismet compares the channels each source offers, not the `channels=` lists, so the boards are still split, but each one hops only over its own list. For example, 2.4 GHz on one board and 5 GHz on the other:

```ini
source=esp32c5-ttyACM0:name=wifi-24,channels="1,2,3,4,5,6,7,8,9,10,11,12,13,14"
source=esp32c5-ttyACM1:name=wifi-5,channels="36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165,169,173,177"
```

In a test with two fake boards, one on `channels="1,6,11",channel_hoprate=2/sec` and one on `channels="36,40,44"`, Kismet still logged the split, and each board hopped only over its own list, the first at its own rate.

A split source may have its own rate with `channel_hoprate=`, for example `channel_hoprate=2/sec` on the 2.4 GHz board. [Multiple Boards](Multiple-Boards) has more set-ups.

## Locking a source on one channel

Give the source both options:

- `channel=<n>` is the channel to start on;
- `channel_hop=false` stops Kismet from ever sending this source a hop list, so it stays there.

`channel=` on its own does **not** lock a source. Kismet adds the channel to the hop list and keeps hopping. Kismet never tunes to `channel=` itself, which is why the helper does. And without `channel_hop=false`, Kismet's hop list reaches the helper during the 0.8 s it waits after `MODE`, before `START`, so the first channel the board gets is already one from the hop list, not `channel=`.

To start Kismet with a Wi-Fi board locked on channel 36 and a Zigbee board locked on channel 20, run this and change the ports to yours:

```bash
kismet -c 'esp32c5-ttyACM0:channel=36,channel_hop=false' -c 'esp32c5zigbee-ttyACM1:channel=20,channel_hop=false'
```

To keep it, put it in `kismet_site.conf`:

```ini
source=esp32c5-ttyACM0:name=wifi-ch36,channel=36,channel_hop=false
source=esp32c5zigbee-ttyACM1:name=zigbee-ch20,channel=20,channel_hop=false
```

With the Python remote helper, the options go in `--source`. Here the API key comes from `KISMET_CAP_APIKEY` ([Remote Capture](Remote-Capture)):

```powershell
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5zigbee-COM14:channel=20,channel_hop=false
```

- Kismet then shows the source as not hopping, on that channel.
- Both helpers check `channel=` before they touch the port: digits only, at most 177, and a channel the radio has. Otherwise they refuse the definition, for example `esp32c5-ttyACM0: channel=15 is not a channel the board can tune to in wifi mode`. The Python remote helper stops at start-up with that message and exit status 2. For a local source, Kismet shows only `Unable to find driver for '...'` unless the definition also has `type=esp32c5`. Add it to see the reason.
- On a BTLE source, `channel=` accepts 37, 38 or 39, and the source stays on 37.

On the test Pi, `channel=20,channel_hop=false` kept a Zigbee board on channel 20 (200 of 200 test frames) and `channel=36,channel_hop=false` kept a Wi-Fi board on 36 (every frame at 5180 MHz), with the C helper started by Kismet, the C helper over `--connect` and the Python remote helper.

Kismet remembers a remote source's options by its UUID for as long as it runs. A remote helper that reconnects with a plain `esp32c5-ttyACM0`, after the same board and radio ran with `channel_hop=false`, stays locked, with either remote helper. Write `channel_hop=true` in the definition, or restart Kismet.

> **Warning:** A locked source may not stay locked when another source on the same radio hops. At this Kismet version, when a hopping source opens, or a remote one reconnects, the split sends a new hop list to every running source of the same type that offers the same channels. It does not skip a source that has `channel_hop=false`, or one locked from the web UI. So a Wi-Fi board locked on channel 36 starts hopping when a second, hopping Wi-Fi board opens after it; a test with fake boards showed exactly that, for a board locked with `channel_hop=false` and for one locked while Kismet ran. If you lock one board and let another on the same radio hop, set `split_source_hopping=false` in `kismet_site.conf`; with it, the locked board in the same test stayed locked. In exchange, the hopping boards all start at the beginning of their lists instead of being spread out, and walk them in the same order. Two hopping boards with the same list that open together, as at Kismet's start, are then on the same channels at nearly the same time (15 ms apart in the test) and mostly duplicate each other. So give each hopping board its own `channels=` list (see "Several boards on one radio" above).

## Changing channels while Kismet runs: the web UI

1. Open Kismet's web UI at `http://192.168.1.50:2501`, changing the address to your Kismet server's, and log in with the admin login.
2. Open **Data Sources** from the sidebar menu and click the source to expand it. A running source has two rows for channels:
   - **Channel Options**, with **Lock** and **Hop** buttons and, while it hops, the rate;
   - **Channels**, with **All** and one button per channel.

To lock the source on one channel:

1. Click **Lock**. The source locks on the first channel of its list.
2. Click the channel you want under **Channels**.

To hop over some of the channels:

1. Click **Hop**. The source hops over all its channels again.
2. Click channels under **Channels** to take them out of the hop list or put them back. The change goes to Kismet after a short pause.
3. **All** puts every channel back.

<!-- VERIFY: these UI steps and labels, read from Kismet's web UI code at cfe427074 (kismet.ui.datasources.js), not tried in a browser -->

A lock or hop list set this way lasts while the source is open, unless another hopping source of the same radio opens or a remote one reconnects (see the warning above). Kismet's split then sets this source hopping again over its current hop list, at `channel_hop_speed` (or its own `channel_hoprate=`) and with the global shuffle, so a rate or shuffle set live is lost too. When Kismet re-opens a local source after an error, the lock is lost: the source comes back on its start channel (6, 15 or 37) and does not hop, so set the channel again. A remote source that reconnects is hopped again as its definition says. Nothing is saved: after Kismet restarts, every source starts as its definition says. For a lock that lasts, put `channel=` and `channel_hop=false` in the definition.

## Changing channels while Kismet runs: the REST API

The same controls over HTTP. These calls need the admin login, or an API key with the admin role. A `datasource` or `readonly` key is refused with HTTP 401.

Each source is addressed by its UUID. The Data Sources panel shows it in the source's **UUID** row, and `GET /datasource/all_sources.json` lists every source with its `kismet.datasource.uuid`. For a board with a MAC it can also be worked out: `E5C5000`, then `1` for Wi-Fi, `2` for Zigbee or `3` for BTLE, then `-0000-0000-0000-` and the MAC without colons. See [Multiple Boards](Multiple-Boards).

The examples use a Kismet server at 192.168.1.50 and a Wi-Fi source on a board with the example MAC F0:F5:BD:01:02:03. Change the address and the UUID, and change `admin` and `PASSWORD` to your Kismet login's user name and password (on a native Kismet the user name is whatever was chosen at the first login; only the Docker image's made-up login uses `admin`). Run them in Git Bash, WSL or a Linux shell:

```bash
K=http://192.168.1.50:2501/datasource/by-uuid/E5C50001-0000-0000-0000-F0F5BD010203
# lock on channel 48
curl -s -u admin:PASSWORD --data-urlencode 'json={"channel":"48"}' $K/set_channel.cmd
# hop over 1, 6 and 11, two channels a second, without shuffle
curl -s -u admin:PASSWORD --data-urlencode 'json={"channels":["1","6","11"],"rate":2,"shuffle":0}' $K/set_channel.cmd
# keep the list, change the rate to one channel a second
curl -s -u admin:PASSWORD --data-urlencode 'json={"rate":1}' $K/set_channel.cmd
# after a lock: hop again with the list and rate from before
curl -s -u admin:PASSWORD $K/set_hop.cmd
```

| Call | Body | Effect |
|---|---|---|
| `set_channel.cmd` | `{"channel":"48"}` | Lock on channel 48. The channel is a string. |
| `set_channel.cmd` | `{"channels":[...],"rate":2,"shuffle":0}` | Hop over these channels. `channels` is a list of strings. `rate` is channels per second and may be a fraction, such as `0.5`. `shuffle` is `0` or `1`. Leave any of the three out to keep its current value. |
| `set_hop.cmd` | none | Hop again with the list, rate and shuffle the source last hopped with. |

- On success the call returns the source's record as JSON. On failure it returns HTTP 500 with `{}`, and Kismet's messages say `Source '<name>' (<uuid>) failed to set channel <n>` for a lock, or `Source '<name>' (<uuid>) failed to set channel list or hopping` for a hop list or rate. A channel the radio does not have is not a failure: see "Channels per radio" above.
- Use `--data-urlencode` as shown. In a plain form body, a `+` turns into a space.
- On Windows, run these in Git Bash or WSL. They do not work as written in Windows PowerShell 5.1: `K=...` is bash syntax, `curl` there is another command (`Invoke-WebRequest`), and PowerShell strips the double quotes inside the JSON, so Kismet answers HTTP 500 with `ERROR: channel control API requires either 'channel' or 'channels' and 'rate'`. `curl.exe` with a backslash before each inner quote gets them through, as [Kismet Configuration](Kismet-Configuration#creating-a-key-with-curl) shows for the API key call. In PowerShell 5.1, and in cmd with double quotes around the argument:

  ```powershell
  curl.exe -s -u admin:PASSWORD --data-urlencode 'json={\"channel\":\"48\"}' http://192.168.1.50:2501/datasource/by-uuid/E5C50001-0000-0000-0000-F0F5BD010203/set_channel.cmd
  ```

  ```text
  curl.exe -s -u admin:PASSWORD --data-urlencode "json={\"channel\":\"48\"}" http://192.168.1.50:2501/datasource/by-uuid/E5C50001-0000-0000-0000-F0F5BD010203/set_channel.cmd
  ```

  Run this way from Windows against a real Kismet, the lock, a hop list with a rate and shuffle, a new rate and `set_hop.cmd` all took effect, in both shells.
- To close, reopen or pause a source over the same API, for example to move a board to another radio on a headless machine, see [Source Definitions](Source-Definitions#closing-reopening-and-pausing-a-source).

What the tests saw: with the Python remote helper feeding Kismet in Docker Desktop, `{"channel":"48"}` put all 287 packets of the next 20 s on 5240 MHz, and `set_hop.cmd` spread packets over both bands again within 20 s. On the Raspberry Pi, `{"channel":"20"}` on a Zigbee source let it receive 200 of 200 test frames.

## Bluetooth LE: no channel to choose

The board's Bluetooth controller scans advertising channels 37, 38 and 39 together and cannot be limited to one of them, so a BTLE source has one channel, `37`.

- `channel=` accepts 37, 38 or 39, and the source stays on 37.
- **Lock**, **Hop** and `set_channel.cmd` are accepted and change nothing. Both helpers answer a request for 38 or 39 with 37, so Kismet goes on showing 37. Any other channel is refused as on the other radios, with `<name> cannot tune to channel 40 in btle mode`, say.
- Every BTLE packet is labelled channel 37. [Bluetooth LE Capture](Bluetooth-LE-Capture) explains why.

## See also

- [Wi-Fi Capture](Wi-Fi-Capture), [Zigbee and Thread Capture](Zigbee-and-Thread-Capture), [Bluetooth LE Capture](Bluetooth-LE-Capture): what each radio captures
- [Multiple Boards](Multiple-Boards): naming boards and sharing out channels
- [Source Definitions](Source-Definitions): every option in a definition
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf`
- [Dual-band Wi-Fi survey](Guide-Dual-Band-Wi-Fi-Survey) and [Zigbee and Thread networks](Guide-Zigbee-and-Thread-Networks): worked examples
