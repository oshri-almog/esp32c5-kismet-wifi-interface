/*
    This file is part of Kismet

    Kismet is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Kismet is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Kismet; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

/* kismet_cap_esp32c5: ESP32-C5 sniffer boards over their native USB port.
 *
 * The C helper of the esp32c5 source type (datasource_esp32c5.h): Kismet starts it
 * for every local esp32c5 source, and run by hand with --connect it sends a board to
 * a Kismet server elsewhere (remote capture).  What users read about it -- every
 * form of a source definition, the options and the messages -- is on the wiki,
 * https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki: the pages
 * Source-Definitions, Command-Line-Reference, How-It-Works, Firmware-Protocol and
 * Troubleshooting.
 *
 * The board runs the esp32c5 sniffer firmware and listens with one of its three
 * radios: Wi-Fi (2.4 and 5 GHz), IEEE 802.15.4 (Zigbee, Thread) or Bluetooth LE
 * advertising.  It speaks plain text lines over USB-Serial-JTAG (all of them on the
 * wiki's Firmware-Protocol page):
 *
 *   MODE WIFI|802154|BLE       which radio; another one than now reboots the board
 *   CHANNELS <n>               tune to channel n
 *   START <unix us> <nonce>    answer "\n<<START>> <nonce>\n", a PCAP global
 *                              header, then one PCAP record per frame
 *
 * Source definitions:
 *
 *   esp32c5-ttyACM0                            the board on /dev/ttyACM0, Wi-Fi
 *   esp32c5zigbee-ttyACM0                      the same board, 802.15.4
 *   esp32c5btle-ttyACM0                        the same board, BTLE
 *   esp32c5-ttyACM0:mode=zigbee                802.15.4 too: mode= wins over the name
 *   esp32c5:device=/dev/ttyACM1,mode=btle      any name, explicit device
 *   esp32c5                                    the only board plugged in
 *
 * The name starts with "esp32c5", in lower case.  The options this helper reads are
 * device= (the port, as given, which wins over the name; a /dev/serial/by-id link
 * works), mode=, channel=, name= (the source's name, in these messages as in Kismet)
 * and uuid= (instead of the one made from the board's MAC, see make_uuid).  Kismet
 * reads its own, such as type=, channels= and channel_hop=.
 *
 * mode is wifi, zigbee (or 802154, 802.15.4, thread) or btle (or ble, bluetooth), in
 * any case.  Without mode= the name says it: what comes between "esp32c5" and the
 * first '-' is read the same way, and anything else (nothing, as in esp32c5-ttyACM0)
 * is Wi-Fi.  After the '-' comes the port, as its name under /dev, when it is a name
 * serial ports have: tty* (ttyACM0), cu.* (cu.usbmodem1101 on macOS), cua* (cuaU0 on
 * FreeBSD and OpenBSD), dty* (dtyU0 on NetBSD) or pts/N, and has no "..".  Any other
 * name, such as esp32c5-kitchen, is only a name: it finds its board by itself or
 * takes device=, and whatever /dev holds by that name is left alone.
 *
 * --list offers every board once per radio under the three names above: Kismet
 * keeps only the name of a listed interface, so the radio has to be part of it.
 * (The capture framework prints the list on stderr and exits with 2.)  They are
 * alternatives, not sources to run together -- a board captures with one radio at
 * a time.  The helper holds the port exclusively while it runs: a lock (flock) on
 * its device node, and the tty itself in exclusive mode (TIOCEXCL; not on a
 * pseudo-terminal, see serial_open), which also holds between a helper in a
 * container, which has a /dev node of its own for the board, and one on the host
 * or in another container.  The Python remote helper takes the same two, so the
 * two helpers keep out of each other's way.  A second source on a board in use
 * therefore fails with "already in use" instead of the two fighting over it, and
 * --list leaves a board whose port is locked out altogether, all three names,
 * rather than offer sources that can only fail.  A program with CAP_SYS_ADMIN, such
 * as esptool run with sudo, is not kept out by the exclusive mode (see serial_open).
 *
 * Kismet finds the helper for a definition without type= by asking every helper
 * whether it is theirs; it keeps their reasons to itself and gives up for good when
 * none says yes, with only "Unable to find driver".  So a local definition named
 * the way this helper names things -- nothing or a radio word between "esp32c5" and
 * the first '-', as in esp32c5, esp32c5zigbee, esp32c5-kitchen, esp32c5btle-<name>
 * -- is claimed even while the board it means cannot be told (none plugged in,
 * several, or no sysfs to look in), and the open says why; Kismet retries the open
 * every 5 seconds, so a board plugged in later is picked up.  One that names its
 * port (esp32c5-ttyACM0, device=) is claimed whether or not the port is there, and
 * fails its open the same way.  One that is wrong in itself, a mode= or channel=
 * the radio does not have, is not claimed, as no retry would help it, nor is a name
 * that is not this helper's (esp32c5foo) while its board cannot be found; with
 * type=esp32c5 Kismet asks no one and shows the reason.
 *
 * channel=<n> is the channel to start on, and with channel_hop=false the one to
 * stay on; it has to be one the radio can tune to, in plain digits (parse_channel;
 * the channels Kismet hops through or sets later are read more loosely, see
 * chantranslate_callback).  BTLE scans the three advertising channels together:
 * any of 37, 38 and 39 is taken, in channel= and when Kismet sets a channel, and
 * reported back to Kismet as 37, the channel the board labels every packet with;
 * any other channel is refused.  A channel set to one the radio does not have is
 * refused the way Kismet's own helpers refuse one: the capture goes on where it
 * was, and Kismet logs why (refuse_channel).
 *
 * Kismet hops; the board is told one channel at a time.  Frames go to Kismet in
 * link types it decodes: Wi-Fi as radiotap, unchanged.  802.15.4 arrives in a TAP
 * header whose TLVs Kismet does not walk (it assumes a fixed 28 byte header), so
 * the helper takes the channel and signal out of it and sends the bare MAC frame
 * as 802.15.4 without FCS.  BTLE goes as it arrives, with the radio pseudo-header,
 * except from boards on older firmware, whose CRC the helper fills in (see
 * send_btle).  Every packet has a signal block with its frequency in kHz: Wi-Fi's
 * from the radiotap header's Channel field (none without one), 802.15.4's from the
 * TAP header's channel (which also gives the block the channel and the signal),
 * BTLE's 2402 MHz, channel 37 (see emit_record).
 *
 * The board reboots whenever it is asked for a radio other than the one it is
 * running.  Its USB port usually stays up through that, but it can also go away,
 * and USB hiccups happen.  The helper rides all of that out: it reopens the port
 * and asks again.  A board is known by its MAC, which it reports as its USB serial
 * number: a reopened port is checked to still hold the same board, since two boards
 * that reboot together can come back with their tty names swapped, and a board that
 * moved to another name is found again by its MAC.  The helper says "<name>
 * capturing (<radio>)" once the board answers with the PCAP header of the radio
 * asked for; firmware without that radio answers in another link type, which is
 * lost sync, said once.  Only a board that has not been capturing for
 * RECOVER_TIMEOUT_S -- away, silent, or on the wrong radio -- is reported, as a
 * message Kismet logs, and the helper ends: Kismet opens a local source again 5
 * seconds later, and the capture framework connects a remote helper again 5 seconds
 * later (unless --disable-retry).
 *
 * Boards are recognised by the USB ID 303a:1001, which every Espressif chip with a
 * native USB-Serial-JTAG port shares (ESP32-C3, C5, C6, H2, S3, P4 ...).  So an
 * ESP32-C5 sniffer cannot be told from any other ESP32 on native USB: --list and a
 * bare "esp32c5" count them all, and with other ones plugged in the port has to be
 * named.  Finding boards (a definition that names no port, --list) and finding a
 * moved board by its MAC read Linux sysfs (/sys/class/tty) and only work on Linux;
 * elsewhere (macOS, the BSDs) name the port: device=/dev/cu.usbmodem1101,
 * esp32c5-cuaU0.
 *
 * Remote capture over the websocket (--connect, --host or --autodetect, without
 * --tcp) needs a Kismet login, and one given with --user and --password or --apikey
 * can be read by every user in the process list.  So what the command line leaves
 * out of it is taken from the environment (login_from_env, in a helper built with
 * libwebsockets): KISMET_CAP_APIKEY, or KISMET_CAP_USER and KISMET_CAP_PASSWORD, when
 * it has none of those options; KISMET_CAP_PASSWORD when it has --user alone,
 * KISMET_CAP_USER when it has --password alone.  Legacy TCP (--tcp) has no login and
 * reads none of them.  The capture framework, as add-to-kismet.sh fixes it, sends the
 * login in the websocket request's headers, not in its URI, which a reverse proxy
 * would log: a user and password as Basic authorization and an API key as Kismet's
 * session cookie, which Kismet takes as they are.  Only a user name with ':', which
 * Basic cannot carry, goes in the URI's query, where Kismet's server cuts the login at
 * every '&' after decoding it: such a login with an '&' in it cannot log in, and the
 * helper warns about one (warn_login_cannot_pass).  A websocket answered with a
 * redirect is not followed, since the login would go along to wherever it points: the
 * connection attempt ends there, with a FATAL line that says so.
 *
 * A remote helper checks its definition before it connects: when its board cannot
 * be found, or the definition is wrong in itself, or (on Linux) another process
 * holds its port, it stops there with the capture framework's "Could not probe local
 * source ..." and the reason, and unless --disable-retry the framework tries again
 * every 5 seconds.  A port in use is not offered to Kismet at all: the same board
 * and radio have the same uuid, and Kismet closes a running source when another
 * connection comes in under its uuid, so the second capture would take the source
 * over from the first, a local source of Kismet's own included.
 *
 * With retry, the framework makes each connection in a child process, and starts
 * another 5 seconds after that one ends.  The child ends with its parent
 * (PR_SET_PDEATHSIG, Linux), so a remote helper that is stopped -- by kill, systemd
 * or a closed terminal -- does not leave its board held by an orphan; and a remote
 * helper takes its port out of exclusive mode when a signal ends it (end_on_signal).
 * A signal it was started with ignored stays ignored: under nohup a closed terminal
 * does not stop it.
 *
 * Kismet PINGs every source every 5 seconds, and the framework ends a TCP connection
 * that hears none for 15 seconds, but not a websocket; Kismet can stop talking to a
 * websocket source without closing it, when another connection takes its uuid, so
 * the capture thread watches for that itself (ws_ping_lost): after PING_TIMEOUT_S,
 * 15 seconds, with no PING it ends the capture, and with it the connection, and
 * with retry the framework connects again 5 seconds later.  The framework's
 * libwebsockets logs only its warnings and errors.
 *
 * The helper needs no privilege, only the serial port: run as root, as a user, or
 * installed setuid root, it drops every capability before it does anything else
 * (drop_capabilities), which is also why a container needs no NET_ADMIN for it.
 * Installed setuid root, it used to keep them all; it now opens what root owns and
 * what the user who runs it may open, and nothing else.
 *
 * It adds no command-line option of its own: --help prints the capture framework's
 * usage (the remote capture options), which does not name the KISMET_CAP_*
 * variables above; the wiki's Command-Line-Reference page does.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <linux/major.h>
#include <sys/fsuid.h>
#include <sys/prctl.h>
#include <sys/sysmacros.h>
#endif

#include "../capture_framework.h"
#include "../config.h"

#ifdef HAVE_CAPABILITY
#include <sys/capability.h>
#include <sys/prctl.h>
#endif

#define ESP_USB_VID "303a"
#define ESP_USB_PID "1001"

#define MODE_WIFI 1
#define MODE_154 2
#define MODE_BLE 3

#define LINKTYPE_IEEE802_11_RADIOTAP 127
#define LINKTYPE_IEEE802_15_4_NOFCS 230
#define LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR 256
#define LINKTYPE_IEEE802_15_4_TAP 283

#define PCAP_MAGIC 0xA1B2C3D4u
#define PCAP_GLOBAL_HDR_LEN 24
#define PCAP_REC_HDR_LEN 16
#define MAX_RECORD_LEN 16384

/* LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR: a 10 byte pseudo-header (flags at offset 8),
 * the 4 byte access address, the PDU (2 byte header and up to 255 bytes), the CRC */
#define BTLE_PHDR_LEN 10
#define BTLE_AA_LEN 4
#define BTLE_CRC_LEN 3
#define BTLE_MIN_RECORD (BTLE_PHDR_LEN + BTLE_AA_LEN + 2 + BTLE_CRC_LEN)
#define BTLE_MAX_RECORD (BTLE_PHDR_LEN + BTLE_AA_LEN + 2 + 255 + BTLE_CRC_LEN)
#define BTLE_FLAG_CRC_CHECKED 0x0400
#define BTLE_FLAG_CRC_VALID 0x0800

/* The channel every BTLE packet is labelled with, and its frequency: the board scans
 * 37, 38 and 39 together */
#define BTLE_CHANNEL_STR "37"
#define BTLE_FREQ_KHZ 2402000ULL

#define START_MARKER "<<START>>"
#define START_MARKER_LEN 9
#define NONCE_LEN 8

/* How often the handshake is repeated while the board has not answered, how long a
 * port that says nothing at all is trusted before it is reopened, and how long the
 * board may be away before Kismet is told. */
#define START_RETRY_S 2.0
#define STALL_TIMEOUT_S 6.0
#define RECOVER_TIMEOUT_S 15.0

/* How long a websocket connection may go without a PING from Kismet, which sends one
 * every 5 seconds: the framework's own limit for TCP and local connections */
#define PING_TIMEOUT_S 15

/* From MODE to START.  A board asked for another radio reboots, and for about half
 * a second hears nothing: a START sent then is lost.  Its port usually stays open
 * through the reboot, so nothing else would tell the helper to wait. */
#define MODE_SETTLE_S 0.8

#define RX_BUF_SIZE (4 * MAX_RECORD_LEN)

/* serial_open: another process holds the port (its flock, or the tty in exclusive
 * mode) */
#define PORT_BUSY -2

/* parse_definition: ours and well-formed, but which port it means cannot be told
 * now (no board plugged in, or several, which can change; or no sysfs to look in) */
#define NO_BOARD_NOW -2

/* Where sysfs and the device nodes are.  Only the tests point them elsewhere, at a
 * made-up tree of boards. */
static const char *sysfs_root = "/sys";
static const char *dev_root = "/dev";

typedef struct {
    kis_capture_handler_t *caph;

    char *name;
    char *interface;
    char *device;
    char mac[13];

    int mode;
    uint32_t dlt;

    /* The port, and the lock that serialises writes to it: the capture thread
     * sends the handshake, Kismet's hop thread sends channels. */
    pthread_mutex_t lock;
    int fd;
    unsigned int channel;

    /* stream state, capture thread only */
    char nonce[NONCE_LEN + 1];
    bool synced;
    bool need_global_hdr;
    /* the last PCAP global header from this port had our link type, so the board
     * is on our radio and a new handshake can skip MODE */
    bool on_radio;
    uint8_t buf[RX_BUF_SIZE];
    size_t buf_len;
    /* bytes at the start of buf that are the last record passed on, kept for the
     * restart check in frame_records */
    size_t kept;
    /* unsynced_since: since when the board has not been capturing (see capturing) */
    double last_start, last_byte, unsynced_since;
    /* when MODE went out, while START is still to follow; 0 otherwise */
    double mode_sent;
    /* the framework's time of the last PING from Kismet, and when this thread saw it
     * change (see ws_ping_lost) */
    time_t ping_seen;
    double ping_seen_at;
    /* a packet could not be sent to Kismet: the capture thread ends (see send_packet) */
    bool send_failed;

    unsigned long sync_losses;
    unsigned long dropped_154;
    unsigned long dropped_btle;
    bool btle_fixup_said;
} local_esp32c5_t;

typedef struct {
    unsigned int channel;
} local_channel_t;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------------------------
 * Channels
 * ---------------------------------------------------------------------------- */

static bool channel_ok(int mode, unsigned int ch) {
    if (mode == MODE_BLE)
        return ch == 37;
    if (mode == MODE_154)
        return ch >= 11 && ch <= 26;
    return (ch >= 1 && ch <= 14) ||
        (ch >= 36 && ch <= 64 && (ch - 36) % 4 == 0) ||
        (ch >= 100 && ch <= 144 && (ch - 100) % 4 == 0) ||
        (ch >= 149 && ch <= 177 && (ch - 149) % 4 == 0);
}

static unsigned int initial_channel(int mode) {
    return mode == MODE_BLE ? 37 : mode == MODE_154 ? 15 : 6;
}

/* Every channel the radio can tune to, as the strings Kismet hops through */
static void fill_channels(cf_params_interface_t *iface, int mode) {
    size_t n = 0;

    iface->channels = (char **) malloc(sizeof(char *) * 64);
    for (unsigned int ch = 1; ch <= 177; ch++) {
        if (channel_ok(mode, ch)) {
            char chstr[8];
            snprintf(chstr, sizeof(chstr), "%u", ch);
            iface->channels[n++] = strdup(chstr);
        }
    }
    iface->channels_len = n;
}

/* ------------------------------------------------------------------------------
 * Definitions: mode, device, identity
 * ---------------------------------------------------------------------------- */

/* A radio by any of its names; -1 for none */
static int mode_from_word(const char *word, int len) {
    static const struct {
        const char *word;
        int mode;
    } words[] = {
        { "wifi", MODE_WIFI },
        { "zigbee", MODE_154 }, { "802154", MODE_154 }, { "802.15.4", MODE_154 },
        { "thread", MODE_154 },
        { "btle", MODE_BLE }, { "ble", MODE_BLE }, { "bluetooth", MODE_BLE },
    };

    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
        if ((size_t) len == strlen(words[i].word) && strncasecmp(word, words[i].word, len) == 0)
            return words[i].mode;
    }
    return -1;
}

/* esp32c5, esp32c5-kitchen, esp32c5zigbee, esp32c5btle-ttyACM0: the names this
 * helper gives and documents, where what comes between "esp32c5" and the first '-'
 * is nothing or a radio -- as opposed to anything else that starts with esp32c5 */
static bool our_name(const char *interface) {
    size_t len = strcspn(interface + 7, "-");
    return len == 0 || mode_from_word(interface + 7, len) > 0;
}

/* mode= when it is there, otherwise the name: esp32c5zigbee-ttyACM0 is 802.15.4,
 * esp32c5-ttyACM0 and esp32c5-kitchen are Wi-Fi.  -1 for a mode= that names no
 * radio. */
static int parse_mode(char *definition, const char *interface) {
    char *placeholder;
    int len, mode;

    if ((len = cf_find_flag(&placeholder, "mode", definition)) > 0)
        return mode_from_word(placeholder, len);

    /* the interface starts with "esp32c5"; the word runs to the first '-' */
    len = strcspn(interface + 7, "-");
    if (len > 0 && (mode = mode_from_word(interface + 7, len)) > 0)
        return mode;
    return MODE_WIFI;
}

static const char *mode_name(int mode) {
    return mode == MODE_BLE ? "btle" : mode == MODE_154 ? "zigbee" : "wifi";
}

static const char *mode_command(int mode) {
    return mode == MODE_BLE ? "BLE" : mode == MODE_154 ? "802154" : "WIFI";
}

static uint32_t mode_dlt(int mode) {
    return mode == MODE_BLE ? LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR :
        mode == MODE_154 ? LINKTYPE_IEEE802_15_4_NOFCS : LINKTYPE_IEEE802_11_RADIOTAP;
}

/* The link type the board itself sends in each mode */
static uint32_t mode_board_linktype(int mode) {
    return mode == MODE_BLE ? LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR :
        mode == MODE_154 ? LINKTYPE_IEEE802_15_4_TAP : LINKTYPE_IEEE802_11_RADIOTAP;
}

/* channel= is where to start, and with channel_hop=false where to stay: Kismet only
 * adds it to the channel list and never tunes to it itself.  BTLE scans the three
 * advertising channels together, so any of them is 37.  False, with the reason in
 * msg, for a channel the radio does not have. */
static bool parse_channel(char *definition, const char *interface, int mode,
        unsigned int *channel, char *msg) {
    char *placeholder, *s, *end;
    unsigned long ch;
    bool bad;
    int len;

    *channel = initial_channel(mode);
    if ((len = cf_find_flag(&placeholder, "channel", definition)) <= 0)
        return true;

    s = strndup(placeholder, len);
    ch = strtoul(s, &end, 10);
    bad = !isdigit((unsigned char) s[0]) || *end != '\0' || ch > 177;
    free(s);
    if (!bad)
        bad = mode == MODE_BLE ? ch < 37 || ch > 39 : !channel_ok(mode, ch);
    if (bad) {
        snprintf(msg, STATUS_MAX, "%s: channel=%.*s is not a channel the board can "
                "tune to in %s mode", interface, len, placeholder, mode_name(mode));
        return false;
    }
    if (mode != MODE_BLE)
        *channel = ch;
    return true;
}

/* Reads a short sysfs attribute into out, without the trailing newline */
static bool read_attr(const char *dir, const char *attr, char *out, size_t out_sz) {
    char path[PATH_MAX];
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s", dir, attr);
    if ((f = fopen(path, "r")) == NULL)
        return false;
    if (fgets(out, out_sz, f) == NULL) {
        fclose(f);
        return false;
    }
    fclose(f);
    out[strcspn(out, "\r\n")] = '\0';
    return true;
}

/* Is /dev/<tty> an Espressif chip on its native USB-Serial-JTAG port -- any of
 * them, the USB ID does not say which chip?  If so, and it reports its MAC as its
 * USB serial number, as they do, mac gets the 12 hex digits in upper case. */
static bool tty_is_board(const char *tty, char *mac) {
    char path[PATH_MAX], real[PATH_MAX], usbdev[PATH_MAX + 4];
    char vid[16], pid[16], serial[64];

    /* /sys/class/tty/ttyACM0/device is the USB interface; its parent is the
     * USB device, which has the IDs and the serial number */
    snprintf(path, sizeof(path), "%s/class/tty/%s/device", sysfs_root, tty);
    if (realpath(path, real) == NULL)
        return false;
    snprintf(usbdev, sizeof(usbdev), "%s/..", real);

    if (!read_attr(usbdev, "idVendor", vid, sizeof(vid)) ||
            !read_attr(usbdev, "idProduct", pid, sizeof(pid)))
        return false;
    if (strcasecmp(vid, ESP_USB_VID) != 0 || strcasecmp(pid, ESP_USB_PID) != 0)
        return false;

    if (mac != NULL) {
        mac[0] = '\0';
        if (read_attr(usbdev, "serial", serial, sizeof(serial))) {
            size_t n = 0;
            for (const char *p = serial; *p && n < 12; p++) {
                if (isxdigit((unsigned char) *p))
                    mac[n++] = toupper((unsigned char) *p);
                else if (*p != ':' && *p != '-')
                    break;
            }
            mac[n == 12 ? 12 : 0] = '\0';
        }
    }
    return true;
}

/* ttyACM2 before ttyACM10 */
static int tty_cmp(const void *a, const void *b) {
    const char *x = *(char * const *) a, *y = *(char * const *) b;
    size_t px = strcspn(x, "0123456789"), py = strcspn(y, "0123456789");
    int r;

    if (px != py || (r = strncmp(x, y, px)) != 0)
        return strcmp(x, y);
    return atoi(x + px) - atoi(y + py);
}

/* The tty names of every board plugged in -- the ttyACM and ttyUSB devices with the
 * USB ID, tty_is_board -- sorted.  Returns the count, or -1 on a system without
 * /sys/class/tty (anything but Linux), where *ttys is NULL. */
static int find_boards(char ***ttys) {
    char path[PATH_MAX];
    DIR *d;
    struct dirent *e;
    int n = 0, cap = 8;

    *ttys = NULL;
    snprintf(path, sizeof(path), "%s/class/tty", sysfs_root);
    if ((d = opendir(path)) == NULL)
        return -1;
    *ttys = (char **) malloc(sizeof(char *) * cap);
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "ttyACM", 6) != 0 && strncmp(e->d_name, "ttyUSB", 6) != 0)
            continue;
        if (!tty_is_board(e->d_name, NULL))
            continue;
        if (n == cap) {
            cap *= 2;
            *ttys = (char **) realloc(*ttys, sizeof(char *) * cap);
        }
        (*ttys)[n++] = strdup(e->d_name);
    }
    closedir(d);
    qsort(*ttys, n, sizeof(char *), tty_cmp);
    return n;
}

/* Is the part of a source name after the '-' a port?  Only when it is a name serial
 * ports have under /dev: tty* (Linux ttyACM and ttyUSB, macOS tty.*, BSD ttyU), cu.*
 * (macOS), cua* (FreeBSD and OpenBSD cuaU), dty* (NetBSD dtyU) and pts/N (a
 * pseudo-terminal, as the tests use).  Anything else is a name for the source, not
 * a port: whatever /dev holds by that name -- watchdog, which reboots the machine
 * once opened and not properly closed, or serial1, the Raspberry Pi's Bluetooth
 * UART -- is never opened for it.  The name counts as written, not where a link
 * leads, and not whether it exists, so that a board that is rebooting right now is
 * waited for rather than swapped for another. */
static bool serial_name(const char *port) {
    static const char *prefixes[] = { "tty", "cu.", "cua", "dty", "pts/" };

    /* nor one that climbs out of /dev */
    if (strstr(port, "..") != NULL)
        return false;
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        if (strncmp(port, prefixes[i], strlen(prefixes[i])) == 0)
            return true;
    }
    return false;
}

/* Which serial device a definition means: device= wins, then the interface name
 * (esp32c5-ttyACM0 and esp32c5zigbee-ttyACM0 are /dev/ttyACM0; see serial_name),
 * then the only board plugged in.  Returns an allocated path, or NULL with the
 * reason in msg. */
static char *resolve_device(char *definition, const char *interface, char *msg) {
    const char *dash = strchr(interface, '-');
    char *placeholder;
    char path[PATH_MAX];
    int len;

    if ((len = cf_find_flag(&placeholder, "device", definition)) > 0)
        return strndup(placeholder, len);

    if (dash != NULL && serial_name(dash + 1)) {
        snprintf(path, sizeof(path), "%s/%s", dev_root, dash + 1);
        return strdup(path);
    }

    char **ttys;
    int n = find_boards(&ttys);
    char *ret = NULL;

    if (n < 0) {
        snprintf(msg, STATUS_MAX, "finding a board by itself needs Linux sysfs "
                "(%s/class/tty), which this system does not have; name the port "
                "with device=/dev/... or a source name like esp32c5-cu.usbmodem1101 "
                "or esp32c5-cuaU0", sysfs_root);
    } else if (n == 1) {
        snprintf(path, sizeof(path), "%s/%s", dev_root, ttys[0]);
        ret = strdup(path);
    } else if (n == 0) {
        snprintf(msg, STATUS_MAX, "no Espressif USB-Serial-JTAG device (USB ID 303a:1001) "
                "found; plug the board in, or give device= in the source definition");
    } else {
        snprintf(msg, STATUS_MAX, "%d Espressif USB-Serial-JTAG devices (USB ID 303a:1001) "
                "found, and every ESP32 on native USB has that ID; say which one with "
                "device= or a source name like esp32c5-%s", n, ttys[0]);
    }
    for (int i = 0; i < n; i++)
        free(ttys[i]);
    free(ttys);
    return ret;
}

/* The board behind a device number, from sysfs, where /sys/dev/char/<major>:<minor>
 * links to its tty: 1, with its MAC in mac, when it is one; 0 when it is not; -1
 * when there is no sysfs to ask.  By number rather than by name, so a /dev/serial/
 * by-id link, the tty's own name and any other name for it all give the same
 * answer, and for an open fd the answer cannot change while it is open. */
static int rdev_board(dev_t rdev, char *mac) {
    char path[PATH_MAX], real[PATH_MAX];
    const char *tty;

    mac[0] = '\0';
    snprintf(path, sizeof(path), "%s/dev/char", sysfs_root);
    if (access(path, F_OK) != 0)
        return -1;
    snprintf(path, sizeof(path), "%s/dev/char/%u:%u", sysfs_root,
            (unsigned int) major(rdev), (unsigned int) minor(rdev));
    if (realpath(path, real) == NULL)
        return 0;
    tty = strrchr(real, '/');
    tty = tty ? tty + 1 : real;
    return tty_is_board(tty, mac) ? 1 : 0;
}

/* The board's MAC, or "" for a device that is no board or is not there right now */
static void board_mac(const char *device, char *mac) {
    struct stat st;

    mac[0] = '\0';
    if (stat(device, &st) == 0 && S_ISCHR(st.st_mode))
        rdev_board(st.st_rdev, mac);
}

/* E5C5000M-0000-0000-0000-<MAC>, M being the mode, so a board keeps its identity
 * whichever tty it comes back on (reopen_port follows it by MAC).  Without a MAC
 * the device path stands in, as a 48 bit FNV-1a hash. */
static char *make_uuid(int mode, const char *mac, const char *device) {
    char uuid[64];

    if (mac[0] != '\0') {
        snprintf(uuid, sizeof(uuid), "E5C5000%d-0000-0000-0000-%s", mode, mac);
    } else {
        uint64_t h = 0xcbf29ce484222325ULL;
        for (const unsigned char *p = (const unsigned char *) device; *p; p++) {
            h ^= *p;
            h *= 0x100000001b3ULL;
        }
        snprintf(uuid, sizeof(uuid), "E5C5000%d-0000-0000-0000-%012llX", mode,
                (unsigned long long) (h & 0xFFFFFFFFFFFFULL));
    }
    return strdup(uuid);
}

/* What sysfs knows is an Espressif USB-Serial-JTAG device, not which chip */
static char *make_hardware(const char *mac) {
    char hw[64];

    if (mac[0] == '\0')
        return strdup("ESP32-C5");
    snprintf(hw, sizeof(hw), "Espressif USB-Serial-JTAG (%.2s:%.2s:%.2s:%.2s:%.2s:%.2s)",
            mac, mac + 2, mac + 4, mac + 6, mac + 8, mac + 10);
    return strdup(hw);
}

/* A board that rebooted while its old port was still held can come back under
 * another tty name; the MAC finds it again. */
static bool find_tty_by_mac(const char *mac, char *path, size_t path_sz) {
    char **ttys;
    int n = find_boards(&ttys);
    bool found = false;

    for (int i = 0; i < n; i++) {
        char other[13] = "";
        if (!found && tty_is_board(ttys[i], other) && strcmp(other, mac) == 0) {
            snprintf(path, path_sz, "%s/%s", dev_root, ttys[i]);
            found = true;
        }
        free(ttys[i]);
    }
    free(ttys);
    return found;
}

/* Is the port open on fd the board with this MAC?  1 yes, 0 no, -1 when there is
 * no sysfs to ask.  It asks about the open fd, not a name: the fd holds its device
 * number, so the answer cannot change under it the way a tty name can. */
static int fd_is_board(int fd, const char *mac) {
    char other[13];
    struct stat st;
    int r;

    if (fstat(fd, &st) < 0 || !S_ISCHR(st.st_mode))
        return -1;
    if ((r = rdev_board(st.st_rdev, other)) <= 0)
        return r;
    return strcmp(other, mac) == 0;
}

/* Does someone hold the flock on the port at path (a link is followed) -- a source
 * capturing from it, with this helper or the Python remote helper (pyserial's
 * exclusive=True is the same lock)?  Looked up in /proc/locks by the device and
 * inode the lock sits on, without opening the port: opening it raises DTR and RTS,
 * which reset the board being captured from.  That is also why the tty's exclusive
 * mode is not asked about: TIOCGEXCL needs the port open.  /proc/locks shows the
 * locks of the processes this one can see, on the node they opened, so a board held
 * from another container, or from the host when this runs in a container, is missed
 * (--list keeps it, and a remote helper offers it); its open still fails with
 * "already in use", the tty being in exclusive mode (see serial_open).  Without
 * /proc/locks (not Linux) nothing is known to be locked; --list needs Linux sysfs
 * anyway.  A lock of this process's own does not count. */
static bool node_locked(const char *path) {
    char want[64], line[256];
    struct stat st;
    bool locked = false;
    FILE *f;

    if (stat(path, &st) < 0 || (f = fopen("/proc/locks", "r")) == NULL)
        return false;

    /* "12: FLOCK  ADVISORY  WRITE 3067 00:05:595 0 EOF": the pid that took the lock,
     * then the file system's device as the kernel prints it, major and minor in hex,
     * and the inode.  A lock being waited for has "->" after the number, and the one
     * holding it a line of its own. */
    snprintf(want, sizeof(want), "%02x:%02x:%llu", (unsigned int) major(st.st_dev),
            (unsigned int) minor(st.st_dev), (unsigned long long) st.st_ino);
    while (!locked && fgets(line, sizeof(line), f) != NULL) {
        char type[16], where[64];
        long pid;
        if (sscanf(line, "%*s %15s %*s %*s %ld %63s", type, &pid, where) == 3)
            locked = strcmp(type, "FLOCK") == 0 && strcmp(where, want) == 0 && pid != (long) getpid();
    }
    fclose(f);
    return locked;
}

/* The same for /dev/<tty>, the way --list names a board */
static bool port_locked(const char *tty) {
    char path[PATH_MAX];

    snprintf(path, sizeof(path), "%s/%s", dev_root, tty);
    return node_locked(path);
}

/* ------------------------------------------------------------------------------
 * Serial port
 * ---------------------------------------------------------------------------- */

/* serial_open's answer for a port that someone else holds */
static int port_in_use(const char *device, char *err, size_t err_sz) {
    snprintf(err, err_sz, "%s is already in use by another capture (an esp32c5 "
            "source or another program holds it); a board captures with one "
            "radio at a time", device);
    return PORT_BUSY;
}

/* Is fd a pseudo-terminal, /dev/pts/N?  Only Linux is asked, by the device's major
 * number; elsewhere the answer is no, and none is needed (see serial_open). */
static bool pseudo_terminal(int fd) {
#ifdef __linux__
    struct stat st;
    unsigned int m;

    if (fstat(fd, &st) < 0 || !S_ISCHR(st.st_mode))
        return false;
    m = major(st.st_rdev);
    return m >= UNIX98_PTY_SLAVE_MAJOR && m < UNIX98_PTY_SLAVE_MAJOR + UNIX98_PTY_MAJOR_COUNT;
#else
    return false;
#endif
}

/* Closes a port serial_open opened, ending its exclusive mode first.  The close
 * ends it only when it is the tty's last: when someone else has the tty open too
 * (a program that had it before this helper, which does not take the flock, or
 * one with CAP_SYS_ADMIN), the mode would stay, and refuse this helper's own next
 * open. */
static void serial_close(int fd) {
    ioctl(fd, TIOCNXCL);
    close(fd);
}

/* open() of a port, for serial_open.  Installed setuid root and started by a user,
 * the helper opens as root with no capability (drop_capabilities): the nodes root
 * owns, the boards' among them, are its own, but a node of the user's that is not
 * in a group of theirs is not, and a pseudo-terminal they made is just that
 * (user:tty 0620, from tools/fake_board.py or socat).  So an open refused with
 * EACCES is tried once more with the user's file permissions, as the file system
 * uid.  That needs no capability, as the real uid is theirs, and it lets the helper
 * open only what they could open themselves -- and follow a link of theirs in
 * /tmp, which protected_symlinks refuses to anyone else, root included.  The file
 * system uid is the calling thread's alone, and this may be the capture thread
 * (reopen_port), so it is put back straight after.  Changing it clears the thread's
 * parent-death signal, which a remote helper's capture process relies on
 * (end_with_parent), so that is asked for again once it was set. */
static void end_with_parent(void);

static int open_port(const char *device) {
    int fd = open(device, O_RDWR | O_NOCTTY | O_NONBLOCK);

#ifdef __linux__
    if (fd < 0 && errno == EACCES && getuid() != geteuid()) {
        int pdeath = 0, was, e;

        prctl(PR_GET_PDEATHSIG, &pdeath);
        was = setfsuid(getuid());
        fd = open(device, O_RDWR | O_NOCTTY | O_NONBLOCK);
        e = errno;
        setfsuid((uid_t) was);
        if (pdeath != 0)
            end_with_parent();
        errno = e;
    }
#endif
    return fd;
}

/* Opens the port for this helper alone.  Returns the fd, which serial_close
 * closes; -1, or PORT_BUSY when another process holds the port, with the reason
 * in err. */
static int serial_open(const char *device, char *err, size_t err_sz) {
    struct termios tio;
    int fd, bits;

    if ((fd = open_port(device)) < 0) {
        /* another helper has the tty in exclusive mode (below) */
        if (errno == EBUSY)
            return port_in_use(device, err, err_sz);
        snprintf(err, err_sz, "cannot open %s: %s", device, strerror(errno));
        return -1;
    }

    /* One process per board.  Every kismet_cap_esp32c5 takes this lock, and so does
     * the Python remote helper (pyserial's exclusive=True).  It sits on the device
     * node, so it covers the /dev/serial/by-id links as well, and unlike TIOCEXCL it
     * also holds against a process with CAP_SYS_ADMIN that takes it, such as the
     * Python remote helper run by root (this helper keeps no capability, see
     * drop_capabilities).  It is taken before anything else touches the port: its
     * settings and its input belong to whoever holds it. */
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        int e = errno;
        close(fd);
        if (e == EWOULDBLOCK)
            return port_in_use(device, err, err_sz);
        snprintf(err, err_sz, "cannot lock %s: %s", device, strerror(e));
        return -1;
    }

    /* The flock is on the node's inode, though, and a container makes a /dev/ttyACM0
     * of its own (mknod), another inode for the same tty: a helper there does not see
     * the lock of one on the host or in another container, nor they its.  So the tty
     * itself goes into exclusive mode too, which the kernel keeps with the tty,
     * whichever node it was opened through: every other open of it fails with EBUSY
     * until this helper closes it, or dies -- Linux ends the mode with the tty's last
     * close.  A process with CAP_SYS_ADMIN is let in all the same (this helper has
     * none by now, see drop_capabilities; esptool run with sudo has it).
     *
     * Not on a pseudo-terminal (the fake board, socat): Linux keeps one's tty, and the
     * mode with it, for as long as its other end is open, so a helper that was killed
     * before it could end the mode would lock the next one out.  Nor does one need it:
     * it cannot be opened through a node of its own the way a container makes one,
     * only through its node in /dev/pts, which is where the flock is. */
    if (!pseudo_terminal(fd))
        ioctl(fd, TIOCEXCL);

    if (tcgetattr(fd, &tio) < 0) {
        snprintf(err, err_sz, "%s is not a serial port: %s", device, strerror(errno));
        serial_close(fd);
        return -1;
    }
    cfmakeraw(&tio);
    tio.c_cflag |= CLOCAL | CREAD;
    tio.c_cflag &= ~(HUPCL | CRTSCTS);
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 0;
    /* The USB-Serial-JTAG port ignores the speed.  One every platform defines
     * (B921600 does not exist on macOS and OpenBSD) keeps it off B0, which would
     * mean hang up. */
    cfsetspeed(&tio, B115200);
    if (tcsetattr(fd, TCSANOW, &tio) < 0) {
        snprintf(err, err_sz, "cannot configure %s: %s", device, strerror(errno));
        serial_close(fd);
        return -1;
    }

    /* Linux raises DTR and RTS when the port opens.  On the USB-Serial-JTAG port
     * those two lines drive the chip's reset and boot mode, and releasing DTR while
     * RTS is still up resets it.  So RTS goes first. */
    bits = TIOCM_RTS;
    ioctl(fd, TIOCMBIC, &bits);
    bits = TIOCM_DTR;
    ioctl(fd, TIOCMBIC, &bits);

    tcflush(fd, TCIFLUSH);
    return fd;
}

/* All or nothing, within a second; the port is non-blocking */
static int write_all(int fd, const char *data, size_t len) {
    double deadline = now_s() + 1.0;
    size_t done = 0;

    while (done < len) {
        ssize_t r = write(fd, data + done, len - done);
        if (r > 0) {
            done += r;
            continue;
        }
        if (r < 0 && errno != EAGAIN && errno != EINTR)
            return -1;
        if (now_s() > deadline) {
            errno = ETIMEDOUT;
            return -1;
        }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        poll(&pfd, 1, 50);
    }
    return 0;
}

/* The handshake is MODE, then after MODE_SETTLE_S the channel and START with a
 * fresh nonce.  MODE goes on its own: a board on another radio reboots when it
 * reads it, and whatever follows too soon is lost.  If the port goes away in the
 * reboot, the capture thread notices, reopens it and starts over. */
static int send_mode(local_esp32c5_t *local) {
    char line[32];
    int r = -1;

    snprintf(line, sizeof(line), "MODE %s\n", mode_command(local->mode));
    pthread_mutex_lock(&local->lock);
    if (local->fd >= 0)
        r = write_all(local->fd, line, strlen(line));
    pthread_mutex_unlock(&local->lock);
    return r;
}

/* Channel and START are written under one lock, so a hop that lands in between
 * cannot be overtaken by a stale channel. */
static int send_start(local_esp32c5_t *local) {
    static const char hex[] = "0123456789abcdef";
    char line[128];
    struct timeval tv;
    int r = -1;

    for (int i = 0; i < NONCE_LEN; i++)
        local->nonce[i] = hex[random() & 15];
    local->nonce[NONCE_LEN] = '\0';

    gettimeofday(&tv, NULL);
    pthread_mutex_lock(&local->lock);
    if (local->fd >= 0) {
        snprintf(line, sizeof(line), "CHANNELS %u\nSTART %llu %s\n", local->channel,
                (unsigned long long) tv.tv_sec * 1000000ULL + tv.tv_usec, local->nonce);
        r = write_all(local->fd, line, strlen(line));
    }
    pthread_mutex_unlock(&local->lock);
    return r;
}

/* ------------------------------------------------------------------------------
 * Status
 * ---------------------------------------------------------------------------- */

/* Passes a status on when it changes, not once a second while a port stays away */
static void status(local_esp32c5_t *local, const char *fmt, ...) {
    static char last[STATUS_MAX];
    char text[STATUS_MAX];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(text, sizeof(text), fmt, ap);
    va_end(ap);

    if (strcmp(text, last) == 0)
        return;
    snprintf(last, sizeof(last), "%s", text);
    cf_send_message(local->caph, text, MSGFLAG_INFO);
}

/* ------------------------------------------------------------------------------
 * Packets to Kismet
 * ---------------------------------------------------------------------------- */

static uint16_t le16(const uint8_t *p) {
    return p[0] | (p[1] << 8);
}

static uint32_t le32(const uint8_t *p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t) p[3] << 24);
}

/* Why the helper ends, to Kismet: as a MESSAGE, which Kismet logs, and as an ERROR.
 * Kismet (cfe427074) drops an ERROR frame unread -- kis_external.cc has no case for
 * it -- so without the message all it would show is the connection closing.  Both
 * are queued before the capture thread ends and the framework spins down, and the
 * framework sends what is queued before it ends: its select loop runs until its
 * buffer is empty, and its websocket loop until nothing is left to send (see
 * add-to-kismet.sh). */
static void say_why(kis_capture_handler_t *caph, const char *why) {
    cf_send_message(caph, why, MSGFLAG_ERROR);
    cf_send_error(caph, 0, why);
}

/* Every packet goes with a signal block that has at least its frequency in kHz (see
 * emit_record).  The one exception is a Wi-Fi frame whose radiotap header has no
 * Channel field, which then goes without a block; the firmware always writes that
 * field.  A packet that cannot be sent ends the capture thread, and with it the
 * connection, but the thread does not spin down itself: the framework does once it
 * returns (see the end of capture_thread). */
static bool send_packet(local_esp32c5_t *local, struct cf_params_signal *signal,
        struct timeval tv, uint32_t dlt, uint32_t orig_len, const uint8_t *data, uint32_t len) {
    while (1) {
        int r = cf_send_data(local->caph, NULL, 0, signal, NULL, tv, dlt, orig_len, len,
                (uint8_t *) data);
        if (r > 0)
            return true;
        if (r < 0) {
            char why[STATUS_MAX];
            snprintf(why, sizeof(why), "%s: unable to send a packet to the Kismet server",
                    local->name);
            say_why(local->caph, why);
            local->send_failed = true;
            return false;
        }
        cf_handler_wait_ringbuffer(local->caph);
    }
}

/* The frequency in a radiotap header's Channel field, in kHz; 0 without one.  The
 * fields are found by the presence bits: the ones before Channel (TSFT, 8 bytes
 * aligned to 8 from the header's start; Flags and Rate, a byte each) are stepped
 * over, as are the further presence words that bit 31 announces.  The firmware
 * writes Flags, Channel, signal and noise.  Kismet reads the field itself as well. */
static uint64_t radiotap_freq_khz(const uint8_t *rt, uint32_t len) {
    uint32_t present, word;
    size_t hdr_len, pos = 8;

    if (len < 8 || rt[0] != 0)
        return 0;
    hdr_len = le16(rt + 2);
    present = le32(rt + 4);
    if (hdr_len < 8 || hdr_len > len || !(present & (1u << 3)))
        return 0;
    for (word = present; word & (1u << 31); pos += 4) {
        if (pos + 4 > hdr_len)
            return 0;
        word = le32(rt + pos);
    }
    if (present & (1u << 0))
        pos = (pos + 7) / 8 * 8 + 8;
    pos += ((present >> 1) & 1) + ((present >> 2) & 1);
    /* the frequency and the channel flags, two u16 */
    pos += pos % 2;
    if (pos + 4 > hdr_len)
        return 0;
    return le16(rt + pos) * 1000ULL;
}

/* 802.15.4: the board wraps each frame in a TAP header (TLVs for FCS type, RSS,
 * channel, LQI, start-of-frame time).  Kismet reads TAP as if it always held the
 * same three TLVs, so the frame goes over bare, as 802.15.4 without FCS -- the radio
 * never hands the FCS over -- and the channel and signal go in the signal block. */
static bool send_154(local_esp32c5_t *local, struct timeval tv, uint32_t orig_len,
        const uint8_t *data, uint32_t len) {
    struct cf_params_signal signal;
    char chstr[8];
    unsigned int channel = 0;
    bool have_rss = false;
    float rss = 0;
    size_t tap_len, pos;

    if (len < 4 || data[0] != 0)
        goto bad;
    tap_len = le16(data + 2);
    if (tap_len < 4 || tap_len % 4 != 0 || tap_len > len)
        goto bad;

    for (pos = 4; pos + 4 <= tap_len; ) {
        uint16_t type = le16(data + pos), tlv_len = le16(data + pos + 2);
        size_t next = pos + 4 + ((tlv_len + 3u) & ~3u);
        if (next > tap_len)
            goto bad;
        if (type == 3 && tlv_len >= 2) {
            channel = le16(data + pos + 4);
        } else if (type == 1 && tlv_len == 4) {
            uint32_t bits = le32(data + pos + 4);
            memcpy(&rss, &bits, sizeof(rss));
            if (!isfinite(rss))
                goto bad;
            have_rss = true;
        }
        pos = next;
    }
    /* The firmware always says which channel; a header without one did not come
     * from it, and neither did one that runs past its own length */
    if (pos != tap_len || channel < 11 || channel > 26)
        goto bad;

    memset(&signal, 0, sizeof(signal));
    snprintf(chstr, sizeof(chstr), "%u", channel);
    signal.channel = chstr;
    signal.freq_khz = (2405 + 5 * (channel - 11)) * 1000ULL;
    /* Kismet reads dBm as u32 and casts it back, so a negative one goes over as its
     * two's complement, the same as every other source does */
    if (have_rss)
        signal.signal_dbm = (uint32_t) (int32_t) (rss < 0 ? rss - 0.5f : rss + 0.5f);

    return send_packet(local, &signal, tv, LINKTYPE_IEEE802_15_4_NOFCS,
            orig_len >= tap_len ? orig_len - tap_len : len - tap_len,
            data + tap_len, len - tap_len);

bad:
    local->dropped_154++;
    if (local->dropped_154 == 1 || local->dropped_154 % 1000 == 0)
        status(local, "%s: %lu 802.15.4 frames with a malformed TAP header dropped",
                local->name, local->dropped_154);
    return true;
}

/* The advertising channel CRC: 24 bits, x^24+x^10+x^9+x^6+x^4+x^3+x+1, shifted in
 * least significant bit first from 0x555555, which is 0xAAAAAA in this reflected
 * register, and sent least significant byte first.  The same as the firmware's. */
static uint32_t btle_adv_crc(const uint8_t *pdu, size_t len) {
    uint32_t state = 0xAAAAAA;

    for (size_t i = 0; i < len; i++) {
        uint8_t cur = pdu[i];
        for (int bit = 0; bit < 8; bit++) {
            bool in = ((state ^ cur) & 1) != 0;
            cur >>= 1;
            state >>= 1;
            if (in) {
                state |= 1u << 23;
                state ^= 0x5A6000;
            }
        }
    }
    return state;
}

/* BTLE goes as the board sends it, LL with the radio pseudo-header.  Kismet trusts
 * the CRC only when the pseudo-header says it was checked; otherwise it checks the
 * CRC itself and drops the packet when that fails.  This firmware sets "CRC
 * checked" and "CRC valid" and writes the CRC -- the controller only reports
 * advertising packets whose CRC passed.  Older firmware (the published
 * esp32c5-wireshark-sniffer builds) leaves both flags clear and the CRC zeroed, so
 * Kismet would drop every packet: for those records the helper writes the CRC of
 * the PDU into the last three bytes and sets the two flags, which is what newer
 * firmware sends.  A record that says it was checked is left as it is. */
static bool send_btle(local_esp32c5_t *local, struct timeval tv, uint32_t orig_len,
        const uint8_t *data, uint32_t len) {
    struct cf_params_signal signal;
    uint8_t rec[BTLE_MAX_RECORD];
    uint16_t flags;
    uint32_t crc;

    /* The frequency of 37, which the board labels every packet with: the controller
     * scans 37, 38 and 39 together and does not say which one it heard a packet on.
     * Kismet reads the same out of the pseudo-header's RF channel, 0. */
    memset(&signal, 0, sizeof(signal));
    signal.freq_khz = BTLE_FREQ_KHZ;

    if (len < BTLE_MIN_RECORD)
        goto bad;
    flags = le16(data + 8);
    if (flags & BTLE_FLAG_CRC_CHECKED)
        return send_packet(local, &signal, tv, local->dlt, orig_len, data, len);
    if (len > sizeof(rec))
        goto bad;

    memcpy(rec, data, len);
    crc = btle_adv_crc(rec + BTLE_PHDR_LEN + BTLE_AA_LEN,
            len - BTLE_PHDR_LEN - BTLE_AA_LEN - BTLE_CRC_LEN);
    rec[len - 3] = crc & 0xFF;
    rec[len - 2] = (crc >> 8) & 0xFF;
    rec[len - 1] = (crc >> 16) & 0xFF;
    flags |= BTLE_FLAG_CRC_CHECKED | BTLE_FLAG_CRC_VALID;
    rec[8] = flags & 0xFF;
    rec[9] = flags >> 8;

    if (!local->btle_fixup_said) {
        local->btle_fixup_said = true;
        status(local, "%s: the board's firmware does not mark BTLE packets as CRC checked, "
                "so Kismet would drop them; the helper fills in the CRC and the flags (the "
                "board only reports packets whose CRC passed). Flashing current firmware "
                "makes this unnecessary", local->name);
    }
    return send_packet(local, &signal, tv, local->dlt, orig_len, rec, len);

bad:
    local->dropped_btle++;
    if (local->dropped_btle == 1 || local->dropped_btle % 1000 == 0)
        status(local, "%s: %lu BTLE records of impossible length dropped",
                local->name, local->dropped_btle);
    return true;
}

/* The signal block: 802.15.4's has the channel, the signal and the frequency from the
 * TAP header; BTLE's the frequency of channel 37; Wi-Fi's the frequency of the
 * radiotap header, and none at all for a header without one.  Kismet takes a
 * packet's frequency from the radiotap header and the BTLE pseudo-header itself, so
 * for those two the block only says the same; the Python remote helper sends the
 * same blocks. */
static bool emit_record(local_esp32c5_t *local, uint32_t ts_sec, uint32_t ts_usec,
        uint32_t orig_len, const uint8_t *data, uint32_t len) {
    struct timeval tv = { .tv_sec = ts_sec, .tv_usec = ts_usec };
    struct cf_params_signal signal;

    if (local->mode == MODE_154)
        return send_154(local, tv, orig_len, data, len);
    if (local->mode == MODE_BLE)
        return send_btle(local, tv, orig_len, data, len);
    /* Wi-Fi is radiotap, which Kismet decodes as it is */
    memset(&signal, 0, sizeof(signal));
    signal.freq_khz = radiotap_freq_khz(data, len);
    return send_packet(local, signal.freq_khz != 0 ? &signal : NULL, tv, local->dlt,
            orig_len, data, len);
}

/* ------------------------------------------------------------------------------
 * The stream: our marker, the PCAP global header, then records
 *
 * The frames in the records are copied byte for byte, and whoever transmits
 * chooses what is in them: an SSID, advertising data or an 802.15.4 payload can
 * hold "<<START>>\n" and a PCAP header as easily as anything else.  So nothing
 * inside a record is ever read as part of the stream.  The firmware writes every
 * record whole, from one task, and restarts the stream only between records (or
 * reboots), which gives this rule.  esp32c5_kismet/board.py follows the same one.
 *
 *  1. Before sync, only "<<START>> <our nonce>", then "\r\n" or "\n", counts; the
 *     nonce is fresh with every START, so no older stream and no frame can carry
 *     it.  The 24 bytes after that line must be a PCAP global header: d4 c3 b2 a1
 *     02 00 04 00, and the link type of the mode at offset 20.
 *
 *  2. Then, at each record boundary, once 16 bytes are there:
 *
 *     a. bytes that start with "<<START>>" or "\n<<START>>" begin a new stream
 *        (the board rebooted, or answered another START): sync is lost, and the
 *        marker scan goes on from the boundary.  No record header starts that way:
 *        its ts_usec would read "ART>" or "TART", far above 999999.
 *
 *     b. otherwise they are a record header, which must have ts_usec < 1000000
 *        and 0 < incl_len <= 16384 and incl_len <= orig_len.  The record is passed
 *        on once all of it is there; the next boundary is right after it.
 *
 *     c. a header that fails (b) loses sync.  Only now is the last record passed
 *        on looked into: a board that resets while its port stays open cuts the
 *        record it was sending short, and its new marker then sits in what was
 *        taken for that record's payload.  The search covers the start of the last
 *        record passed on (kept in the buffer until the next one is; the boundary
 *        itself when none was since sync) up to 16 bytes past the boundary.  The
 *        first "<<START>>" there that is followed by an optional " " and 1 to 16
 *        letters or digits, an optional "\r", then "\n" and d4 c3 b2 a1 02 00 04
 *        00 -- or by the start of that, up to the end of what has arrived -- is
 *        where the marker scan goes on; without one it goes on from the boundary.
 *
 * A frame holding that whole signature is therefore passed on like any other: the
 * header after it is one the firmware wrote, and it passes (b).  The cost is in
 * (c), a reset without a USB disconnect, which the real port does not do: the
 * record the reset cut short has already gone to Kismet, with what followed it.
 * ---------------------------------------------------------------------------- */

static const uint8_t pcap_magic_ver[8] = { 0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00 };

#define NO_RECORD ((size_t) -1)

/* Synced, and past a PCAP global header in the link type of the radio asked for:
 * records are going to Kismet.  A board whose firmware lacks that radio syncs on
 * every START and never gets this far. */
static bool capturing(const local_esp32c5_t *local) {
    return local->synced && !local->need_global_hdr;
}

static void buf_drop(local_esp32c5_t *local, size_t n) {
    memmove(local->buf, local->buf + n, local->buf_len - n);
    local->buf_len -= n;
}

/* Room for the next read.  Framing leaves at most the last record and a partial
 * one behind, so a full buffer means a stream that makes no sense. */
static size_t rx_room(local_esp32c5_t *local) {
    if (local->buf_len == RX_BUF_SIZE) {
        local->buf_len = 0;
        local->kept = 0;
    }
    return RX_BUF_SIZE - local->buf_len;
}

/* Looks for the answer to our START: "<<START>> <nonce>" and a line end.  Anything
 * before it is boot text or an older stream.  Returns true once synced. */
static bool scan_for_marker(local_esp32c5_t *local) {
    char want[32];
    size_t want_len = snprintf(want, sizeof(want), START_MARKER " %s", local->nonce);
    size_t pos = 0;

    while (1) {
        uint8_t *m = memmem(local->buf + pos, local->buf_len - pos, want, want_len);
        if (m == NULL) {
            /* keep the tail: a marker may be split between reads */
            if (local->buf_len > want_len + 1)
                buf_drop(local, local->buf_len - (want_len + 1));
            return false;
        }
        size_t at = m - local->buf, after = at + want_len;
        if (after < local->buf_len && local->buf[after] == '\r')
            after++;
        if (after >= local->buf_len) {
            buf_drop(local, at); /* the line end has not arrived yet */
            return false;
        }
        if (local->buf[after] == '\n') {
            buf_drop(local, after + 1);
            local->synced = true;
            local->need_global_hdr = true;
            local->kept = 0;
            return true;
        }
        pos = at + 1; /* our nonce was only the start of a longer one */
    }
}

/* Rule 2a: a new stream at a record boundary.  At least 10 bytes are there. */
static bool marker_at_boundary(const uint8_t *p) {
    return memcmp(p, START_MARKER, START_MARKER_LEN) == 0 ||
        (p[0] == '\n' && memcmp(p + 1, START_MARKER, START_MARKER_LEN) == 0);
}

/* Rule 2c: does a new-stream signature start at buf[at]?  1 if it does, 0 if not,
 * -1 if what has arrived ends while it still could. */
static int restart_signature_at(const uint8_t *buf, size_t len, size_t at) {
    size_t q = at, n;

    for (n = 0; n < START_MARKER_LEN; n++, q++) {
        if (q >= len)
            return -1;
        if (buf[q] != (uint8_t) START_MARKER[n])
            return 0;
    }
    if (q >= len)
        return -1;
    if (buf[q] == ' ') {
        for (q++, n = 0; n < 16 && q < len && isalnum(buf[q]); n++, q++)
            ;
        if (q >= len)
            return -1;
        if (n == 0)
            return 0;
    }
    if (buf[q] == '\r' && ++q >= len)
        return -1;
    if (buf[q] != '\n')
        return 0;
    for (q++, n = 0; n < sizeof(pcap_magic_ver); n++, q++) {
        if (q >= len)
            return -1;
        if (buf[q] != pcap_magic_ver[n])
            return 0;
    }
    return 1;
}

/* Rule 2c: the first signature that starts in [from, to), -1 for none */
static long find_stream_restart(const uint8_t *buf, size_t len, size_t from, size_t to) {
    for (size_t at = from; at < to && at < len; at++) {
        if (buf[at] == '<' && restart_signature_at(buf, len, at) != 0)
            return at;
    }
    return -1;
}

/* Passes on the whole records in the buffer, by the rule above.  Returns false
 * when sync is lost. */
static bool frame_records(local_esp32c5_t *local) {
    size_t pos = local->kept, prev = local->kept > 0 ? 0 : NO_RECORD;
    char lost[128] = "";

    if (local->need_global_hdr) {
        if (local->buf_len < PCAP_GLOBAL_HDR_LEN)
            return true;
        uint32_t network = le32(local->buf + 20);
        if (memcmp(local->buf, pcap_magic_ver, 8) != 0) {
            snprintf(lost, sizeof(lost), "bad PCAP global header");
        } else if (network != mode_board_linktype(local->mode)) {
            /* still on another radio: ask again rather than mislabel its frames */
            local->on_radio = false;
            snprintf(lost, sizeof(lost), "the board sends link type %u, not %u",
                    network, mode_board_linktype(local->mode));
        } else {
            pos = PCAP_GLOBAL_HDR_LEN;
            local->need_global_hdr = false;
            local->on_radio = true;
            /* Not before: firmware without the radio answers every START, in the link
             * type of another one, which would make this alternate with "lost sync" */
            status(local, "%s capturing (%s)", local->name, mode_name(local->mode));
        }
    }

    while (lost[0] == '\0' && local->buf_len - pos >= PCAP_REC_HDR_LEN) {
        const uint8_t *h = local->buf + pos;

        if (marker_at_boundary(h)) {
            snprintf(lost, sizeof(lost), "the board restarted the stream");
            break;
        }

        uint32_t ts_sec = le32(h), ts_usec = le32(h + 4), incl = le32(h + 8), orig = le32(h + 12);
        if (ts_usec >= 1000000 || incl > orig || incl == 0 || incl > MAX_RECORD_LEN) {
            long at = find_stream_restart(local->buf, local->buf_len,
                    prev == NO_RECORD ? pos : prev, pos + PCAP_REC_HDR_LEN);
            snprintf(lost, sizeof(lost), "damaged PCAP record");
            if (at >= 0)
                pos = at;
            break;
        }
        if (pos + PCAP_REC_HDR_LEN + incl > local->buf_len)
            break;
        if (!emit_record(local, ts_sec, ts_usec, orig, h + PCAP_REC_HDR_LEN, incl))
            return false;
        prev = pos;
        pos += PCAP_REC_HDR_LEN + incl;
    }

    if (lost[0] != '\0') {
        buf_drop(local, pos);
        local->kept = 0;
        local->synced = false;
        local->need_global_hdr = true;
        local->sync_losses++;
        status(local, "%s: lost sync (%s)", local->name, lost);
        return false;
    }

    /* Keep the last record passed on for rule 2c; drop what came before it */
    if (prev == NO_RECORD)
        prev = pos;
    buf_drop(local, prev);
    local->kept = pos - prev;
    return true;
}

/* Feeds what is in the buffer through marker scan and framing, as often as either
 * makes progress.  Returns true if sync was lost along the way. */
static bool consume(local_esp32c5_t *local) {
    bool lost_sync = false;

    while (!local->caph->spindown && !local->send_failed) {
        if (!local->synced && !scan_for_marker(local))
            return lost_sync;
        if (frame_records(local))
            return lost_sync;
        lost_sync = true;
    }
    return lost_sync;
}

/* ------------------------------------------------------------------------------
 * Capture thread
 * ---------------------------------------------------------------------------- */

/* Asks for a new stream at once: the next pass of the capture thread starts the
 * handshake */
static void handshake_now(local_esp32c5_t *local) {
    local->last_start = 0;
    local->mode_sent = 0;
}

static void drop_port(local_esp32c5_t *local, const char *why) {
    pthread_mutex_lock(&local->lock);
    if (local->fd >= 0)
        serial_close(local->fd);
    local->fd = -1;
    pthread_mutex_unlock(&local->lock);

    if (capturing(local))
        local->unsynced_since = now_s();
    local->synced = false;
    local->on_radio = false;
    local->buf_len = 0;
    local->kept = 0;
    status(local, "%s: %s, reconnecting", local->name, why);
}

/* Opens the port again after it went away.  The configured device comes first,
 * but only if it still holds this source's board: boards that reboot together can
 * come back with their tty names swapped, and a board that is not ours must not
 * be sent MODE or read from under our name.  When ours is elsewhere now, its MAC
 * finds it for this attempt only -- the configured path, maybe a /dev/serial/by-id
 * link, stays the one tried first. */
static bool reopen_port(local_esp32c5_t *local) {
    char err[STATUS_MAX], path[PATH_MAX];
    int fd = serial_open(local->device, err, sizeof(err));

    if (fd >= 0 && local->mac[0] != '\0' && fd_is_board(fd, local->mac) == 0) {
        status(local, "%s: %s now holds another board, looking for %s", local->name,
                local->device, local->mac);
        serial_close(fd);
        fd = -1;
    }
    if (fd < 0 && local->mac[0] != '\0' &&
            find_tty_by_mac(local->mac, path, sizeof(path)) && strcmp(path, local->device) != 0) {
        fd = serial_open(path, err, sizeof(err));
        if (fd >= 0 && fd_is_board(fd, local->mac) == 0) {
            serial_close(fd);
            fd = -1;
        } else if (fd >= 0) {
            status(local, "%s: board %s is on %s now", local->name, local->mac, path);
        }
    }
    if (fd == PORT_BUSY)
        status(local, "%s: %s; waiting for it", local->name, err);
    if (fd < 0)
        return false;

    pthread_mutex_lock(&local->lock);
    local->fd = fd;
    pthread_mutex_unlock(&local->lock);
    local->last_byte = now_s();
    handshake_now(local);
    return true;
}

/* A websocket connection that has heard no PING from Kismet for PING_TIMEOUT_S.
 * Kismet PINGs every source every 5 seconds, and the framework ends a TCP or local
 * connection that hears none for 15, but its websocket loop has no such check.  And
 * Kismet can stop using a websocket without closing it: when another connection
 * comes in under a running source's uuid, it closes that source and leaves its
 * websocket open.  The capture would then go on for good, holding the board, with
 * no one reading it.
 *
 * The framework stamps each PING with the wall clock (last_ping), which can jump:
 * a Raspberry Pi has no clock of its own, and sets it from the network some time
 * after it boots.  So the time runs from when the capture thread, which looks at
 * least every half second, saw the stamp change, on the monotonic clock. */
static bool ws_ping_lost(local_esp32c5_t *local) {
#ifdef HAVE_LIBWEBSOCKETS
    kis_capture_handler_t *caph = local->caph;
    double now = now_s();

    if (!caph->use_ws)
        return false;
    if (caph->last_ping != local->ping_seen || local->ping_seen_at == 0) {
        local->ping_seen = caph->last_ping;
        local->ping_seen_at = now;
    }
    return now - local->ping_seen_at > PING_TIMEOUT_S;
#else
    return false;
#endif
}

static void capture_thread(kis_capture_handler_t *caph) {
    local_esp32c5_t *local = (local_esp32c5_t *) caph->userdata;
    char errstr[STATUS_MAX];

    local->unsynced_since = now_s();
    local->last_byte = now_s();
    handshake_now(local);

    while (!caph->spindown && !local->send_failed) {
        double now = now_s();

        /* Away, silent or on another radio: the board has not been capturing */
        if (!capturing(local) && now - local->unsynced_since > RECOVER_TIMEOUT_S) {
            snprintf(errstr, sizeof(errstr), "%s: no capture from the board on %s for %.0f "
                    "seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing "
                    "else holding the port?", local->name, local->device, RECOVER_TIMEOUT_S);
            say_why(caph, errstr);
            break;
        }

        /* Ending the capture ends the connection (see the end of this function), and the
         * framework makes a new one 5 seconds later, unless --disable-retry.  Only the
         * helper's own log can say so: Kismet is not listening. */
        if (ws_ping_lost(local)) {
            fprintf(stderr, "ERROR: %s: no PING from Kismet for %d seconds; closing the "
                    "connection\n", local->name, PING_TIMEOUT_S);
            break;
        }

        if (local->fd < 0) {
            if (!reopen_port(local))
                usleep(500000);
            continue;
        }

        struct pollfd pfd = { .fd = local->fd, .events = POLLIN };
        int r = poll(&pfd, 1, 100);
        if (r < 0 && errno != EINTR) {
            drop_port(local, strerror(errno));
            continue;
        }
        if (r > 0) {
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                drop_port(local, "port closed");
                continue;
            }
            /* a read of 0 bytes would look like EOF */
            size_t room = rx_room(local);
            ssize_t n = read(local->fd, local->buf + local->buf_len, room);
            if (n == 0) {
                drop_port(local, "port closed");
                continue;
            }
            if (n < 0 && errno != EAGAIN && errno != EINTR) {
                drop_port(local, strerror(errno));
                continue;
            }
            if (n > 0) {
                bool was_capturing = capturing(local);
                local->buf_len += n;
                local->last_byte = now_s();
                if (consume(local)) {
                    /* only a fresh START brings a marker with our nonce: ask now */
                    handshake_now(local);
                }
                if (was_capturing && !capturing(local))
                    local->unsynced_since = now_s();
            }
        }

        if (capturing(local))
            continue;

        now = now_s();
        /* Asked whether or not bytes are arriving: a board that lost sync on a busy
         * channel keeps sending records and never goes quiet.  A failed write is also
         * how a port whose board has rebooted gives itself away.  MODE is left out
         * while the board is known to be on our radio already. */
        if (local->mode_sent > 0) {
            if (now - local->mode_sent >= MODE_SETTLE_S) {
                local->mode_sent = 0;
                if (send_start(local) < 0) {
                    drop_port(local, "write failed");
                    continue;
                }
            }
        } else if (now - local->last_start > START_RETRY_S) {
            local->last_start = now;
            if (local->on_radio) {
                r = send_start(local);
            } else if ((r = send_mode(local)) == 0) {
                local->mode_sent = now;
            }
            if (r < 0) {
                drop_port(local, "write failed");
                continue;
            }
        }
        /* A board that reboots can take its USB device with it, and the old handle
         * can stay open and silent.  Only before capture, though: once capturing,
         * silence is just a quiet channel. */
        if (now - local->last_byte > STALL_TIMEOUT_S)
            drop_port(local, "no answer");
    }

    pthread_mutex_lock(&local->lock);
    if (local->fd >= 0)
        serial_close(local->fd);
    local->fd = -1;
    pthread_mutex_unlock(&local->lock);

    /* The framework spins down once this returns (cf_int_capture_thread), which ends
     * the connection.  Not here as well, nor where a send fails (send_packet): the
     * first spindown can end the websocket loop, which then cancels this thread at any
     * instruction (the framework makes it cancelable asynchronously), and a second one
     * would give it a window in which this thread holds the handler's lock -- held for
     * good, the process would hang as it ends instead of letting the framework connect
     * again. */
}

/* ------------------------------------------------------------------------------
 * Kismet callbacks
 * ---------------------------------------------------------------------------- */

/* Everything open and probe share: the interface must be ours, then mode, channel=,
 * device, identity and channels.  Returns 1; 0 when it is not ours; -1 when it is
 * wrong in itself (a mode= or channel= the radio does not have); NO_BOARD_NOW when
 * which port it means cannot be told now -- no board plugged in, or several, or no
 * sysfs to look in.  For all but 1, msg says why. */
static int parse_definition(char *definition, char *msg, int *mode, unsigned int *channel,
        char **interface, char **device, char *mac, char **uuid, cf_params_interface_t *iface) {
    char *placeholder;
    int len;

    if ((len = cf_parse_interface(&placeholder, definition)) <= 0) {
        snprintf(msg, STATUS_MAX, "unable to find interface in definition");
        return 0;
    }
    if (len < 7 || strncmp(placeholder, "esp32c5", 7) != 0) {
        snprintf(msg, STATUS_MAX, "not an esp32c5 source");
        return 0;
    }
    *interface = strndup(placeholder, len);

    if ((*mode = parse_mode(definition, *interface)) < 0) {
        snprintf(msg, STATUS_MAX, "%s: mode must be wifi, zigbee or btle", *interface);
        return -1;
    }
    if (!parse_channel(definition, *interface, *mode, channel, msg))
        return -1;
    fill_channels(iface, *mode);

    if ((*device = resolve_device(definition, *interface, msg)) == NULL)
        return NO_BOARD_NOW;
    board_mac(*device, mac);

    if ((len = cf_find_flag(&placeholder, "uuid", definition)) > 0)
        *uuid = strndup(placeholder, len);
    else
        *uuid = make_uuid(*mode, mac, *device);

    iface->hardware = make_hardware(mac);
    return 1;
}

/* The source's name, in these messages as in Kismet: name= when the definition has
 * it, otherwise the interface.  Allocated. */
static char *source_name(char *definition, const char *interface) {
    char *placeholder;
    int len;

    if ((len = cf_find_flag(&placeholder, "name", definition)) > 0)
        return strndup(placeholder, len);
    return strdup(interface);
}

static int probe_callback(kis_capture_handler_t *caph, uint32_t seqno, char *definition,
        char *msg, char **uuid, cf_params_interface_t **ret_interface,
        cf_params_spectrum_t **ret_spectrum) {
    char *interface = NULL, *device = NULL;
    char mac[13] = "";
    unsigned int channel;
    int mode, r;

    *ret_spectrum = NULL;
    *ret_interface = cf_params_interface_new();

    r = parse_definition(definition, msg, &mode, &channel, &interface, &device, mac, uuid,
            *ret_interface);

    /* Kismet keeps a probe's reasons to itself and never probes a definition again
     * once no helper has claimed it, so one named for this helper is claimed even
     * while its board cannot be found: the open then says why, and Kismet retries
     * it every 5 seconds until the board is there.  Not for a remote helper
     * (--connect), which probes its own definition before it connects: that stops
     * with the reason, and the capture framework tries again 5 seconds later. */
    if (r == NO_BOARD_NOW && caph->remote_host == NULL && our_name(interface))
        r = 1;

    /* A remote helper does not offer Kismet a port another process holds (Linux; see
     * node_locked).  Its open could only fail -- and first, as the board and radio give
     * the same uuid wherever they are captured from, Kismet would close the running
     * source that has that uuid, a local source of its own or another remote helper's,
     * to make room for this one.  The framework probes before every connection it
     * makes, over TCP as over the websocket, so with retry the port is looked at again
     * every 5 seconds, and offered once it is free. */
    if (r == 1 && caph->remote_host != NULL && node_locked(device)) {
        char *name = source_name(definition, interface);
        snprintf(msg, STATUS_MAX, "%s: %s is already in use by another capture; not offering "
                "it to Kismet%s", name, device, caph->remote_retry ?
                " until it is free (looked at again every 5 seconds)" : "");
        free(name);
        r = -1;
    }

    free(interface);
    free(device);
    return r;
}

static int list_callback(kis_capture_handler_t *caph, uint32_t seqno, char *msg,
        cf_params_list_interface_t ***interfaces) {
    /* The name carries the radio, since Kismet keeps nothing else of a listed
     * interface.  Letters, digits and '-' only: the web UI uses it as an element id */
    static const char *names[] = { "", "zigbee", "btle" };
    static const char *modes[] = { "wifi", "zigbee", "btle" };
    char **ttys;
    int n = find_boards(&ttys), k = 0;

    *interfaces = NULL;
    if (n <= 0) {
        free(ttys);
        return 0;
    }

    /* Each board once per radio, like the esp32c5-wireshark-sniffer project's extcap
     * plugin for Wireshark: only one of the three can capture at a time, since
     * picking another reboots the board */
    *interfaces = (cf_params_list_interface_t **) malloc(sizeof(cf_params_list_interface_t *) * n * 3);
    for (int i = 0; i < n; i++) {
        char name[64], mac[13] = "";
        /* Gone since find_boards looked, rebooting maybe; or in use, and then none of
         * its three names can be opened.  Kismet can only mark a listed name in use
         * when it is a running source's name or capif, which covers one of the three
         * at most. */
        if (!tty_is_board(ttys[i], mac) || port_locked(ttys[i])) {
            free(ttys[i]);
            continue;
        }
        for (int m = 0; m < 3; m++) {
            char flags[32];
            cf_params_list_interface_t *li =
                (cf_params_list_interface_t *) calloc(1, sizeof(cf_params_list_interface_t));
            snprintf(name, sizeof(name), "esp32c5%s-%s", names[m], ttys[i]);
            snprintf(flags, sizeof(flags), "mode=%s", modes[m]);
            li->interface = strdup(name);
            li->flags = strdup(flags);
            li->hardware = make_hardware(mac);
            (*interfaces)[k++] = li;
        }
        free(ttys[i]);
    }
    free(ttys);

    /* the framework frees the list only when there is something in it */
    if (k == 0) {
        free(*interfaces);
        *interfaces = NULL;
    }
    return k;
}

static int open_callback(kis_capture_handler_t *caph, uint32_t seqno, char *definition,
        char *msg, uint32_t *dlt, char **uuid, cf_params_interface_t **ret_interface,
        cf_params_spectrum_t **ret_spectrum) {
    local_esp32c5_t *local = (local_esp32c5_t *) caph->userdata;
    char chstr[8], real[PATH_MAX], capif[PATH_MAX + 16];
    int r, fd;

    *ret_spectrum = NULL;
    *ret_interface = cf_params_interface_new();

    /* channel= included, all checked before the port is touched */
    r = parse_definition(definition, msg, &local->mode, &local->channel, &local->interface,
            &local->device, local->mac, uuid, *ret_interface);
    if (r <= 0) {
        if (r == 0)
            snprintf(msg, STATUS_MAX, "not an esp32c5 source definition");
        return -1;
    }

    local->name = source_name(definition, local->interface);

    local->dlt = mode_dlt(local->mode);
    *dlt = local->dlt;

    if ((fd = serial_open(local->device, msg, STATUS_MAX)) < 0)
        return -1;
    local->fd = fd;

    snprintf(chstr, sizeof(chstr), "%u", local->channel);
    (*ret_interface)->chanset = strdup(chstr);
    /* The framework reports caph->channel whenever Kismet sets a channel, one this
     * helper refuses included, and only sets it itself when a set succeeds */
    free(caph->channel);
    caph->channel = strdup(chstr);

    /* The port as --list names it for Wi-Fi, however this source was defined
     * (device=, a by-id link, a bare esp32c5), so that Kismet can match that listed
     * row with this source.  It matches that one row only; --list covers the other
     * two by leaving out a board whose port is locked. */
    if (realpath(local->device, real) != NULL) {
        const char *tty = strncmp(real, "/dev/", 5) == 0 ? real + 5 : strrchr(real, '/') + 1;
        snprintf(capif, sizeof(capif), "esp32c5-%s", tty);
    } else {
        snprintf(capif, sizeof(capif), "%s", local->device);
    }
    (*ret_interface)->capif = strdup(capif);

    return 1;
}

/* A channel from Kismet's hop list or a channel set.  %u takes the number at its
 * start, so Kismet's Wi-Fi names such as 6HT40 come out as their channel (6), and
 * a number the radio does not have is refused by chancontrol_callback; only a
 * string that does not start with a number is refused here.  channel= in the
 * definition is read strictly, by parse_channel.
 *
 * In BTLE mode 38 and 39 are rewritten to "37" in place, as that is what Kismet is
 * to be told: once a channel set succeeds, the framework reports the string it
 * passed here, not caph->channel, and only this callback sees the string before.
 * The string is the framework's own writable copy (a buffer for a channel set, an
 * allocated string for each entry of a hop list), and one that reads as 37 to 39
 * has room for "37". */
static void *chantranslate_callback(kis_capture_handler_t *caph, const char *chanstr) {
    local_esp32c5_t *local = (local_esp32c5_t *) caph->userdata;
    local_channel_t *ret;
    unsigned int ch;

    if (sscanf(chanstr, "%u", &ch) != 1) {
        char errstr[STATUS_MAX];
        snprintf(errstr, sizeof(errstr), "unable to parse channel '%s'; esp32c5 channels are "
                "plain numbers", chanstr);
        cf_send_message(caph, errstr, MSGFLAG_INFO);
        return NULL;
    }
    if (local->mode == MODE_BLE && ch >= 37 && ch <= 39 && strcmp(chanstr, BTLE_CHANNEL_STR) != 0)
        strcpy((char *) chanstr, BTLE_CHANNEL_STR);
    ret = (local_channel_t *) malloc(sizeof(local_channel_t));
    ret->channel = ch;
    return ret;
}

/* A channel the radio does not have.  Refused the way Kismet's own helpers refuse
 * one: the capture goes on where it was, and the framework answers the channel set
 * with that channel -- not with a failure, on which Kismet would put the source in
 * error and close it.  So Kismet's answer to the set says nothing, and the refusal
 * goes to Kismet as an error message, which it logs.  Only for a set (seqno not 0):
 * the hop thread asks for its channels over and over, and the framework drops the
 * ones refused after a lap and says so itself. */
static int refuse_channel(local_esp32c5_t *local, uint32_t seqno, unsigned int ch, char *msg) {
    snprintf(msg, STATUS_MAX, "%s cannot tune to channel %u in %s mode", local->name, ch,
            mode_name(local->mode));
    if (seqno != 0)
        cf_send_message(local->caph, msg, MSGFLAG_ERROR);
    return 0;
}

static int chancontrol_callback(kis_capture_handler_t *caph, uint32_t seqno, void *privchan,
        char *msg) {
    local_esp32c5_t *local = (local_esp32c5_t *) caph->userdata;
    local_channel_t *channel = (local_channel_t *) privchan;
    char line[32];

    if (channel == NULL)
        return 0;

    /* The BTLE controller scans all three advertising channels together and will
     * not be restricted to one: there is nothing to tune, and any of the three is 37
     * (see chantranslate_callback) */
    if (local->mode == MODE_BLE) {
        if (channel->channel < 37 || channel->channel > 39)
            return refuse_channel(local, seqno, channel->channel, msg);
        free(caph->channel);
        caph->channel = strdup(BTLE_CHANNEL_STR);
        return 1;
    }

    if (!channel_ok(local->mode, channel->channel))
        return refuse_channel(local, seqno, channel->channel, msg);

    /* A failed write is not an error here: the capture thread notices the port is
     * gone, reopens it, and sends this channel again with its START */
    pthread_mutex_lock(&local->lock);
    local->channel = channel->channel;
    if (local->fd >= 0) {
        snprintf(line, sizeof(line), "CHANNELS %u\n", channel->channel);
        write_all(local->fd, line, strlen(line));
    }
    pthread_mutex_unlock(&local->lock);

    /* The channel the framework puts in its reports to Kismet: those answer a
     * channel set (which, once it succeeds, the framework reports as the string
     * Kismet sent) or a hop list (reported as the list), and Kismet sets a source's
     * kismet.datasource.channel only from them and from the open and probe reports,
     * never on a hop -- a hopping source keeps showing the channel it started on.
     * Both callers, the hop thread and a channel set, hold caph->handler_lock. */
    snprintf(line, sizeof(line), "%u", channel->channel);
    free(caph->channel);
    caph->channel = strdup(line);

    return 1;
}

#ifdef HAVE_LIBWEBSOCKETS
/* What a command line says about remote capture and its login */
typedef struct {
    bool remote, tcp;
    const char *user, *password, *apikey;
} login_args_t;

/* Reads a command line the way the capture framework does (cf_handler_parse_opts):
 * with getopt_long and the framework's own table of long options.  getopt_long takes
 * any abbreviation that fits one option alone (--pass for --password, not --s), which
 * only the whole table tells; it takes the word after an option that needs a value
 * as that value, whatever it looks like; it stops at "--"; and a later option wins
 * over an earlier one.  The '-' that starts the short options makes it read argv in
 * its order, where the framework's getopt moves the operands to the end; the options
 * it finds are the same.  The values point into argv. */
static void read_login_args(int argc, char *argv[], login_args_t *args) {
    static const struct option longopt[] = {
        { "in-fd", required_argument, 0, 1 },
        { "out-fd", required_argument, 0, 2 },
        { "connect", required_argument, 0, 3 },
        { "source", required_argument, 0, 4 },
        { "disable-retry", no_argument, 0, 5 },
        { "daemonize", no_argument, 0, 6 },
        { "list", no_argument, 0, 7 },
        { "fixed-gps", required_argument, 0, 8 },
        { "gps-name", required_argument, 0, 9 },
        { "host", required_argument, 0, 10 },
        { "autodetect", optional_argument, 0, 11 },
        { "tcp", no_argument, 0, 12 },
        { "ssl", no_argument, 0, 13 },
        { "user", required_argument, 0, 14 },
        { "password", required_argument, 0, 15 },
        { "apikey", required_argument, 0, 16 },
        { "endpoint", required_argument, 0, 17 },
        { "ssl-certificate", required_argument, 0, 18 },
        { "help", no_argument, 0, 'h' },
        { "version", no_argument, 0, 'v' },
        { 0, 0, 0, 0 }
    };
    int r;

    memset(args, 0, sizeof(*args));
    /* 0 starts getopt afresh, as the framework does before it reads argv itself */
    optind = 0;
    opterr = 0;
    while ((r = getopt_long(argc, argv, "-vh", longopt, NULL)) != -1) {
        if (r == 3 || r == 10 || r == 11)
            args->remote = true;
        else if (r == 12)
            args->tcp = true;
        else if (r == 14)
            args->user = optarg;
        else if (r == 15)
            args->password = optarg;
        else if (r == 16)
            args->apikey = optarg;
    }
}
#endif

/* Remote capture over websockets needs a Kismet login, and one on the command line
 * can be read by every user in the process list.  So with --connect, --host or
 * --autodetect, what the command line leaves out of the login comes from the
 * environment: with none of --user, --password and --apikey, KISMET_CAP_APIKEY or
 * else KISMET_CAP_USER and KISMET_CAP_PASSWORD; with --user alone,
 * KISMET_CAP_PASSWORD; with --password alone, KISMET_CAP_USER.  An empty variable
 * counts as unset, and the command line is read as the framework will read it
 * (read_login_args: --pass is --password, and nothing after a "--" counts).  They go
 * to the framework as options in a copy of argv, right after the program's name,
 * where no "--" can make operands of them; the process's own command line,
 * /proc/<pid>/cmdline, keeps the original.  Legacy TCP (--tcp) has no login, and a
 * Kismet built without libwebsockets has no login options: nothing is added then.
 * Returns argv itself when nothing is added. */
static char **login_from_env(int argc, char *argv[], int *ret_argc) {
    *ret_argc = argc;
#ifdef HAVE_LIBWEBSOCKETS
    const char *apikey = getenv("KISMET_CAP_APIKEY");
    const char *user = getenv("KISMET_CAP_USER"), *password = getenv("KISMET_CAP_PASSWORD");
    login_args_t given;
    char **copy;
    int n = 0;

    read_login_args(argc, argv, &given);
    if (!given.remote || given.tcp || given.apikey != NULL ||
            (given.user != NULL && given.password != NULL))
        return argv;

    if (apikey != NULL && apikey[0] == '\0')
        apikey = NULL;
    if (user != NULL && user[0] == '\0')
        user = NULL;
    if (password != NULL && password[0] == '\0')
        password = NULL;

    if (given.user != NULL || given.password != NULL) {
        /* half a login given: only the other half can complete it */
        apikey = NULL;
        if (given.user != NULL)
            user = NULL;
        else
            password = NULL;
    } else if (apikey != NULL) {
        user = password = NULL;
    } else if (user == NULL || password == NULL) {
        return argv;
    }
    if (apikey == NULL && user == NULL && password == NULL)
        return argv;

    /* at most four options added, and the NULL that ends argv */
    copy = (char **) calloc(argc + 5, sizeof(char *));
    copy[n++] = argv[0];
    if (apikey != NULL) {
        copy[n++] = (char *) "--apikey";
        copy[n++] = (char *) apikey;
    }
    if (user != NULL) {
        copy[n++] = (char *) "--user";
        copy[n++] = (char *) user;
    }
    if (password != NULL) {
        copy[n++] = (char *) "--password";
        copy[n++] = (char *) password;
    }
    memcpy(copy + n, argv + 1, sizeof(char *) * (argc - 1));
    n += argc - 1;
    copy[n] = NULL;
    *ret_argc = n;
    return copy;
#else
    return argv;
#endif
}

/* The framework (add-to-kismet.sh) sends a user and password in a Basic Authorization
 * header, which Kismet's server takes as it is.  But Basic ends the user name at its
 * first ':', so a user name with one goes in the websocket URI's query instead, and
 * the server percent-decodes the whole query and only then splits it at '&'
 * (kis_net_beast_httpd.cc, decode_get_variables): a user name with ':' and an '&'
 * anywhere in the login cannot log in either way.  Said on stderr before the framework
 * tries, for a login from the command line as for one from the environment (argv is
 * login_from_env's), when the framework logs in with a user and password: it does
 * when it has both, and with the API key otherwise, which goes in a cookie.  The
 * Python remote helper has the same rule and says the same (remote.py,
 * login_cannot_pass). */
static void warn_login_cannot_pass(int argc, char *argv[]) {
#ifdef HAVE_LIBWEBSOCKETS
    login_args_t given;

    read_login_args(argc, argv, &given);
    if (given.remote && !given.tcp && given.user != NULL && given.password != NULL &&
            strchr(given.user, ':') != NULL &&
            (strchr(given.user, '&') != NULL || strchr(given.password, '&') != NULL))
        fprintf(stderr, "WARNING: the Kismet user name holds ':' and the login '&': Kismet reads "
                "a user name in an Authorization header only up to its first ':', and cuts a "
                "login in the websocket's address at every '&' (after decoding it), so this one "
                "cannot log in either way; use an API key (--apikey or KISMET_CAP_APIKEY) "
                "instead of the login\n");
#endif
}

/* Nothing the helper does needs a capability.  It opens serial ports: run by root
 * or installed setuid root, as the owner of nodes that root owns, which the boards'
 * are (root:dialout on the host, made by root in a container); run by a user, as a
 * member of the port's group.  It reads sysfs and /proc/locks, which anyone may.  It
 * talks to Kismet over the pipes Kismet gives it or, with --connect, over a socket
 * of its own; --autodetect listens on UDP 2501, not a privileged port.  So it drops
 * them all, first thing: no command line, no --list, no announcement --autodetect
 * reads, no reply from a server and nothing a radio sent is then ever handled with
 * privileges, and the process is still a single thread, which matters because
 * capabilities are per thread.  And it takes no new ones: a process of uid 0 would
 * get the whole set back by running a program, which PR_SET_NO_NEW_PRIVS prevents.
 *
 * What root gives up is its override of file permissions.  Run by root, it can no
 * longer open a port node that it does not own and whose group it is not in, which
 * was so before too, as cf_drop_most_caps() dropped the override as well, nor read
 * an --ssl-certificate file that it does not own and others may not read, which it
 * used to read before dropping anything.  Installed setuid root and run by a user,
 * it used to keep every capability, as cf_drop_most_caps() dropped nothing for it,
 * and now has none either.  It still opens the nodes that root owns, the boards'
 * among them, and a port of the user's own, such as a pseudo-terminal from
 * tools/fake_board.py or socat (user:tty 0620), which serial_open opens with the
 * user's file permissions (open_port); but no longer a node of another user's, nor
 * an --ssl-certificate file that only the user may read.  make install, with the
 * user in the ports' group (dialout), needs no setuid at all.
 *
 * This replaces Kismet's cf_drop_most_caps(), which keeps NET_ADMIN and NET_RAW,
 * of no use here, fails where they are not to be had (Docker does not give a
 * container NET_ADMIN), and reports that through Kismet before the channel to
 * Kismet exists, which crashes the helper (SIGSEGV) before it opens a board.  It
 * drops nothing unless the real uid is 0, either, so a helper installed setuid root
 * kept every capability.  With it gone, the Docker image needs no NET_ADMIN for this
 * helper; Kismet's other helpers still call cf_drop_most_caps(), which is why
 * docker/kismet_site.conf masks their source types.  This one says on stderr what
 * went wrong, and only there; dropping to none is always allowed, so nothing
 * should.  Built without libcap (HAVE_CAPABILITY) it cannot drop anything nor set
 * no_new_privs, and keeps what it was given.  cf_jail_filesystem(), which Kismet
 * has switched off, is not called either: it would need CAP_SYS_ADMIN. */
static void drop_capabilities(void) {
#ifdef HAVE_CAPABILITY
    cap_t none = cap_init();

    if (none == NULL || cap_set_proc(none) < 0)
        fprintf(stderr, "WARNING: kismet_cap_esp32c5 could not drop its capabilities: %s\n",
                strerror(errno));
    if (none != NULL)
        cap_free(none);
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
        fprintf(stderr, "WARNING: kismet_cap_esp32c5 could not set no_new_privs: %s\n",
                strerror(errno));
#endif
}

/* The capture process of a remote helper, for end_on_signal */
static local_esp32c5_t *signal_local;

/* A remote helper ended by a signal takes its port out of exclusive mode first, as
 * serial_close does: the close that ending the process makes ends that mode only when
 * it is the tty's last, and the flock goes with the process anyway.  Then the signal
 * does what it would have done: SA_RESETHAND has put the default action back, and the
 * signal raised here, blocked while this runs, ends the process once it returns. */
static void end_on_signal(int sig) {
    int fd = signal_local->fd;

    if (fd >= 0)
        ioctl(fd, TIOCNXCL);
    raise(sig);
}

/* SIGTERM (kill, systemd, end_with_parent), SIGINT (Ctrl+C) and SIGHUP (a closed
 * terminal): the ways a remote helper is stopped.  Not for a local source, which
 * Kismet starts and stops itself.  A signal the helper was started with ignored
 * stays ignored: nohup ignores SIGHUP, and a shell without job control starts a
 * background command with SIGINT ignored, so that it outlives the terminal and the
 * Ctrl+C -- the handler would put the default action, the end, back. */
static void catch_end_signals(local_esp32c5_t *local) {
    static const int sigs[] = { SIGTERM, SIGINT, SIGHUP };
    struct sigaction sa, was;

    signal_local = local;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = end_on_signal;
    sa.sa_flags = SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        if (sigaction(sigs[i], NULL, &was) == 0 && was.sa_handler == SIG_IGN)
            continue;
        sigaction(sigs[i], &sa, NULL);
    }
}

#ifdef __linux__
/* The pid of the process that forked last, as its child sees it: the capture
 * process's parent, which end_with_parent checks getppid() against */
static pid_t forked_from;

static void note_fork(void) {
    forked_from = getpid();
}
#endif

/* With retry, a remote helper captures in a child the framework forks for each
 * connection (cf_handler_remote_capture); the parent only waits for it to end and
 * forks the next.  A signal that ends the parent -- kill, systemd stopping it --
 * would leave the child running on its own, holding the board, and the next helper
 * started for it would find it in use.  So the child gets SIGTERM when its parent
 * dies.  The parent may have died already, before the prctl, and then no signal
 * would come: getppid() is no longer the pid that forked it, and it ends at once.
 * Never for a local source: PR_SET_PDEATHSIG fires when the thread that forked the
 * process ends, and Kismet starts its helpers from any of its threads.  The kernel
 * clears the setting whenever the thread's credentials change, which open_port's
 * switch of the file system uid does, so open_port asks again after it. */
static void end_with_parent(void) {
#ifdef __linux__
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0) {
        fprintf(stderr, "WARNING: kismet_cap_esp32c5 could not arrange to end with its "
                "parent: %s\n", strerror(errno));
        return;
    }
    if (getppid() != forked_from)
        raise(SIGTERM);
#endif
}

int main(int argc, char *argv[]) {
    local_esp32c5_t local;
    char **opt_argv;
    int opt_argc;

    drop_capabilities();

    memset(&local, 0, sizeof(local));
    local.fd = -1;
    pthread_mutex_init(&local.lock, NULL);
    srandom(time(NULL) ^ getpid());

    kis_capture_handler_t *caph = cf_handler_init("esp32c5");
    if (caph == NULL) {
        fprintf(stderr, "FATAL: Could not allocate basic handler data, your system "
                "is very low on RAM or something is wrong.\n");
        return -1;
    }
    local.caph = caph;

    cf_handler_set_userdata(caph, &local);
    cf_handler_set_open_cb(caph, open_callback);
    cf_handler_set_probe_cb(caph, probe_callback);
    cf_handler_set_listdevices_cb(caph, list_callback);
    cf_handler_set_chantranslate_cb(caph, chantranslate_callback);
    cf_handler_set_chancontrol_cb(caph, chancontrol_callback);
    cf_handler_set_capture_cb(caph, capture_thread);

    /* Set a channel hop spacing of 4 to get the most out of 2.4 overlap;
     * it does nothing and hurts nothing on 5ghz */
    cf_handler_set_hop_shuffle_spacing(caph, 4);

    /* the copy, if one is made, lives as long as the process */
    opt_argv = login_from_env(argc, argv, &opt_argc);
    warn_login_cannot_pass(opt_argc, opt_argv);

    /* 0 after --version; 1 for a local source (Kismet's --in-fd and --out-fd), 2 for
     * remote capture; below 0 for --help and for options that are wrong or missing,
     * which get the framework's usage (its remote capture options; this helper adds
     * none) and exit status 255.  --list never returns: the framework prints the
     * boards on stderr and exits with 2. */
    int r = cf_handler_parse_opts(caph, opt_argc, opt_argv);
    if (r == 0) {
        return 0;
    } else if (r < 0) {
        cf_print_help(caph, argv[0]);
        return -1;
    }

#ifdef HAVE_LIBWEBSOCKETS
    /* libwebsockets logs its notices on stderr by default: its version, and every
     * connection it opens and closes.  Its warnings and errors still come through. */
    lws_set_log_level(LLL_ERR | LLL_WARN, NULL);
#endif

#ifdef __linux__
    pthread_atfork(note_fork, NULL, NULL);
#endif

    /* No cf_jail_filesystem() or cf_drop_most_caps(): see drop_capabilities */
    cf_handler_remote_capture(caph);

    /* Remote capture, in the process that captures: with retry, the framework's child
     * for this connection, whose monitor_pid is the 0 its fork returned.  (--daemonize
     * forks as well, but its parent exits at once, and that fork leaves monitor_pid
     * alone.) */
    if (!caph->use_ipc) {
        catch_end_signals(&local);
        if (caph->remote_retry && caph->monitor_pid == 0)
            end_with_parent();
    }

    cf_handler_loop(caph);
    cf_handler_shutdown(caph);

    return 0;
}
