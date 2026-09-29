/* Offline tests for kismet_cap_esp32c5: the stream parser and when it says
 * "capturing", the 802.15.4 and BTLE handling and every radio's signal block,
 * source names, channel= and BTLE channel sets, refused channels, the probe (a
 * remote helper refusing a port another process holds), --list, finding a board by
 * its MAC, the port lock and the tty's exclusive mode, the reason told to Kismet,
 * the websocket PING watchdog, the signals that end a remote helper (and the ones
 * it was started ignoring, which do not), its capture process ending with its
 * parent (setuid root too), the remote login (read as the framework reads it; the
 * framework's Authorization header, cookie, or for a user name with ':' the
 * percent-encoded URI; the warning for a login that cannot log in; a failed send that
 * ends the capture without a second spindown), the helper dropping its capabilities,
 * and, installed setuid root, still opening a port of the user's own.  No board and
 * no Kismet server needed, only a Kismet source tree patched by
 * kismet/add-to-kismet.sh and built.  The exclusive mode, and the capabilities as
 * root, in a container and setuid root, need root and a Kismet configured with
 * libcap; without them those checks print SKIP instead.
 *
 *     tests/c/run.sh [PATH_TO_KISMET_SOURCE]
 *
 * The helper's source is compiled in as it is.  The calls that would reach Kismet
 * (cf_send_data, cf_send_message, cf_send_error, cf_handler_spindown,
 * cf_handler_wait_ringbuffer) are renamed to the stubs below, which record what
 * they are given, and its main() is renamed to esp32c5_helper_main, which the
 * capability tests run in a child process.  The rest of the framework --
 * cf_find_flag, cf_handler_parse_opts and so on -- is the real one, from the tree's
 * libkismetdatasource.a.
 *
 * The streams are the ones tests/test_board.py gives board.py, fed the way the
 * capture thread reads them, in chunks of 1, 3, 7, 11, 64 and 4096 bytes and all
 * at once, plus what only the C helper does: nonces, frames that carry the whole
 * restart signature, 802.15.4 TAP, the BTLE CRC fix-up.
 *
 * The boards come from a sysfs tree the test makes up (the helper's sysfs_root and
 * dev_root point at it), never from the machine's own: whatever is plugged in here
 * changes nothing.  Its ports are pseudo-terminals; only the exclusive mode is tried
 * on a tty that is not one, a /dev/ttyS* with no hardware behind it (see
 * test_exclusive).  What the test makes lives in /tmp/esp32c5-test-XXXXXX, but for
 * one link in /tmp itself (test_setuid_open), and is removed again.  The processes
 * it starts -- another process holding a port's lock, a helper's capture process
 * and the parent it ends with -- end by themselves or are killed by their pid.
 *
 * Each check prints PASS or FAIL; the run ends with ALL OK and exit status 0, or
 * "<n> FAILED" and 1.  The wiki's Development-and-Testing page describes the tests
 * for users. */

#define main esp32c5_helper_main
#define cf_send_data stub_cf_send_data
#define cf_send_message stub_cf_send_message
#define cf_send_error stub_cf_send_error
#define cf_handler_spindown stub_cf_handler_spindown
#define cf_handler_wait_ringbuffer stub_cf_handler_wait_ringbuffer

#include "../../kismet/capture_esp32c5/capture_esp32c5.c"

#undef main
#undef cf_send_data
#undef cf_send_message
#undef cf_send_error
#undef cf_handler_spindown
#undef cf_handler_wait_ringbuffer

#include <ftw.h>
#include <grp.h>
#include <sys/wait.h>

#define NONCE "deadbeef"

static int failures;

static void check(bool ok, const char *fmt, ...) {
    va_list ap;

    printf(ok ? "PASS " : "FAIL ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    if (!ok)
        failures++;
}

/* ------------------------------------------------------------------------------
 * What the helper sends to Kismet
 * ---------------------------------------------------------------------------- */

typedef struct {
    uint32_t dlt, orig_len, len;
    struct timeval ts;
    uint8_t *data;
    bool has_signal;
    char channel[8];
    int32_t dbm;
    uint64_t freq_khz;
} packet_t;

/* What went as an ERROR frame, not a MESSAGE, in message_flags */
#define SENT_AS_ERROR 0x10000

static packet_t *pkts;
static size_t npkts, pkts_cap;
static char messages[64][STATUS_MAX];
static unsigned int message_flags[64];
static size_t nmessages;
/* cf_send_data fails (returns -1) while this is set */
static bool send_data_fails;

int stub_cf_send_data(kis_capture_handler_t *caph, const char *msg, unsigned int msg_type,
        struct cf_params_signal *signal, struct cf_params_gps *gps, struct timeval ts,
        uint32_t dlt, uint32_t original_sz, uint32_t packet_sz, uint8_t *pack) {
    packet_t *p;

    if (send_data_fails)
        return -1;
    if (npkts == pkts_cap) {
        pkts_cap = pkts_cap ? pkts_cap * 2 : 256;
        pkts = (packet_t *) realloc(pkts, sizeof(packet_t) * pkts_cap);
    }
    p = &pkts[npkts++];
    memset(p, 0, sizeof(*p));
    p->dlt = dlt;
    p->orig_len = original_sz;
    p->len = packet_sz;
    p->ts = ts;
    p->data = (uint8_t *) malloc(packet_sz ? packet_sz : 1);
    memcpy(p->data, pack, packet_sz);
    if (signal != NULL) {
        p->has_signal = true;
        snprintf(p->channel, sizeof(p->channel), "%s", signal->channel ? signal->channel : "");
        p->dbm = (int32_t) signal->signal_dbm;
        p->freq_khz = signal->freq_khz;
    }
    return 1;
}

static void note(const char *text, unsigned int flags) {
    if (nmessages < sizeof(messages) / sizeof(messages[0])) {
        message_flags[nmessages] = flags;
        snprintf(messages[nmessages++], STATUS_MAX, "%s", text);
    }
}

int stub_cf_send_message(kis_capture_handler_t *caph, const char *message, unsigned int flags) {
    note(message, flags);
    return 1;
}

int stub_cf_send_error(kis_capture_handler_t *caph, uint32_t in_seqno, const char *message) {
    note(message, SENT_AS_ERROR);
    return 1;
}

void stub_cf_handler_spindown(kis_capture_handler_t *caph) {
    caph->spindown = 1;
}

void stub_cf_handler_wait_ringbuffer(kis_capture_handler_t *caph) {
}

static size_t messages_with(const char *text) {
    size_t n = 0;
    for (size_t i = 0; i < nmessages; i++)
        n += strstr(messages[i], text) != NULL;
    return n;
}

/* The same, counting only those sent with these flags (SENT_AS_ERROR for an ERROR) */
static size_t messages_flagged(const char *text, unsigned int flags) {
    size_t n = 0;
    for (size_t i = 0; i < nmessages; i++)
        n += strstr(messages[i], text) != NULL && message_flags[i] == flags;
    return n;
}

/* ------------------------------------------------------------------------------
 * Streams
 * ---------------------------------------------------------------------------- */

typedef struct {
    uint8_t *p;
    size_t n, cap;
} bytes_t;

static void put(bytes_t *b, const void *data, size_t n) {
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2 + 64;
        b->p = (uint8_t *) realloc(b->p, b->cap);
    }
    memcpy(b->p + b->n, data, n);
    b->n += n;
}

static void put_str(bytes_t *b, const char *s) {
    put(b, s, strlen(s));
}

static void put_le16(bytes_t *b, uint16_t v) {
    uint8_t x[2] = { v & 0xFF, v >> 8 };
    put(b, x, 2);
}

static void put_le32(bytes_t *b, uint32_t v) {
    uint8_t x[4] = { v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24 };
    put(b, x, 4);
}

static void put_global(bytes_t *b, uint32_t linktype) {
    put_le32(b, PCAP_MAGIC);
    put_le16(b, 2);
    put_le16(b, 4);
    put_le32(b, 0);
    put_le32(b, 0);
    put_le32(b, 65535);
    put_le32(b, linktype);
}

/* "\n<<START>> <nonce>\n" as the firmware answers START, or its boot marker */
static void put_marker(bytes_t *b, const char *nonce) {
    put_str(b, "\n" START_MARKER);
    if (nonce != NULL) {
        put_str(b, " ");
        put_str(b, nonce);
    }
    put_str(b, "\n");
}

static void put_hdr(bytes_t *b, uint32_t sec, uint32_t usec, uint32_t incl, uint32_t orig) {
    put_le32(b, sec);
    put_le32(b, usec);
    put_le32(b, incl);
    put_le32(b, orig);
}

/* Record i as tests/test_board.py makes it: payload bytes (i + k) & 0xFF */
static size_t rec_size(int i) {
    return 40 + (i * 37) % 900;
}

static void put_rec_with(bytes_t *b, int i, const uint8_t *payload, size_t n) {
    put_hdr(b, 1700000000 + i, (i * 1237) % 1000000, n, n);
    put(b, payload, n);
}

static void put_rec_sized(bytes_t *b, int i, size_t n) {
    uint8_t *payload = (uint8_t *) malloc(n);
    for (size_t k = 0; k < n; k++)
        payload[k] = (i + k) & 0xFF;
    put_rec_with(b, i, payload, n);
    free(payload);
}

static void put_rec(bytes_t *b, int i) {
    put_rec_sized(b, i, rec_size(i));
}

static void put_recs(bytes_t *b, int from, int to) {
    for (int i = from; i < to; i++)
        put_rec(b, i);
}

/* The start of a synced stream: our marker and the header */
static void put_start(bytes_t *b, uint32_t linktype) {
    put_marker(b, NONCE);
    put_global(b, linktype);
}

static void bytes_free(bytes_t *b) {
    free(b->p);
    memset(b, 0, sizeof(*b));
}

/* ------------------------------------------------------------------------------
 * Feeding the parser the way the capture thread does
 * ---------------------------------------------------------------------------- */

static kis_capture_handler_t *caph;
static local_esp32c5_t *L;

static void reset(int mode) {
    for (size_t i = 0; i < npkts; i++)
        free(pkts[i].data);
    npkts = 0;
    nmessages = 0;
    memset(L, 0, sizeof(*L));
    L->caph = caph;
    L->fd = -1;
    pthread_mutex_init(&L->lock, NULL);
    L->mode = mode;
    L->dlt = mode_dlt(mode);
    L->name = (char *) "test";
    snprintf(L->nonce, sizeof(L->nonce), "%s", NONCE);
    caph->spindown = 0;
    /* status() passes a text on only when it differs from the last one: every test
     * starts after a text of its own */
    status(L, "-- reset --");
    nmessages = 0;
}

static size_t max_left;

static void feed(const uint8_t *s, size_t len, size_t chunk) {
    size_t off = 0;

    while (off < len) {
        size_t room = rx_room(L), n = chunk;
        if (n > len - off)
            n = len - off;
        if (n > room)
            n = room;
        memcpy(L->buf + L->buf_len, s + off, n);
        L->buf_len += n;
        off += n;
        consume(L);
        if (L->buf_len > max_left)
            max_left = L->buf_len;
    }
}

/* What was passed on, written back as PCAP records */
static void got_stream(bytes_t *g) {
    for (size_t i = 0; i < npkts; i++) {
        put_hdr(g, pkts[i].ts.tv_sec, pkts[i].ts.tv_usec, pkts[i].len, pkts[i].orig_len);
        put(g, pkts[i].data, pkts[i].len);
    }
}

static const size_t chunks[] = { 1, 3, 7, 11, 64, 4096, 0 };
#define NCHUNKS (sizeof(chunks) / sizeof(chunks[0]))

static size_t chunk_of(size_t c, const bytes_t *s) {
    return chunks[c] ? chunks[c] : s->n;
}

/* Every chunk size must pass on exactly `want` with `losses` losses of sync */
static void expect(const char *name, int mode, const bytes_t *s, const bytes_t *want,
        unsigned long losses) {
    for (size_t c = 0; c < NCHUNKS; c++) {
        bytes_t g = { 0 };
        reset(mode);
        feed(s->p, s->n, chunk_of(c, s));
        got_stream(&g);
        bool same = g.n == want->n && (g.n == 0 || memcmp(g.p, want->p, g.n) == 0);
        check(same && L->sync_losses == losses, "%s chunk=%zu (%zu records, %lu lost sync)",
                name, chunk_of(c, s), npkts, L->sync_losses);
        bytes_free(&g);
    }
}

/* A resync that may pass on a truncated record: what comes before and after it
 * must be right, and sync must have been lost */
static void expect_ends(const char *name, int mode, const bytes_t *s, const bytes_t *head,
        const bytes_t *tail) {
    for (size_t c = 0; c < NCHUNKS; c++) {
        bytes_t g = { 0 };
        reset(mode);
        feed(s->p, s->n, chunk_of(c, s));
        got_stream(&g);
        bool ok = g.n >= head->n + tail->n && memcmp(g.p, head->p, head->n) == 0 &&
            memcmp(g.p + g.n - tail->n, tail->p, tail->n) == 0 && L->sync_losses >= 1;
        check(ok, "%s chunk=%zu (%zu records, %lu lost sync)", name, chunk_of(c, s), npkts,
                L->sync_losses);
        bytes_free(&g);
    }
}

/* ------------------------------------------------------------------------------
 * Framing
 * ---------------------------------------------------------------------------- */

static const uint8_t magic8[8] = { 0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00 };

static void test_framing(void) {
    bytes_t s = { 0 }, e = { 0 }, head = { 0 }, tail = { 0 };
    uint8_t payload[64];

    /* test_board.py's marker-like payload: "<<START>>\n" before zeros */
    memset(payload, 0, sizeof(payload));
    memcpy(payload, "<<START>>\n", 10);

    put_str(&s, "ESP-ROM:esp32c5-eco2\r\nboot text\r\n");
    put_start(&s, 127);
    for (int i = 0; i < 60; i++) {
        if (i == 5) {
            put_rec_with(&s, 5, payload, sizeof(payload));
            put_rec_with(&e, 5, payload, sizeof(payload));
        } else {
            put_rec(&s, i);
            put_rec(&e, i);
        }
    }
    expect("plain marker", MODE_WIFI, &s, &e, 0);
    check(max_left <= 2 * (PCAP_REC_HDR_LEN + MAX_RECORD_LEN), "buffer stays within a kept and a partial record (%zu bytes)", max_left);
    bytes_free(&s);
    bytes_free(&e);

    put_str(&s, "boot\r\n\r\n" START_MARKER " " NONCE "\r\n");
    put_global(&s, 127);
    put_recs(&s, 0, 10);
    put_recs(&e, 0, 10);
    expect("CRLF marker", MODE_WIFI, &s, &e, 0);
    bytes_free(&s);

    put_recs(&s, 20, 30);
    put_marker(&s, NULL);
    put_global(&s, 127);
    put_recs(&s, 30, 40);
    put_marker(&s, "0badc0de");
    put_global(&s, 127);
    put_recs(&s, 40, 45);
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    expect("nonce skips stale markers", MODE_WIFI, &s, &e, 0);
    bytes_free(&s);
    bytes_free(&e);

    put_marker(&s, "0badc0de");
    put_global(&s, 127);
    put_recs(&s, 0, 3);
    expect("wrong nonce ignored", MODE_WIFI, &s, &e, 0);
    bytes_free(&s);

    put_marker(&s, NONCE "00");
    put_global(&s, 127);
    put_recs(&s, 0, 3);
    put_str(&s, "\n" START_MARKER " " NONCE "x1\r\n");
    put_global(&s, 127);
    put_recs(&s, 0, 3);
    put_start(&s, 127);
    put_recs(&s, 3, 6);
    put_recs(&e, 3, 6);
    expect("nonce that is a prefix of a longer one", MODE_WIFI, &s, &e, 0);
    bytes_free(&s);
    bytes_free(&e);

    /* A board that rebooted while its port stayed open cut record 10 short; the
     * new marker is inside what record 10 claims */
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    {
        bytes_t r10 = { 0 };
        put_rec(&r10, 10);
        put(&s, r10.p, 30);
        bytes_free(&r10);
    }
    put_str(&s, "ESP-ROM:esp32c5\r\nrst:0x15\r\n");
    put_start(&s, 127);
    put_recs(&s, 40, 50);
    put_recs(&head, 0, 10);
    put_recs(&tail, 40, 50);
    expect_ends("reboot mid-stream resyncs", MODE_WIFI, &s, &head, &tail);
    bytes_free(&s);

    /* the same without boot text */
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    {
        bytes_t r10 = { 0 };
        put_rec(&r10, 10);
        put(&s, r10.p, 30);
        bytes_free(&r10);
    }
    put_start(&s, 127);
    put_recs(&s, 40, 50);
    expect_ends("truncated record, then marker and header", MODE_WIFI, &s, &head, &tail);
    bytes_free(&s);

    /* the truncated record claims less than the boot text that follows: the
     * marker comes after the damaged header, where the scan finds it anyway */
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    put_hdr(&s, 1700000010, 5, 100, 100);
    put(&s, "0123456789abcd", 14);
    for (int i = 0; i < 20; i++)
        put_str(&s, "boot text line\r\n");
    put_start(&s, 127);
    put_recs(&s, 40, 50);
    expect_ends("truncated record, long boot text, then marker", MODE_WIFI, &s, &head, &tail);
    bytes_free(&s);

    /* a reset between records: the boot marker (no nonce) at a record boundary, and
     * the answer to the START that follows */
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    put_marker(&s, NULL);
    put_global(&s, 127);
    put_recs(&s, 30, 35);
    put_start(&s, 127);
    put_recs(&s, 40, 50);
    put_recs(&e, 0, 10);
    put_recs(&e, 40, 50);
    expect("boot marker at a record boundary", MODE_WIFI, &s, &e, 1);
    bytes_free(&s);

    /* the marker with our nonce at a record boundary: resyncs on it directly */
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    put_start(&s, 127);
    put_recs(&s, 40, 50);
    expect("marker at record boundary", MODE_WIFI, &s, &e, 1);
    bytes_free(&s);

    /* with a CRLF it is not a record header either */
    put_start(&s, 127);
    put_recs(&s, 0, 10);
    put_str(&s, "\r\n" START_MARKER " " NONCE "\r\n");
    put_global(&s, 127);
    put_recs(&s, 40, 50);
    expect("CRLF marker at record boundary", MODE_WIFI, &s, &e, 1);
    bytes_free(&s);
    bytes_free(&e);
    bytes_free(&head);
    bytes_free(&tail);

    /* damaged records of every kind, then the answer to the next START */
    static const struct {
        const char *what;
        uint32_t usec, incl, orig;
    } damaged[] = {
        { "incl_len 0xFFFF", 5, 0xFFFF, 0xFFFF },
        { "incl_len > orig_len", 5, 100, 99 },
        { "ts_usec >= 1000000", 1000000, 60, 60 },
        { "incl_len 0", 5, 0, 60 },
    };
    for (size_t d = 0; d < sizeof(damaged) / sizeof(damaged[0]); d++) {
        char name[96];
        put_start(&s, 127);
        put_recs(&s, 0, 10);
        put_hdr(&s, 1700000000, damaged[d].usec, damaged[d].incl, damaged[d].orig);
        put_recs(&s, 10, 15);
        put_start(&s, 127);
        put_recs(&s, 40, 50);
        put_recs(&e, 0, 10);
        put_recs(&e, 40, 50);
        snprintf(name, sizeof(name), "damaged record (%s) resyncs", damaged[d].what);
        expect(name, MODE_WIFI, &s, &e, 1);
        bytes_free(&s);
        bytes_free(&e);
    }

    /* a board still on another radio */
    put_start(&s, 283);
    put_recs(&s, 0, 5);
    expect("wrong link type is refused", MODE_WIFI, &s, &e, 1);
    bytes_free(&s);

    /* the largest records the helper takes, back to back with small ones */
    put_start(&s, 127);
    for (int i = 0; i < 12; i++) {
        put_rec_sized(&s, i, i % 2 ? MAX_RECORD_LEN : rec_size(i));
        put_rec_sized(&e, i, i % 2 ? MAX_RECORD_LEN : rec_size(i));
    }
    expect("16384 byte records", MODE_WIFI, &s, &e, 0);
    check(max_left <= 2 * (PCAP_REC_HDR_LEN + MAX_RECORD_LEN), "buffer stays within a kept and a partial record (%zu bytes)", max_left);
    bytes_free(&s);
    bytes_free(&e);

    /* random bytes */
    srandom(1);
    for (int i = 0; i < 200000; i++) {
        uint8_t x = random() & 0xFF;
        put(&s, &x, 1);
    }
    reset(MODE_WIFI);
    feed(s.p, s.n, 4096);
    check(npkts == 0, "random garbage yields nothing");
    bytes_free(&s);
}

/* ------------------------------------------------------------------------------
 * "capturing": said once the PCAP header has the radio's link type, not before
 * ---------------------------------------------------------------------------- */

static void test_capturing(void) {
    bytes_t s = { 0 };
    bool ok;

    /* a good stream says it once, however it is cut up, marker and header included */
    put_start(&s, 127);
    put_recs(&s, 0, 5);
    ok = true;
    for (size_t c = 0; c < NCHUNKS; c++) {
        reset(MODE_WIFI);
        feed(s.p, s.n, chunk_of(c, &s));
        if (messages_with("test capturing (wifi)") != 1 || nmessages != 1 || !capturing(L)) {
            printf("     chunk=%zu: %zu said, capturing %d\n", chunk_of(c, &s), nmessages, capturing(L));
            ok = false;
        }
    }
    check(ok, "\"test capturing (wifi)\" is said once, with the header, at every chunk size");
    bytes_free(&s);

    /* the answer to START, but not yet its header: synced, not capturing */
    put_marker(&s, NONCE);
    put(&s, pcap_magic_ver, 8);
    reset(MODE_WIFI);
    feed(s.p, s.n, 4096);
    check(L->synced && !capturing(L) && messages_with("capturing") == 0,
            "the marker alone is not capturing, and nothing is said");
    bytes_free(&s);

    /* Firmware without BTLE answers every START in Wi-Fi's link type (the sibling's
     * 1.0.0 and 1.1.0): five answers, five losses of sync, one message, and never
     * "capturing" -- which used to alternate with the loss, once a second */
    for (int i = 0; i < 5; i++) {
        put_start(&s, 127);
        put_recs(&s, i * 3, i * 3 + 3);
    }
    ok = true;
    for (size_t c = 0; c < NCHUNKS; c++) {
        reset(MODE_BLE);
        feed(s.p, s.n, chunk_of(c, &s));
        if (messages_with("capturing") != 0 || nmessages != 1 ||
                messages_with("test: lost sync (the board sends link type 127, not 256)") != 1 ||
                L->sync_losses != 5 || npkts != 0 || capturing(L)) {
            printf("     chunk=%zu: %zu said (%s), %lu lost sync, %zu packets\n", chunk_of(c, &s),
                    nmessages, nmessages ? messages[0] : "", L->sync_losses, npkts);
            ok = false;
        }
    }
    check(ok, "a board without the radio: lost sync said once, \"capturing\" never, at every chunk size");
    bytes_free(&s);

    /* and back: a damaged record loses sync, the next answer captures again */
    put_start(&s, 127);
    put_recs(&s, 0, 3);
    put_hdr(&s, 1700000000, 5, 0xFFFF, 0xFFFF);
    put_start(&s, 127);
    put_recs(&s, 3, 6);
    reset(MODE_WIFI);
    feed(s.p, s.n, 7);
    check(messages_with("test capturing (wifi)") == 2 && messages_with("lost sync (damaged PCAP record)") == 1 &&
            capturing(L) && npkts == 6, "a resync says capturing again (%zu said)", nmessages);
    bytes_free(&s);
}

/* ------------------------------------------------------------------------------
 * Frames that carry the restart signature: anyone on the air can send one
 * ---------------------------------------------------------------------------- */

static void test_injection(void) {
    bytes_t s = { 0 }, e = { 0 }, p = { 0 };
    int i = 100;

#define INJECT(build) do { \
        bytes_free(&p); \
        build; \
        put_rec_with(&s, i, p.p, p.n); \
        put_rec_with(&e, i, p.p, p.n); \
        i++; \
    } while (0)

    put_start(&s, 127);
    put_recs(&s, 0, 10);
    put_recs(&e, 0, 10);

    /* the signature from the finding: an SSID of "<<START>>\n" and the magic */
    INJECT({ put_str(&p, "\x80\x00ssid:"); put_str(&p, START_MARKER "\n"); put(&p, magic8, 8); put_str(&p, "tail"); });
    put_recs(&s, 10, 12);
    put_recs(&e, 10, 12);
    /* the payload is exactly a stream start with a whole global header */
    INJECT({ put_marker(&p, NULL); put_global(&p, 127); });
    /* with a nonce, CRLF, and at the very end of the payload */
    INJECT({ put_str(&p, "xx"); put_str(&p, START_MARKER " 0badc0de\r\n"); put(&p, magic8, 8); });
    /* with our own nonce (which no transmitter can know), a header and a record */
    INJECT({ put_start(&p, 127); put_hdr(&p, 1, 2, 20, 20); put_str(&p, "01234567890123456789"); });
    /* a payload that ends in the middle of the marker */
    INJECT({ put_str(&p, "abc\n" START_MARKER); });
    /* one claiming a record far longer than anything that follows */
    INJECT({ put_start(&p, 127); put_hdr(&p, 1, 2, 16000, 16000); });
    put_recs(&s, 12, 20);
    put_recs(&e, 12, 20);
    /* and as the last record, with nothing after it: it must not be held back */
    INJECT({ put_str(&p, START_MARKER "\n"); put(&p, magic8, 8); put_global(&p, 127); });
    expect("payloads holding the restart signature all come through", MODE_WIFI, &s, &e, 0);

    /* a damaged header after such a record: the signature in it is a candidate
     * now, but it has no nonce of ours, so the scan goes on to the real answer */
    put_hdr(&s, 1700000000, 5, 0xFFFF, 0xFFFF);
    put_recs(&s, 30, 33);
    put_start(&s, 127);
    put_recs(&s, 40, 45);
    put_recs(&e, 40, 45);
    expect("damaged header after a signature payload", MODE_WIFI, &s, &e, 1);
#undef INJECT

    bytes_free(&s);
    bytes_free(&e);
    bytes_free(&p);

    /* The same in 802.15.4 and BTLE: the check is in the framing, before the radios */
    uint8_t tap[48] = { 0, 0, 48, 0,
        0, 0, 1, 0, 0, 0, 0, 0,                         /* FCS type: none */
        1, 0, 4, 0, 0, 0, 0x5C, 0xC2,                   /* RSS -55.0 dBm */
        3, 0, 3, 0, 15, 0, 0, 0,                        /* channel 15, page 0 */
        10, 0, 1, 0, 200, 0, 0, 0,                      /* LQI */
        5, 0, 8, 0, 1, 2, 3, 4, 5, 6, 7, 8 };           /* start of frame */
    put_start(&s, 283);
    for (int k = 0; k < 6; k++) {
        bytes_t f = { 0 };
        put(&f, tap, sizeof(tap));
        put_str(&f, "\x41\x88\x01\x34\x12\xff\xff\x01\x10");
        if (k % 2)
            put_str(&f, "\n" START_MARKER "\n");
        else
            put_str(&f, "plain payload");
        if (k % 2)
            put(&f, magic8, 8);
        put_rec_with(&s, k, f.p, f.n);
        bytes_free(&f);
    }
    reset(MODE_154);
    feed(s.p, s.n, 7);
    check(npkts == 6 && L->sync_losses == 0, "802.15.4 payloads holding the signature come through (%zu)", npkts);
    bytes_free(&s);
}

/* ------------------------------------------------------------------------------
 * 802.15.4: TAP header off, channel and signal into the signal block
 * ---------------------------------------------------------------------------- */

static void put_tap_frame(bytes_t *b, int i, bool with_channel) {
    bytes_t f = { 0 };
    float rss = -55.4f;
    uint32_t bits;

    memcpy(&bits, &rss, 4);
    put(&f, "\x00\x00", 2);
    put_le16(&f, with_channel ? 48 : 40);
    put_le16(&f, 0); put_le16(&f, 1); put_le32(&f, 0);           /* FCS type */
    put_le16(&f, 1); put_le16(&f, 4); put_le32(&f, bits);        /* RSS */
    if (with_channel) {
        put_le16(&f, 3); put_le16(&f, 3); put_le16(&f, 25); put_le16(&f, 0);
    }
    put_le16(&f, 10); put_le16(&f, 1); put_le32(&f, 200);        /* LQI */
    put_le16(&f, 5); put_le16(&f, 8); put_le32(&f, 1); put_le32(&f, 0);
    put_str(&f, "\x41\x88\x07\x34\x12\xff\xff\x01\x25" "esp32c5 node");
    put_rec_with(b, i, f.p, f.n);
    bytes_free(&f);
}

static void test_154(void) {
    bytes_t s = { 0 };

    put_start(&s, 283);
    put_tap_frame(&s, 0, true);
    put_tap_frame(&s, 1, false);
    put_tap_frame(&s, 2, true);
    reset(MODE_154);
    feed(s.p, s.n, 3);
    check(npkts == 2 && L->dropped_154 == 1, "a TAP header without a channel is dropped, the rest pass (%zu, %lu dropped)", npkts, L->dropped_154);
    check(npkts >= 1 && pkts[0].dlt == LINKTYPE_IEEE802_15_4_NOFCS && pkts[0].len == 21 &&
            memcmp(pkts[0].data, "\x41\x88\x07", 3) == 0, "802.15.4 goes as the bare MAC frame, without FCS");
    check(npkts >= 1 && pkts[0].has_signal && strcmp(pkts[0].channel, "25") == 0 && pkts[0].dbm == -55,
            "channel and signal come out of the TAP header (%s, %d dBm)", npkts ? pkts[0].channel : "", npkts ? pkts[0].dbm : 0);
    check(npkts == 2 && pkts[0].freq_khz == 2475000 && pkts[1].freq_khz == 2475000,
            "and the frequency of channel 25, 2475000 kHz (%llu)", npkts ? (unsigned long long) pkts[0].freq_khz : 0ULL);
    bytes_free(&s);
}

/* ------------------------------------------------------------------------------
 * Wi-Fi: the frequency out of the radiotap header
 * ---------------------------------------------------------------------------- */

/* A radiotap header as the firmware and tools/fake_board.py write it: Flags, Channel,
 * signal and noise, 16 bytes */
static void put_radiotap(bytes_t *b, uint16_t mhz) {
    put(b, "\x00\x00", 2);
    put_le16(b, 16);
    put_le32(b, (1 << 1) | (1 << 3) | (1 << 5) | (1 << 6));
    put(b, "\x00\x00", 2);                  /* Flags, and a byte to align Channel */
    put_le16(b, mhz);
    put_le16(b, mhz < 3000 ? 0x00A0 : 0x0140);
    put(b, "\xd8\xa1", 2);                  /* -40 dBm, -95 dBm */
}

static void test_wifi_freq(void) {
    bytes_t s = { 0 }, f = { 0 }, x = { 0 };

    put_start(&s, 127);
    put_radiotap(&f, 2437);                 /* channel 6 */
    put_str(&f, "\x80\x00 a beacon");
    put_rec_with(&s, 0, f.p, f.n);
    bytes_free(&f);
    put_radiotap(&f, 5180);                 /* channel 36 */
    put_str(&f, "\x80\x00 a beacon");
    put_rec_with(&s, 1, f.p, f.n);
    put_rec_with(&s, 2, (const uint8_t *) "\x01\x02 no radiotap here", 20);
    reset(MODE_WIFI);
    feed(s.p, s.n, 11);
    check(npkts == 3 && pkts[0].has_signal && pkts[0].freq_khz == 2437000 && pkts[0].channel[0] == '\0' &&
            pkts[0].dbm == 0 && pkts[1].freq_khz == 5180000,
            "Wi-Fi: the signal block has the radiotap header's frequency, and nothing else (%llu, %llu)",
            npkts > 1 ? (unsigned long long) pkts[0].freq_khz : 0ULL, npkts > 1 ? (unsigned long long) pkts[1].freq_khz : 0ULL);
    check(npkts == 3 && !pkts[2].has_signal && pkts[2].len == 20, "no signal block for a record without a radiotap header");

    /* TSFT, Flags, Rate, Channel and a second presence word: Channel at 26 */
    put(&x, "\x00\x00", 2);
    put_le16(&x, 30);
    put_le32(&x, (1u << 0) | (1u << 1) | (1u << 2) | (1u << 3) | (1u << 31));
    put_le32(&x, 0);
    put_le32(&x, 0);                        /* up to 16, where TSFT is aligned */
    put(&x, "\x01\x02\x03\x04\x05\x06\x07\x08", 8);
    put(&x, "\x10\x0c", 2);                 /* Flags, Rate */
    put_le16(&x, 5745);
    put_le16(&x, 0x0140);
    check(radiotap_freq_khz(x.p, x.n) == 5745000, "TSFT, Flags, Rate and a second presence word are stepped over");
    check(radiotap_freq_khz(x.p, x.n - 2) == 0, "a header longer than the record gives no frequency");
    x.p[4] &= ~(1u << 3);
    check(radiotap_freq_khz(x.p, x.n) == 0, "nor one without a Channel field");
    bytes_free(&s);
    bytes_free(&f);
    bytes_free(&x);
}

/* ------------------------------------------------------------------------------
 * BTLE
 * ---------------------------------------------------------------------------- */

/* ADV_IND from a random address, flags and the short name "ESP".  Its CRC, f1 c0
 * 26, is the one Wireshark's btle dissector accepts for this PDU. */
static const uint8_t adv_pdu[] = { 0x40, 0x0e, 0x11, 0x22, 0x33, 0x44, 0x55, 0xc6,
    0x02, 0x01, 0x06, 0x04, 0x09, 0x45, 0x53, 0x50 };
static const uint8_t adv_crc[3] = { 0xf1, 0xc0, 0x26 };

static void btle_record(bytes_t *b, uint16_t flags, const uint8_t *crc) {
    put(b, "\x00\xc4\x00\x00", 4);          /* RF channel 0 (37), -60 dBm */
    put_le32(b, 0x8E89BED6);
    put_le16(b, flags);
    put_le32(b, 0x8E89BED6);
    put(b, adv_pdu, sizeof(adv_pdu));
    put(b, crc, 3);
}

static void test_btle(void) {
    static const uint8_t zero[3] = { 0, 0, 0 }, wrong[3] = { 1, 2, 3 };
    bytes_t s = { 0 }, now = { 0 }, old = { 0 }, bad = { 0 };
    uint32_t crc = btle_adv_crc(adv_pdu, sizeof(adv_pdu));

    check((crc & 0xFF) == adv_crc[0] && ((crc >> 8) & 0xFF) == adv_crc[1] && (crc >> 16) == adv_crc[2],
            "BTLE advertising CRC matches the known one (%06x)", crc);

    btle_record(&now, 0x0C13, adv_crc);         /* this firmware */
    btle_record(&old, 0x0013, zero);            /* older firmware: no CRC flags, CRC zeroed */
    btle_record(&bad, 0x0413, wrong);           /* checked, and failed */

    put_start(&s, 256);
    put_rec_with(&s, 0, now.p, now.n);
    put_rec_with(&s, 1, old.p, old.n);
    put_rec_with(&s, 2, old.p, old.n);
    put_rec_with(&s, 3, bad.p, bad.n);
    put_rec_with(&s, 4, (const uint8_t *) "0123456789abcdef", 16);    /* too short */
    reset(MODE_BLE);
    feed(s.p, s.n, 11);
    check(npkts == 4 && L->dropped_btle == 1, "BTLE records pass, the short one is dropped (%zu, %lu dropped)", npkts, L->dropped_btle);
    check(npkts == 4 && pkts[0].dlt == LINKTYPE_BLUETOOTH_LE_LL_WITH_PHDR && pkts[0].len == now.n &&
            memcmp(pkts[0].data, now.p, now.n) == 0, "a record with CRC flags goes unchanged");
    check(npkts == 4 && pkts[1].len == now.n && memcmp(pkts[1].data, now.p, now.n) == 0 &&
            memcmp(pkts[2].data, now.p, now.n) == 0,
            "older firmware's record gets the CRC and flags this firmware sends");
    check(messages_with("CRC checked") == 1, "the fix-up is said once (%zu)", messages_with("CRC checked"));
    check(npkts == 4 && pkts[3].len == bad.n && memcmp(pkts[3].data, bad.p, bad.n) == 0,
            "a record checked and failed is left alone");
    {
        bool all = npkts == 4;
        for (size_t i = 0; i < npkts; i++)
            all = all && pkts[i].has_signal && pkts[i].freq_khz == 2402000 && pkts[i].channel[0] == '\0' &&
                pkts[i].dbm == 0;
        check(all, "every BTLE packet's signal block has 2402000 kHz, channel 37's, and nothing else");
    }

    bytes_free(&s);
    bytes_free(&now);
    bytes_free(&old);
    bytes_free(&bad);
}

/* ------------------------------------------------------------------------------
 * Source definitions: the radio and the port from the name
 * ---------------------------------------------------------------------------- */

/* parse_definition on a definition; *device and *uuid are the caller's to free */
static int parse(const char *definition, char *msg, int *mode, unsigned int *channel,
        char **device, char *mac, char **uuid) {
    char def[256], *interface = NULL;
    cf_params_interface_t *iface = cf_params_interface_new();
    int r;

    snprintf(def, sizeof(def), "%s", definition);
    msg[0] = mac[0] = '\0';
    *device = *uuid = NULL;
    r = parse_definition(def, msg, mode, channel, &interface, device, mac, uuid, iface);
    free(interface);
    cf_params_interface_free(iface);
    return r;
}

static void test_definitions(void) {
    static const struct {
        const char *definition;
        int ret, mode;
        const char *device;
    } cases[] = {
        { "esp32c5-ttyACM0", 1, MODE_WIFI, "/dev/ttyACM0" },
        { "esp32c5zigbee-ttyACM0", 1, MODE_154, "/dev/ttyACM0" },
        { "esp32c5btle-ttyACM0", 1, MODE_BLE, "/dev/ttyACM0" },
        { "esp32c5-ttyACM0:mode=btle", 1, MODE_BLE, "/dev/ttyACM0" },
        { "esp32c5zigbee-ttyACM0:mode=wifi", 1, MODE_WIFI, "/dev/ttyACM0" },
        { "esp32c5ble-ttyUSB1", 1, MODE_BLE, "/dev/ttyUSB1" },
        { "esp32c5thread-ttyACM2", 1, MODE_154, "/dev/ttyACM2" },
        { "esp32c5802154-ttyACM2", 1, MODE_154, "/dev/ttyACM2" },
        /* the serial port names of macOS and the BSDs */
        { "esp32c5-cu.usbmodem1101", 1, MODE_WIFI, "/dev/cu.usbmodem1101" },
        { "esp32c5-cuaU0", 1, MODE_WIFI, "/dev/cuaU0" },
        { "esp32c5zigbee-dtyU0", 1, MODE_154, "/dev/dtyU0" },
        { "esp32c5-pts/7", 1, MODE_WIFI, "/dev/pts/7" },
        /* other names are only names, whatever /dev holds by them: the board is
         * looked for, and there is none in this test's sysfs */
        { "esp32c5zigbee-null", NO_BOARD_NOW, MODE_154, NULL },
        { "esp32c5-serial1", NO_BOARD_NOW, MODE_WIFI, NULL },
        { "esp32c5-watchdog", NO_BOARD_NOW, MODE_WIFI, NULL },
        { "esp32c5-pts/../watchdog", NO_BOARD_NOW, MODE_WIFI, NULL },
        { "esp32c5-kitchen:device=/dev/ttyACM3", 1, MODE_WIFI, "/dev/ttyACM3" },
        { "esp32c5btle:device=/dev/ttyACM3", 1, MODE_BLE, "/dev/ttyACM3" },
        { "esp32c5-ttyACM0:mode=lte", -1, -1, NULL },
        { "esp32c5-ttyACM0:channel=15", -1, MODE_WIFI, NULL },
        { "wlan0", 0, 0, NULL },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        char msg[STATUS_MAX], mac[13];
        char *device, *uuid;
        unsigned int channel;
        int mode = 0, r = parse(cases[i].definition, msg, &mode, &channel, &device, mac, &uuid);

        check(r == cases[i].ret && (r != 1 && r != NO_BOARD_NOW ? true : mode == cases[i].mode) &&
                (r != 1 || strcmp(device, cases[i].device) == 0),
                "%s -> %d %s %s %s", cases[i].definition, r, r == 1 || r == NO_BOARD_NOW ? mode_name(mode) : "",
                device ? device : "", r == 1 ? "" : msg);
        free(device);
        free(uuid);
    }

    /* no board plugged in: the messages must not claim what the USB ID cannot tell */
    {
        char msg[STATUS_MAX], mac[13];
        char *device, *uuid;
        unsigned int channel;
        int mode = 0, r = parse("esp32c5-kitchen", msg, &mode, &channel, &device, mac, &uuid);
        check(r == NO_BOARD_NOW && strstr(msg, "Espressif USB-Serial-JTAG") != NULL && strstr(msg, "ESP32-C5 board") == NULL,
                "no board: \"%s\"", msg);
        r = parse("esp32c5zigbee", msg, &mode, &channel, &device, mac, &uuid);
        check(r == NO_BOARD_NOW && mode == MODE_154, "esp32c5zigbee alone is 802.15.4 and looks for its board");
    }

    cf_params_interface_t *iface = cf_params_interface_new();
    fill_channels(iface, MODE_WIFI);
    check(iface->channels_len == 42, "42 Wi-Fi channels offered (%zu)", iface->channels_len);
    check(strcmp(make_hardware("3844BEBFC910"), "Espressif USB-Serial-JTAG (38:44:BE:BF:C9:10)") == 0,
            "hardware names the USB device, not the chip");
}

/* ------------------------------------------------------------------------------
 * A made-up sysfs: boards, --list, the port lock, finding a board by its MAC
 * ---------------------------------------------------------------------------- */

static char tree[64];           /* everything the test makes up lives in here */
static char empty_sysfs[128];   /* a sysfs with no tty in it: no board plugged in */

static void make_dirs(const char *path) {
    char p[PATH_MAX];

    snprintf(p, sizeof(p), "%s", path);
    for (char *s = p + 1; *s; s++) {
        if (*s == '/') {
            *s = '\0';
            mkdir(p, 0755);
            *s = '/';
        }
    }
    mkdir(p, 0755);
}

static void put_file(const char *dir, const char *name, const char *text) {
    char p[PATH_MAX];
    FILE *f;

    snprintf(p, sizeof(p), "%s/%s", dir, name);
    if ((f = fopen(p, "w")) != NULL) {
        fprintf(f, "%s\n", text);
        fclose(f);
    }
}

/* A USB device and the tty on its interface 1.0, the way sysfs shows them:
 * class/tty/<tty>/device links to the interface, whose parent has the IDs */
static void fake_usb_tty(const char *root, const char *tty, const char *usb, const char *vid,
        const char *pid, const char *serial) {
    char dev[PATH_MAX], iface[PATH_MAX + 8], ttydir[PATH_MAX], link[PATH_MAX + 8];

    snprintf(dev, sizeof(dev), "%s/devices/%s", root, usb);
    snprintf(iface, sizeof(iface), "%s/1.0", dev);
    make_dirs(iface);
    put_file(dev, "idVendor", vid);
    put_file(dev, "idProduct", pid);
    put_file(dev, "serial", serial);
    snprintf(ttydir, sizeof(ttydir), "%s/class/tty/%s", root, tty);
    make_dirs(ttydir);
    snprintf(link, sizeof(link), "%s/device", ttydir);
    if (symlink(iface, link) < 0)
        perror(link);
}

/* dev/char/<major>:<minor> for a device node, linking to class/tty/<tty> */
static void fake_dev_char(const char *root, const char *node, const char *tty) {
    char target[PATH_MAX], link[PATH_MAX];
    struct stat st;

    if (stat(node, &st) < 0)
        return;
    snprintf(target, sizeof(target), "%s/class/tty/%s", root, tty);
    snprintf(link, sizeof(link), "%s/dev/char/%u:%u", root, (unsigned int) major(st.st_rdev),
            (unsigned int) minor(st.st_rdev));
    if (symlink(target, link) < 0)
        perror(link);
}

static int rm_one(const char *path, const struct stat *st, int flag, struct FTW *where) {
    remove(path);
    return 0;
}

static bool only_name_chars(const char *s) {
    for (; *s; s++)
        if (!isalnum((unsigned char) *s) && *s != '-')
            return false;
    return true;
}

static void free_list(cf_params_list_interface_t **list, int n) {
    for (int i = 0; i < n; i++) {
        free(list[i]->interface);
        free(list[i]->flags);
        free(list[i]->hardware);
        free(list[i]);
    }
    free(list);
}

/* Another process holding the flock on path, as a capture from another helper does:
 * a child that opens and locks it, then waits to be killed.  Its pid, or -1. */
static pid_t hold_lock(const char *path) {
    int ready[2];
    pid_t pid;
    char c = 0;

    if (pipe(ready) < 0)
        return -1;
    fflush(stdout);
    if ((pid = fork()) == 0) {
        int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
        c = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0;
        if (write(ready[1], &c, 1) < 0)
            _exit(1);
        for (;;)
            pause();
    }
    close(ready[1]);
    if (pid < 0 || read(ready[0], &c, 1) != 1 || !c) {
        if (pid > 0) {
            kill(pid, SIGKILL);
            waitpid(pid, NULL, 0);
        }
        pid = -1;
    }
    close(ready[0]);
    return pid;
}

static void release_lock(pid_t pid) {
    if (pid > 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
    }
}

/* --list as Kismet gets it; the names one by one, joined by spaces */
static int list_names(char *names, size_t names_sz) {
    cf_params_list_interface_t **list = NULL;
    char msg[STATUS_MAX];
    int n = list_callback(caph, 1, msg, &list);

    names[0] = '\0';
    for (int i = 0; i < n; i++)
        snprintf(names + strlen(names), names_sz - strlen(names), "%s%s", i ? " " : "",
                list[i]->interface);
    if (n > 0)
        free_list(list, n);
    else if (list != NULL)
        n = -100;   /* nothing listed, and yet an array left behind */
    return n;
}

static void test_sysfs(void) {
    char root[128], devs[160], node[PATH_MAX], pts[2][64];
    char msg[STATUS_MAX], names[512], mac[13], want[PATH_MAX];
    char *device, *uuid, **ttys;
    unsigned int channel;
    int master[2], n, mode;
    static const char *modes[] = { "wifi", "zigbee", "btle" };
    static const char *macs[] = { "3844BEBFC910", "AABBCCDDEEFF" };

    snprintf(root, sizeof(root), "%s/sys", tree);
    snprintf(devs, sizeof(devs), "%s/dev", tree);
    make_dirs(devs);
    for (int i = 0; i < 2; i++) {
        master[i] = posix_openpt(O_RDWR | O_NOCTTY);
        if (master[i] < 0 || grantpt(master[i]) < 0 || unlockpt(master[i]) < 0) {
            check(false, "two pseudo-terminals for ports");
            return;
        }
        snprintf(pts[i], sizeof(pts[i]), "%s", ptsname(master[i]));
    }

    /* Two boards on ttyACM0 and ttyACM1, a USB serial adapter that is none, a
     * serial port without USB; the made-up dev/ttyACMn are links to the two
     * pseudo-terminals */
    fake_usb_tty(root, "ttyACM0", "1-1.2", "303a", "1001", "38:44:BE:BF:C9:10");
    fake_usb_tty(root, "ttyACM1", "1-1.3", "303a", "1001", "AA:BB:CC:DD:EE:FF");
    fake_usb_tty(root, "ttyUSB0", "1-1.4", "0403", "6001", "FT5X0B1Z");
    snprintf(node, sizeof(node), "%s/class/tty/ttyS0", root);
    make_dirs(node);
    snprintf(node, sizeof(node), "%s/dev/char", root);
    make_dirs(node);
    for (int i = 0; i < 2; i++) {
        char tty[16];
        snprintf(tty, sizeof(tty), "ttyACM%d", i);
        fake_dev_char(root, pts[i], tty);
        snprintf(node, sizeof(node), "%s/%s", devs, tty);
        if (symlink(pts[i], node) < 0)
            perror(node);
    }
    sysfs_root = root;
    dev_root = devs;

    n = find_boards(&ttys);
    check(n == 2 && strcmp(ttys[0], "ttyACM0") == 0 && strcmp(ttys[1], "ttyACM1") == 0,
            "the two boards found, in order, and nothing else (%d)", n);
    for (int i = 0; i < n; i++)
        free(ttys[i]);
    free(ttys);

    /* --list: each board once per radio, under names that give the radio and the port */
    {
        cf_params_list_interface_t **list = NULL;
        bool names_ok = true, back_ok = true;
        n = list_callback(caph, 1, msg, &list);
        check(n == 6, "--list offers each board three times (%d)", n);
        for (int i = 0; i < n && n == 6; i++) {
            char name[64], hw[64];
            snprintf(name, sizeof(name), "esp32c5%s-ttyACM%d", i % 3 == 0 ? "" : modes[i % 3], i / 3);
            snprintf(hw, sizeof(hw), "Espressif USB-Serial-JTAG (%s)",
                    i / 3 ? "AA:BB:CC:DD:EE:FF" : "38:44:BE:BF:C9:10");
            for (int j = 0; j < i; j++)
                names_ok = names_ok && strcmp(list[i]->interface, list[j]->interface) != 0;
            names_ok = names_ok && strcmp(list[i]->interface, name) == 0 &&
                only_name_chars(list[i]->interface) && strcmp(list[i]->hardware, hw) == 0;

            /* each name, used as a definition, is that radio on that port */
            int r = parse(list[i]->interface, msg, &mode, &channel, &device, mac, &uuid);
            snprintf(want, sizeof(want), "E5C5000%d-0000-0000-0000-%s", i % 3 + 1, macs[i / 3]);
            snprintf(node, sizeof(node), "%s/ttyACM%d", devs, i / 3);
            if (r != 1 || mode != i % 3 + 1 || strcmp(device, node) != 0 || strcmp(uuid, want) != 0) {
                printf("     %s -> %d %s %s %s\n", list[i]->interface, r, mode_name(mode),
                        device ? device : msg, uuid ? uuid : "");
                back_ok = false;
            }
            free(device);
            free(uuid);
        }
        check(names_ok, "the six names are distinct, the radio and the port in each, letters, digits and '-' only");
        check(back_ok, "each listed name opens that radio on that board, with the board's MAC in the UUID");
        if (n > 0)
            free_list(list, n);
    }

    /* A board in use -- by another process: a lock of the helper's own does not
     * count -- is not offered at all: none of its names could be opened */
    {
        char a[PATH_MAX], b[PATH_MAX];
        pid_t ha, hb;
        int fa;
        snprintf(a, sizeof(a), "%s/ttyACM0", devs);
        snprintf(b, sizeof(b), "%s/ttyACM1", devs);
        ha = hold_lock(a);
        n = list_names(names, sizeof(names));
        check(ha > 0 && n == 3 && strcmp(names, "esp32c5-ttyACM1 esp32c5zigbee-ttyACM1 esp32c5btle-ttyACM1") == 0,
                "a board whose port another process has locked is left out of --list, all three names (%s)", names);
        hb = hold_lock(b);
        n = list_names(names, sizeof(names));
        check(hb > 0 && n == 0, "every board in use: nothing listed, and no array left (%d)", n);
        release_lock(ha);
        release_lock(hb);
        check(list_names(names, sizeof(names)) == 6, "offered again once the ports are free");
        fa = serial_open(a, msg, sizeof(msg));
        check(fa >= 0 && !node_locked(a) && list_names(names, sizeof(names)) == 6,
                "a port this process holds itself is not in use by another");
        close(fa);
    }

    /* Which board is behind an open port, and where a board is by its MAC */
    {
        int fd = open(pts[0], O_RDWR | O_NOCTTY);
        check(fd_is_board(fd, "3844BEBFC910") == 1, "the port open on ttyACM0 is the board 38:44:BE:BF:C9:10");
        check(fd_is_board(fd, "AABBCCDDEEFF") == 0, "and not the board AA:BB:CC:DD:EE:FF");
        close(fd);
        check(fd_is_board(master[0], "3844BEBFC910") == 0, "a device sysfs does not know is no board");

        char path[PATH_MAX];
        snprintf(want, sizeof(want), "%s/ttyACM1", devs);
        check(find_tty_by_mac("AABBCCDDEEFF", path, sizeof(path)) && strcmp(path, want) == 0,
                "the board AA:BB:CC:DD:EE:FF is found on ttyACM1 by its MAC");
        check(!find_tty_by_mac("0123456789AB", path, sizeof(path)), "a MAC no board has is found nowhere");
    }

    /* A port that now holds another board: tty names swapped in a reboot */
    {
        char held[PATH_MAX], other[PATH_MAX];
        snprintf(held, sizeof(held), "%s/ttyACM0", devs);
        snprintf(other, sizeof(other), "%s/ttyACM1", devs);

        reset(MODE_WIFI);
        L->device = strdup(held);
        snprintf(L->mac, sizeof(L->mac), "AABBCCDDEEFF");
        bool r = reopen_port(L);
        check(r && L->fd >= 0 && fd_is_board(L->fd, "AABBCCDDEEFF") == 1,
                "reopen refuses ttyACM0, which holds another board, and opens the source's board on ttyACM1");
        check(strcmp(L->device, held) == 0, "the configured port stays the one tried first");
        check(messages_with("now holds another board") == 1 && messages_with("is on") == 1,
                "both are said (%zu, %zu)", messages_with("now holds another board"), messages_with("is on"));
        if (L->fd >= 0)
            close(L->fd);
        free(L->device);

        /* the board found by its MAC is busy: nothing is opened, and it is waited for */
        int busy = serial_open(other, msg, sizeof(msg));
        reset(MODE_WIFI);
        L->device = strdup(held);
        snprintf(L->mac, sizeof(L->mac), "AABBCCDDEEFF");
        r = reopen_port(L);
        check(!r && L->fd == -1 && messages_with("already in use") == 1,
                "a board found by its MAC in another source's hands is left alone");
        close(busy);
        free(L->device);

        /* the port holds the source's own board: opened at once, nothing said */
        reset(MODE_WIFI);
        L->device = strdup(held);
        snprintf(L->mac, sizeof(L->mac), "3844BEBFC910");
        r = reopen_port(L);
        check(r && L->fd >= 0 && nmessages == 0, "a port that holds the source's board is opened as it is");
        if (L->fd >= 0)
            close(L->fd);
        free(L->device);
        L->fd = -1;
    }

    /* A bare esp32c5 with two boards names them; with one, takes it */
    n = parse("esp32c5", msg, &mode, &channel, &device, mac, &uuid);
    check(n == NO_BOARD_NOW && strstr(msg, "2 Espressif USB-Serial-JTAG devices") != NULL &&
            strstr(msg, "esp32c5-ttyACM0") != NULL, "two boards: %s", msg);
    {
        char away[PATH_MAX], here[PATH_MAX];
        snprintf(here, sizeof(here), "%s/class/tty/ttyACM1", root);
        snprintf(away, sizeof(away), "%s/ttyACM1-unplugged", root);
        rename(here, away);
        n = parse("esp32c5:mode=btle", msg, &mode, &channel, &device, mac, &uuid);
        snprintf(node, sizeof(node), "%s/ttyACM0", devs);
        check(n == 1 && strcmp(device, node) == 0 && strcmp(uuid, "E5C50003-0000-0000-0000-3844BEBFC910") == 0,
                "one board: a bare esp32c5 is that one (%s, %s)", device ? device : msg, uuid ? uuid : "");
        free(device);
        free(uuid);
        rename(away, here);
    }

    /* no board, and no sysfs at all */
    sysfs_root = empty_sysfs;
    n = list_names(names, sizeof(names));
    check(n == 0, "no board: nothing listed, and no array left (%d)", n);
    snprintf(node, sizeof(node), "%s/none", tree);
    sysfs_root = node;
    n = list_names(names, sizeof(names));
    check(n == 0, "no sysfs: nothing listed (%d)", n);
    n = parse("esp32c5", msg, &mode, &channel, &device, mac, &uuid);
    check(n == NO_BOARD_NOW && strstr(msg, "needs Linux sysfs") != NULL, "no sysfs: %s", msg);

    sysfs_root = empty_sysfs;
    dev_root = "/dev";
    close(master[0]);
    close(master[1]);
}

/* ------------------------------------------------------------------------------
 * The probe: which definitions this helper claims
 * ---------------------------------------------------------------------------- */

static void test_probe(void) {
    static const struct {
        const char *definition;
        int ret;
        const char *msg;
    } cases[] = {
        /* ours, but no board to be found now: claimed, so that the open says why */
        { "esp32c5", 1, "no Espressif USB-Serial-JTAG device" },
        { "esp32c5-kitchen", 1, "no Espressif USB-Serial-JTAG device" },
        { "esp32c5zigbee", 1, "no Espressif USB-Serial-JTAG device" },
        { "esp32c5btle-serial1:channel=38", 1, "no Espressif USB-Serial-JTAG device" },
        { "esp32c5:mode=zigbee,channel=25", 1, "no Espressif USB-Serial-JTAG device" },
        /* a port by name: claimed as always, plugged in or not */
        { "esp32c5-ttyACM9", 1, "" },
        /* wrong in itself: no retry would help */
        { "esp32c5:mode=lte", -1, "mode must be" },
        { "esp32c5:channel=15", -1, "not a channel" },
        { "esp32c5btle-ttyACM0:channel=6", -1, "not a channel" },
        /* not a name of ours, and no board to be found: not claimed */
        { "esp32c5foo", NO_BOARD_NOW, "no Espressif USB-Serial-JTAG device" },
        { "wlan0", 0, "" },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        char def[128], msg[STATUS_MAX] = "", *uuid = NULL;
        cf_params_interface_t *iface = NULL;
        cf_params_spectrum_t *spectrum = NULL;
        int r;

        snprintf(def, sizeof(def), "%s", cases[i].definition);
        r = probe_callback(caph, 1, def, msg, &uuid, &iface, &spectrum);
        check(r == cases[i].ret && strstr(msg, cases[i].msg) != NULL, "probe %s -> %d (%s)",
                cases[i].definition, r, msg);
        free(uuid);
        cf_params_interface_free(iface);
    }

    /* A remote helper probes its own definition before it connects: there the
     * missing board stops it, with the reason */
    {
        char def[] = "esp32c5", msg[STATUS_MAX] = "", *uuid = NULL;
        cf_params_interface_t *iface = NULL;
        cf_params_spectrum_t *spectrum = NULL;
        caph->remote_host = strdup("localhost");
        int r = probe_callback(caph, 0, def, msg, &uuid, &iface, &spectrum);
        check(r <= 0 && strstr(msg, "no Espressif USB-Serial-JTAG device") != NULL,
                "remote: a board that cannot be found stops the helper (%d, %s)", r, msg);
        free(caph->remote_host);
        caph->remote_host = NULL;
        cf_params_interface_free(iface);
    }
}

/* A remote helper does not offer Kismet a port another process holds: offered, it
 * would take the running source of that board and radio over, as they share a uuid */
static int probe_as(const char *remote_host, int retry, const char *fmt, const char *pts, char *msg) {
    char def[128], *uuid = NULL;
    cf_params_interface_t *iface = NULL;
    cf_params_spectrum_t *spectrum = NULL;
    int r;

    caph->remote_host = remote_host ? strdup(remote_host) : NULL;
    caph->remote_retry = retry;
    snprintf(def, sizeof(def), fmt, pts);
    msg[0] = '\0';
    r = probe_callback(caph, 0, def, msg, &uuid, &iface, &spectrum);
    free(caph->remote_host);
    caph->remote_host = NULL;
    caph->remote_retry = 0;
    free(uuid);
    cf_params_interface_free(iface);
    return r;
}

static void test_remote_busy(void) {
    char msg[STATUS_MAX], want[STATUS_MAX], pts[64], path[80];
    int master = posix_openpt(O_RDWR | O_NOCTTY), fd, r;
    pid_t holder;

    if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
        check(false, "a pseudo-terminal for the port");
        return;
    }
    snprintf(pts, sizeof(pts), "%s", ptsname(master) + 5);
    snprintf(path, sizeof(path), "/dev/%s", pts);

    r = probe_as("localhost", 1, "esp32c5-%s:name=busy", pts, msg);
    check(r == 1, "remote: a free port is offered (%d %s)", r, msg);

    holder = hold_lock(path);
    r = probe_as("localhost", 1, "esp32c5-%s:name=busy", pts, msg);
    snprintf(want, sizeof(want), "busy: /dev/%s is already in use by another capture; not offering "
            "it to Kismet until it is free (looked at again every 5 seconds)", pts);
    check(holder > 0 && r <= 0 && strcmp(msg, want) == 0, "remote: a port another process holds is not offered: %s", msg);
    r = probe_as("localhost", 0, "esp32c5-%s", pts, msg);
    snprintf(want, sizeof(want), "esp32c5-%s: /dev/%s is already in use by another capture; not "
            "offering it to Kismet", pts, pts);
    check(r <= 0 && strcmp(msg, want) == 0, "... and with --disable-retry it says no more: %s", msg);
    r = probe_as(NULL, 0, "esp32c5-%s", pts, msg);
    check(r == 1, "a local source's probe still claims it: Kismet's open says it is in use");
    release_lock(holder);
    r = probe_as("localhost", 1, "esp32c5-%s", pts, msg);
    check(r == 1, "offered once it is free (%d %s)", r, msg);

    fd = serial_open(path, msg, sizeof(msg));
    r = probe_as("localhost", 1, "esp32c5-%s", pts, msg);
    check(fd >= 0 && r == 1, "a port the helper holds itself is not in use by another (%d %s)", r, msg);
    if (fd >= 0)
        serial_close(fd);
    close(master);
}

/* ------------------------------------------------------------------------------
 * open: channel=, the lock, the port name; channel sets
 * ---------------------------------------------------------------------------- */

static local_esp32c5_t *new_local(kis_capture_handler_t *h) {
    local_esp32c5_t *l = (local_esp32c5_t *) calloc(1, sizeof(local_esp32c5_t));
    l->caph = h;
    l->fd = -1;
    pthread_mutex_init(&l->lock, NULL);
    h->userdata = l;
    return l;
}

static int try_open(kis_capture_handler_t *h, const char *fmt, const char *pts, char *msg) {
    char def[256], *uuid = NULL;
    uint32_t dlt = 0;
    cf_params_interface_t *iface = NULL;
    cf_params_spectrum_t *spectrum = NULL;
    local_esp32c5_t *l = (local_esp32c5_t *) h->userdata;

    if (l->fd >= 0)
        close(l->fd);
    memset(l, 0, sizeof(*l));
    l->caph = h;
    l->fd = -1;
    pthread_mutex_init(&l->lock, NULL);
    msg[0] = '\0';
    snprintf(def, sizeof(def), fmt, pts);
    return open_callback(h, 1, def, msg, &dlt, &uuid, &iface, &spectrum) == 1 ?
        (int) (iface->capif != NULL && iface->chanset != NULL) : -1;
}

static void test_open(void) {
    kis_capture_handler_t *h1 = cf_handler_init("esp32c5"), *h2 = cf_handler_init("esp32c5");
    local_esp32c5_t *l1 = new_local(h1), *l2 = new_local(h2);
    char msg[STATUS_MAX], pts[64], capif[80];
    int master = posix_openpt(O_RDWR | O_NOCTTY);

    if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
        check(false, "a pseudo-terminal to open");
        return;
    }
    /* esp32c5-pts/3: pts/ is one of the names serial ports have under /dev */
    snprintf(pts, sizeof(pts), "%s", ptsname(master) + 5);
    snprintf(capif, sizeof(capif), "esp32c5-%s", pts);

    check(try_open(h1, "esp32c5-%s:channel=36", pts, msg) == 1 && l1->channel == 36 &&
            h1->channel != NULL && strcmp(h1->channel, "36") == 0,
            "channel=36 opens on 36, and the framework has the channel (%s)", msg);
    {
        char def[128], *uuid = NULL;
        uint32_t dlt;
        cf_params_interface_t *iface = NULL;
        cf_params_spectrum_t *spectrum = NULL;
        close(l1->fd);
        memset(l1, 0, sizeof(*l1));
        l1->caph = h1;
        l1->fd = -1;
        pthread_mutex_init(&l1->lock, NULL);
        snprintf(def, sizeof(def), "esp32c5-%s:channel=36", pts);
        open_callback(h1, 1, def, msg, &dlt, &uuid, &iface, &spectrum);
        check(iface->capif != NULL && strcmp(iface->capif, capif) == 0 && strcmp(iface->chanset, "36") == 0,
                "capif is the port as --list names it (%s), chanset 36", iface->capif ? iface->capif : "");
    }

    /* the board is held by h1 now */
    check(try_open(h2, "esp32c5-%s", pts, msg) == -1 && strstr(msg, "already in use") != NULL,
            "a second source on the same port fails: %s", msg);
    check(try_open(h2, "esp32c5-%s:channel=15", pts, msg) == -1 && strstr(msg, "not a channel") != NULL,
            "channel=15 in Wi-Fi mode is refused before the port is touched: %s", msg);
    check(try_open(h2, "esp32c5-%s:channel=abc", pts, msg) == -1 && strstr(msg, "not a channel") != NULL,
            "channel=abc is refused");
    check(try_open(h2, "esp32c5-%s:channel=+6", pts, msg) == -1 && strstr(msg, "not a channel") != NULL,
            "channel=+6 is refused");
    check(try_open(h2, "esp32c5btle-%s:channel=6", pts, msg) == -1 && strstr(msg, "not a channel") != NULL,
            "channel=6 in BTLE mode is refused");
    check(try_open(h2, "esp32c5zigbee-%s:channel=25", pts, msg) == -1 && strstr(msg, "already in use") != NULL,
            "channel=25 in 802.15.4 mode passes the check (and meets the lock)");

    /* channel sets through the framework's callbacks */
    local_channel_t *c40 = (local_channel_t *) chantranslate_callback(h1, "40");
    local_channel_t *c15 = (local_channel_t *) chantranslate_callback(h1, "15");
    char buf[64] = "";
    ssize_t n;
    msg[0] = '\0';
    check(chancontrol_callback(h1, 2, c40, msg) == 1 && strcmp(h1->channel, "40") == 0,
            "a hop to 40 is what the framework reports");
    usleep(50000);
    fcntl(master, F_SETFL, O_NONBLOCK);
    n = read(master, buf, sizeof(buf) - 1);
    buf[n > 0 ? n : 0] = '\0';
    check(strcmp(buf, "CHANNELS 40\n") == 0, "the board is told CHANNELS 40");
    nmessages = 0;
    check(chancontrol_callback(h1, 3, c15, msg) == 0 && h1->channel != NULL && strcmp(h1->channel, "40") == 0,
            "a refused channel leaves the framework a channel to report (%s)", msg);
    check(nmessages == 1 && message_flags[0] == MSGFLAG_ERROR && strcmp(messages[0], msg) == 0,
            "... and a refused set is told to Kismet as an error message, which it logs");
    nmessages = 0;
    check(chancontrol_callback(h1, 0, c15, msg) == 0 && nmessages == 0,
            "a refused hop is not: the framework drops the channel after a lap, and says so");
    check(chancontrol_callback(h1, 4, NULL, msg) == 0 && h1->channel != NULL,
            "an unparsable channel too");

    /* closing the port lets the next one in */
    close(l1->fd);
    l1->fd = -1;
    check(try_open(h2, "esp32c5btle-%s:channel=38", pts, msg) == 1 && l2->channel == 37 && l2->mode == MODE_BLE &&
            strcmp(h2->channel, "37") == 0, "the port is free once closed; BTLE with channel=38 opens on 37 (%s)", msg);

    /* BTLE: a set to 38 or 39 is taken, and reported to Kismet as 37 -- the framework
     * reports the very string it handed chantranslate_callback */
    {
        char set38[8] = "38", set39[16] = "39", set40[8] = "40", wifi[16] = "6HT40";
        local_channel_t *c38 = (local_channel_t *) chantranslate_callback(h2, set38);
        local_channel_t *c39 = (local_channel_t *) chantranslate_callback(h2, set39);
        local_channel_t *c40b = (local_channel_t *) chantranslate_callback(h2, set40);
        check(strcmp(set38, "37") == 0 && strcmp(set39, "37") == 0 && strcmp(set40, "40") == 0,
                "BTLE: 38 and 39 are rewritten to 37 for Kismet, 40 is left as it is (%s %s %s)", set38, set39, set40);
        msg[0] = '\0';
        check(chancontrol_callback(h2, 5, c38, msg) == 1 && strcmp(h2->channel, "37") == 0 &&
                chancontrol_callback(h2, 6, c39, msg) == 1 && strcmp(h2->channel, "37") == 0,
                "BTLE: a set to 38 or 39 succeeds on 37");
        nmessages = 0;
        check(chancontrol_callback(h2, 7, c40b, msg) == 0 && strstr(msg, "cannot tune to channel 40 in btle mode") != NULL &&
                strcmp(h2->channel, "37") == 0 && nmessages == 1 && message_flags[0] == MSGFLAG_ERROR,
                "BTLE: 40 is refused, told to Kismet as an error message, and 37 stays: %s", msg);
        free(chantranslate_callback(h1, wifi));
        check(strcmp(wifi, "6HT40") == 0, "Wi-Fi: Kismet's channel names are left alone");
        free(c38);
        free(c39);
        free(c40b);
    }
    close(l2->fd);
    close(master);
}

/* ------------------------------------------------------------------------------
 * Exclusive mode: the tty itself, whichever node it is opened through
 *
 * The flock is on a node's inode, and a container's /dev/ttyACM0 is a node of its
 * own.  TIOCEXCL is on the tty: another open of it fails with EBUSY, from any node,
 * unless the opener has CAP_SYS_ADMIN, as this test, run as root, does.  So the
 * opens that count are made by a child process that does not have it.
 * ---------------------------------------------------------------------------- */

#ifdef HAVE_CAPABILITY
/* What a child without CAP_SYS_ADMIN got */
#define GOT_IN 0        /* opened (and, for lock_node, locked) */
#define GOT_BUSY 1      /* refused: EBUSY, or serial_open's "already in use" */
#define GOT_ERROR 2     /* anything else */

static int as_other(int (*fn)(const char *), const char *path) {
    pid_t pid;
    int st;

    fflush(stdout);
    if ((pid = fork()) == 0) {
        cap_t c = cap_get_proc();
        cap_value_t v = CAP_SYS_ADMIN;
        int r;

        cap_set_flag(c, CAP_EFFECTIVE, 1, &v, CAP_CLEAR);
        cap_set_flag(c, CAP_PERMITTED, 1, &v, CAP_CLEAR);
        if (cap_set_proc(c) < 0)
            _exit(99);
        r = fn(path);
        fflush(stdout);
        _exit(r);
    }
    if (pid < 0 || waitpid(pid, &st, 0) != pid || !WIFEXITED(st))
        return -1;
    return WEXITSTATUS(st);
}

/* an open as any program makes it, without the flock */
static int plain_open(const char *path) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);

    if (fd < 0)
        return errno == EBUSY ? GOT_BUSY : GOT_ERROR;
    close(fd);
    return GOT_IN;
}

/* the flock alone, as it was all a helper took */
static int lock_node(const char *path) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK), r;

    if (fd < 0)
        return errno == EBUSY ? GOT_BUSY : GOT_ERROR;
    r = flock(fd, LOCK_EX | LOCK_NB) == 0 ? GOT_IN : GOT_BUSY;
    close(fd);
    return r;
}

/* another helper */
static int helper_open(const char *path) {
    char msg[STATUS_MAX];
    int fd = serial_open(path, msg, sizeof(msg));

    if (fd >= 0) {
        serial_close(fd);
        return GOT_IN;
    }
    if (fd == PORT_BUSY && strstr(msg, "already in use by another capture") != NULL)
        return GOT_BUSY;
    printf("     %s\n", msg);
    return GOT_ERROR;
}

static int tty_exclusive(int fd) {
    int excl = -1;

    ioctl(fd, TIOCGEXCL, &excl);
    return excl;
}
#endif

static void test_exclusive(void) {
#if defined(HAVE_CAPABILITY) && defined(TIOCGEXCL)
    char msg[STATUS_MAX], pts[64], real[32] = "", copy[PATH_MAX];
    struct termios tio;
    struct stat st;
    int master, fd, holder, other;
    FILE *f;

    if (geteuid() != 0) {
        printf("SKIP exclusive mode: needs root, to make device nodes and to open as a process "
                "without CAP_SYS_ADMIN\n");
        return;
    }

    /* A pseudo-terminal gets the flock only: its tty lives as long as the other end is
     * open, and the mode with it, so a helper killed in exclusive mode would lock the
     * next one out */
    master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
        check(false, "a pseudo-terminal to open");
        return;
    }
    snprintf(pts, sizeof(pts), "%s", ptsname(master));
    fd = serial_open(pts, msg, sizeof(msg));
    check(fd >= 0 && tty_exclusive(fd) == 0, "a pseudo-terminal is not put in exclusive mode");
    check(as_other(helper_open, pts) == GOT_BUSY, "... a second helper is kept out of it by the flock");
    serial_close(fd);

    fd = open(pts, O_RDWR | O_NOCTTY | O_NONBLOCK);
    ioctl(fd, TIOCEXCL);
    close(fd);
    check(as_other(plain_open, pts) == GOT_BUSY,
            "the mode outlives a pseudo-terminal's last close while its other end is open (EBUSY)");
    fd = open(pts, O_RDWR | O_NOCTTY | O_NONBLOCK);     /* as root: let in */
    ioctl(fd, TIOCEXCL);
    serial_close(fd);
    check(as_other(plain_open, pts) == GOT_IN, "serial_close ends it all the same");
    close(master);

    /* A tty that is not a pseudo-terminal, as a USB serial port is: a serial port with
     * no hardware behind it, which nothing can be using -- one the 8250 driver lists
     * as "uart:unknown" (tcgetattr on it fails with EIO).  A port with hardware is not
     * opened: that would move its DTR and RTS. */
    if ((f = fopen("/proc/tty/driver/serial", "r")) != NULL) {
        char line[256], path[32];
        int n;
        while (real[0] == '\0' && fgets(line, sizeof(line), f) != NULL) {
            if (sscanf(line, "%d:", &n) != 1 || strstr(line, " uart:unknown ") == NULL)
                continue;
            snprintf(path, sizeof(path), "/dev/ttyS%d", n);
            if ((fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)) < 0)
                continue;
            if (tcgetattr(fd, &tio) < 0 && errno == EIO)
                snprintf(real, sizeof(real), "%s", path);
            close(fd);
        }
        fclose(f);
    }
    snprintf(copy, sizeof(copy), "%s/ttyS-copy", tree);
    if (real[0] == '\0' || stat(real, &st) < 0 || mknod(copy, S_IFCHR | 0600, st.st_rdev) < 0) {
        printf("SKIP exclusive mode across device nodes: no /dev/ttyS* without hardware to try it on\n");
        return;
    }
    printf("     %s, and %s: the same tty, another inode, as a container would make it\n", real, copy);

    holder = open(real, O_RDWR | O_NOCTTY | O_NONBLOCK);
    flock(holder, LOCK_EX | LOCK_NB);
    check(as_other(lock_node, copy) == GOT_IN,
            "the flock on one node does not keep out a helper on another node of the tty");
    ioctl(holder, TIOCEXCL);
    check(as_other(helper_open, copy) == GOT_BUSY,
            "exclusive mode does: serial_open through the other node is refused, \"already in use\"");
    check(as_other(plain_open, real) == GOT_BUSY, "... and any open through the tty's own node (EBUSY)");
    close(holder);
    check(as_other(plain_open, copy) == GOT_IN,
            "the mode ends with the tty's last close, however its holder ends");

    /* Someone else has the tty open as well, a program that had it first: then only
     * serial_close ends the mode, and the helper's own next open is let in */
    other = open(real, O_RDWR | O_NOCTTY | O_NONBLOCK);
    fd = open(real, O_RDWR | O_NOCTTY | O_NONBLOCK);
    ioctl(fd, TIOCEXCL);
    serial_close(fd);
    check(as_other(plain_open, copy) == GOT_IN,
            "serial_close ends the mode while another program keeps the tty open");
    close(other);
    unlink(copy);
#else
    printf("SKIP exclusive mode: built without libcap, or no TIOCGEXCL\n");
#endif
}

/* ------------------------------------------------------------------------------
 * Capabilities: the helper drops them all, first thing
 *
 * Its main runs in a child process, with pipes for Kismet's, and is read from
 * /proc once it waits in Kismet's loop for a command.
 * ---------------------------------------------------------------------------- */

#ifdef HAVE_CAPABILITY
#define AS_ROOT 0           /* as Kismet run by root starts it */
#define AS_DOCKER 1         /* root with Docker's default capabilities: no NET_ADMIN */
#define AS_SETUID_ROOT 2    /* installed setuid root, started by a user */
#define AS_USER 3           /* an ordinary program of an ordinary user */

static const cap_value_t docker_caps[] = { CAP_CHOWN, CAP_DAC_OVERRIDE, CAP_FSETID, CAP_FOWNER,
    CAP_MKNOD, CAP_NET_RAW, CAP_SETGID, CAP_SETUID, CAP_SETFCAP, CAP_SETPCAP, CAP_NET_BIND_SERVICE,
    CAP_SYS_CHROOT, CAP_KILL, CAP_AUDIT_WRITE };
#define N_DOCKER_CAPS (int) (sizeof(docker_caps) / sizeof(docker_caps[0]))

typedef struct {
    unsigned long long inh, prm, eff, bnd, amb;
    int nnp;
    char uid[64];
} proc_caps_t;

static bool read_caps(pid_t pid, proc_caps_t *c) {
    char path[64], line[256];
    FILE *f;

    memset(c, 0, sizeof(*c));
    c->nnp = -1;
    snprintf(path, sizeof(path), "/proc/%d/status", (int) pid);
    if ((f = fopen(path, "r")) == NULL)
        return false;
    while (fgets(line, sizeof(line), f) != NULL) {
        sscanf(line, "CapInh: %llx", &c->inh);
        sscanf(line, "CapPrm: %llx", &c->prm);
        sscanf(line, "CapEff: %llx", &c->eff);
        sscanf(line, "CapBnd: %llx", &c->bnd);
        sscanf(line, "CapAmb: %llx", &c->amb);
        sscanf(line, "NoNewPrivs: %d", &c->nnp);
        if (strncmp(line, "Uid:", 4) == 0) {
            unsigned int r, e, s, fs;
            if (sscanf(line + 4, "%u %u %u %u", &r, &e, &s, &fs) == 4)
                snprintf(c->uid, sizeof(c->uid), "%u %u %u", r, e, s);
        }
    }
    fclose(f);
    return true;
}

/* In the child, before the helper's main; a child that cannot be what it is asked
 * to be ends at once, and fails the checks */
static void become(int how) {
    if (how == AS_DOCKER) {
        cap_t c = cap_init();
        for (int v = 0; v < 64; v++) {
            bool keep = false;
            for (int i = 0; i < N_DOCKER_CAPS; i++)
                keep = keep || docker_caps[i] == v;
            if (!keep)
                prctl(PR_CAPBSET_DROP, v, 0, 0, 0);
        }
        cap_set_flag(c, CAP_PERMITTED, N_DOCKER_CAPS, docker_caps, CAP_SET);
        cap_set_flag(c, CAP_EFFECTIVE, N_DOCKER_CAPS, docker_caps, CAP_SET);
        if (cap_set_proc(c) < 0)
            _exit(98);
        cap_free(c);
    } else if (how == AS_SETUID_ROOT) {
        /* the user's uid, root's effective one: every capability is kept */
        if (setresuid(65534, 0, 0) < 0)
            _exit(98);
    } else if (how == AS_USER && geteuid() == 0) {
        if (setgroups(0, NULL) < 0 || setresgid(65534, 65534, 65534) < 0 ||
                setresuid(65534, 65534, 65534) < 0)
            _exit(98);
    }
}

static void run_helper_as(int how, const char *name) {
    char errfile[PATH_MAX], line[256];
    proc_caps_t c;
    int in[2], out[2], st = 0, alive;
    bool warned = false;
    pid_t pid;
    FILE *f;

    if (pipe(in) < 0 || pipe(out) < 0) {
        check(false, "%s: pipes for the helper", name);
        return;
    }
    snprintf(errfile, sizeof(errfile), "%s/helper-stderr", tree);
    fflush(stdout);
    if ((pid = fork()) == 0) {
        char a_in[16], a_out[16];
        char *argv[] = { (char *) "kismet_cap_esp32c5", (char *) "--in-fd", a_in,
            (char *) "--out-fd", a_out, NULL };
        int e = open(errfile, O_WRONLY | O_CREAT | O_TRUNC, 0666);

        if (e >= 0)
            dup2(e, 2);
        close(in[1]);
        close(out[0]);
        snprintf(a_in, sizeof(a_in), "%d", in[0]);
        snprintf(a_out, sizeof(a_out), "%d", out[1]);
        become(how);
        _exit(esp32c5_helper_main(5, argv));
    }
    close(in[0]);
    close(out[1]);

    /* it sets no_new_privs last: from then on what /proc shows is what it runs with */
    for (int i = 0; i < 150 && read_caps(pid, &c) && c.nnp != 1; i++)
        usleep(20000);
    usleep(100000);
    read_caps(pid, &c);
    alive = waitpid(pid, &st, WNOHANG) == 0;
    check(alive && c.inh == 0 && c.prm == 0 && c.eff == 0 && c.amb == 0 && c.nnp == 1,
            "%s: the helper runs with no capability, and can gain none (CapPrm %llx CapEff %llx "
            "CapInh %llx NoNewPrivs %d%s)", name, c.prm, c.eff, c.inh, c.nnp,
            alive ? "" : WIFSIGNALED(st) ? ", killed by a signal" : ", exited");
    if (how == AS_DOCKER) {
        unsigned long long want = 0;
        for (int i = 0; i < N_DOCKER_CAPS; i++)
            want |= 1ULL << docker_caps[i];
        check(c.bnd == want && !(c.bnd & (1ULL << CAP_NET_ADMIN)),
                "%s: ... started without NET_ADMIN, as Docker starts a container (CapBnd %llx)", name, c.bnd);
    } else if (how == AS_SETUID_ROOT) {
        check(strcmp(c.uid, "65534 0 0") == 0, "%s: ... with the user's uid and root's effective one (%s)",
                name, c.uid);
    }

    /* Kismet goes: the helper's input ends, and so does the helper */
    close(in[1]);
    close(out[0]);
    for (int i = 0; i < 250 && alive; i++) {
        if (waitpid(pid, &st, WNOHANG) == pid)
            alive = 0;
        else
            usleep(20000);
    }
    if (alive) {
        kill(pid, SIGKILL);
        waitpid(pid, &st, 0);
    }
    if ((f = fopen(errfile, "r")) != NULL) {
        while (fgets(line, sizeof(line), f) != NULL)
            warned = warned || strstr(line, "could not") != NULL;
        fclose(f);
    }
    check(!alive && WIFEXITED(st) && !warned, "%s: ... it ends when its input does, and had nothing to "
            "warn about", name);
}
#endif

#if defined(HAVE_CAPABILITY) && defined(__linux__)
/* Installed setuid root and started by a user, the helper has no capability left:
 * a pseudo-terminal of the user's own (user:tty 0620, as tools/fake_board.py makes
 * one) is not root's to open then, and serial_open opens it with the user's file
 * permissions instead (open_port).  One of another user's stays shut, and the file
 * system uid is root's again after each open.  The child that plays the helper
 * reports each check that failed as a bit of its exit status. */
#define SU_PLAIN 1      /* a plain open of the user's pty was not refused: nothing tested */
#define SU_OWN 2        /* serial_open did not open the user's own pty */
#define SU_LINK 4       /* ... nor through the user's link to it in /tmp */
#define SU_OTHER 8      /* it opened another user's pty, or failed for another reason */
#define SU_FSUID 16     /* the file system uid was not root's after an open */
#define SU_SETUP 32     /* the child could not become such a helper */

/* A pseudo-terminal as the user uid would have made it */
static int pty_of(uid_t uid, gid_t gid, char *name, size_t name_sz) {
    int m = posix_openpt(O_RDWR | O_NOCTTY);

    if (m < 0)
        return -1;
    if (grantpt(m) < 0 || unlockpt(m) < 0 || ptsname(m) == NULL) {
        close(m);
        return -1;
    }
    snprintf(name, name_sz, "%s", ptsname(m));
    if (chown(name, uid, gid) < 0 || chmod(name, 0620) < 0) {
        close(m);
        return -1;
    }
    return m;
}

static bool fsuid_is_root(void) {
    char line[256];
    unsigned int r, e, s, fs = 1;
    FILE *f = fopen("/proc/self/status", "r");

    if (f == NULL)
        return false;
    while (fgets(line, sizeof(line), f) != NULL)
        if (strncmp(line, "Uid:", 4) == 0)
            sscanf(line + 4, "%u %u %u %u", &r, &e, &s, &fs);
    fclose(f);
    return fs == 0;
}

static void test_setuid_open(void) {
    char own[64], other[64], link[64], msg[STATUS_MAX];
    struct group *tty = getgrnam("tty");
    gid_t tty_gid = tty != NULL ? tty->gr_gid : 5;
    int m_own, m_other, st, r, protect = -1;
    pid_t pid;
    FILE *f;

    m_own = pty_of(65534, tty_gid, own, sizeof(own));
    m_other = pty_of(65533, tty_gid, other, sizeof(other));
    /* the fake board's link, where the documentation puts it: /tmp, which is sticky
     * and anyone's, so protected_symlinks lets only its owner follow it */
    snprintf(link, sizeof(link), "/tmp/esp32c5-test-link-%d", (int) getpid());
    if (m_own < 0 || m_other < 0 || symlink(own, link) < 0 || lchown(link, 65534, 65534) < 0) {
        check(false, "setuid root: pseudo-terminals of two users, and a link of one of them in /tmp");
        unlink(link);
        if (m_own >= 0)
            close(m_own);
        if (m_other >= 0)
            close(m_other);
        return;
    }
    if ((f = fopen("/proc/sys/fs/protected_symlinks", "r")) != NULL) {
        if (fscanf(f, "%d", &protect) != 1)
            protect = -1;
        fclose(f);
    }

    fflush(stdout);
    if ((pid = fork()) == 0) {
        int fd;

        r = 0;
        /* the user's groups, root's effective uid, and then no capability */
        if (setgroups(0, NULL) < 0 || setresgid(65534, 65534, 65534) < 0 ||
                setresuid(65534, 0, 0) < 0)
            _exit(SU_SETUP);
        drop_capabilities();

        if ((fd = open(own, O_RDWR | O_NOCTTY | O_NONBLOCK)) >= 0 || errno != EACCES)
            r |= SU_PLAIN;
        if (fd >= 0)
            close(fd);
        if ((fd = serial_open(own, msg, sizeof(msg))) >= 0) {
            serial_close(fd);
        } else {
            printf("     %s\n", msg);
            r |= SU_OWN;
        }
        r |= fsuid_is_root() ? 0 : SU_FSUID;
        if ((fd = serial_open(link, msg, sizeof(msg))) >= 0) {
            serial_close(fd);
        } else {
            printf("     %s\n", msg);
            r |= SU_LINK;
        }
        r |= fsuid_is_root() ? 0 : SU_FSUID;
        if ((fd = serial_open(other, msg, sizeof(msg))) >= 0) {
            serial_close(fd);
            r |= SU_OTHER;
        } else if (strstr(msg, "Permission denied") == NULL) {
            printf("     %s\n", msg);
            r |= SU_OTHER;
        }
        r |= fsuid_is_root() ? 0 : SU_FSUID;
        fflush(stdout);
        _exit(r);
    }
    if (pid < 0 || waitpid(pid, &st, 0) != pid || !WIFEXITED(st))
        r = SU_SETUP;
    else
        r = WEXITSTATUS(st);

    check(!(r & (SU_SETUP | SU_PLAIN)), "setuid root, no capability: a user's own pseudo-terminal "
            "(%s, user:tty 0620) is not root's to open (EACCES)", own);
    check(!(r & (SU_SETUP | SU_OWN)), "setuid root: ... serial_open opens it all the same, with the "
            "user's file permissions");
    check(!(r & (SU_SETUP | SU_LINK)), "setuid root: ... and through the user's link to it in /tmp "
            "(protected_symlinks %d)", protect);
    check(!(r & (SU_SETUP | SU_OTHER)), "setuid root: ... but not another user's pseudo-terminal "
            "(Permission denied)");
    check(!(r & (SU_SETUP | SU_FSUID)), "setuid root: ... and the file system uid is root's again "
            "after each open");

    unlink(link);
    close(m_own);
    close(m_other);
}
#endif

static void test_capabilities(void) {
#ifdef HAVE_CAPABILITY
    if (geteuid() != 0) {
        run_helper_as(AS_USER, "a user");
        printf("SKIP capabilities as root, in Docker and setuid root: needs root\n");
        return;
    }
    run_helper_as(AS_ROOT, "root");
    run_helper_as(AS_DOCKER, "root in a container");
    run_helper_as(AS_SETUID_ROOT, "setuid root");
    run_helper_as(AS_USER, "a user");
#ifdef __linux__
    test_setuid_open();
#endif
#else
    printf("SKIP capabilities: built without libcap, the helper keeps what it is given\n");
#endif
}

/* ------------------------------------------------------------------------------
 * Ending: the reason told to Kismet, the PING watchdog, the signals that end a
 * remote helper, and its capture process ending with its parent
 * ---------------------------------------------------------------------------- */

/* Kismet (cfe427074) logs a MESSAGE but drops an ERROR frame unread: the reason goes
 * as both, the message first */
static void test_say_why(void) {
    bytes_t s = { 0 };

    put_start(&s, 127);
    put_recs(&s, 0, 3);
    reset(MODE_WIFI);
    send_data_fails = true;
    feed(s.p, s.n, 4096);
    send_data_fails = false;
    /* the two last things sent, in the order they went: by their flags, as both carry
     * the same text */
    check(messages_flagged("test: unable to send a packet to the Kismet server", MSGFLAG_ERROR) == 1 &&
            messages_flagged("test: unable to send a packet to the Kismet server", SENT_AS_ERROR) == 1 &&
            nmessages >= 2 && message_flags[nmessages - 2] == MSGFLAG_ERROR &&
            message_flags[nmessages - 1] == SENT_AS_ERROR &&
            strstr(messages[nmessages - 2], "unable to send") != NULL && L->send_failed,
            "a failed send is told to Kismet as an error MESSAGE, then as an ERROR, and the capture ends");
    /* the framework spins down once the capture thread returns: a second spindown here
     * would leave a window for its cancel while this thread holds the handler's lock */
    check(!caph->spindown && !consume(L), "... and nothing more is framed, without the helper "
            "spinning down itself");
    bytes_free(&s);
    reset(MODE_WIFI);
}

static void test_ping_watchdog(void) {
#ifdef HAVE_LIBWEBSOCKETS
    kis_capture_handler_t *h = cf_handler_init("esp32c5");
    local_esp32c5_t *l = new_local(h);

    h->use_ws = 1;
    h->last_ping = time(NULL);
    check(!ws_ping_lost(l) && l->ping_seen == h->last_ping, "websocket: the PING at the connection starts the clock");
    l->ping_seen_at = now_s() - 5;
    check(!ws_ping_lost(l), "websocket: a PING 5 s ago is fine");
    l->ping_seen_at = now_s() - PING_TIMEOUT_S - 1;
    check(ws_ping_lost(l), "websocket: no PING for %d s ends the connection", PING_TIMEOUT_S + 1);
    h->last_ping++;
    check(!ws_ping_lost(l), "websocket: a new PING starts it again");
    /* the wall clock jumps an hour ahead: last_ping looks old, but it has not changed
     * for only a moment */
    h->last_ping = time(NULL) - 3600;
    l->ping_seen = h->last_ping;
    l->ping_seen_at = now_s() - 1;
    check(!ws_ping_lost(l), "a jump of the wall clock is no lost PING (monotonic clock)");
    h->use_ws = 0;
    l->ping_seen_at = now_s() - PING_TIMEOUT_S - 1;
    check(!ws_ping_lost(l), "not over TCP or to a local source, where the framework watches for it");
#else
    check(!ws_ping_lost(L), "no libwebsockets: no websocket to watch");
#endif
}

/* The exclusive mode of the tty behind fd; -1 when it cannot be asked */
static int exclusive_of(int fd) {
    int on = 0;
    return ioctl(fd, TIOCGEXCL, &on) < 0 ? -1 : on;
}

/* A remote helper's process ended by a signal takes the port out of exclusive mode.
 * The test holds the pseudo-terminal's other end, so the tty outlives the process,
 * and so would the mode, as with a port someone else has open too. */
static void test_end_on_signal(void) {
    int ready[2];

    if (pipe(ready) < 0) {
        check(false, "a pipe");
        return;
    }

    for (int handled = 0; handled < 2; handled++) {
        int master = posix_openpt(O_RDWR | O_NOCTTY);
        char name[64];
        pid_t pid;
        int st = 0, fd, ex;
        char c;

        if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
            check(false, "a pseudo-terminal");
            return;
        }
        snprintf(name, sizeof(name), "%s", ptsname(master));
        fflush(stdout);
        if ((pid = fork()) == 0) {
            local_esp32c5_t l;
            memset(&l, 0, sizeof(l));
            l.fd = open(name, O_RDWR | O_NOCTTY);
            ioctl(l.fd, TIOCEXCL);
            if (handled)
                catch_end_signals(&l);
            c = 1;
            if (write(ready[1], &c, 1) < 0)
                _exit(1);
            for (;;)
                pause();
        }
        if (read(ready[0], &c, 1) != 1)
            c = 0;
        kill(pid, SIGTERM);
        waitpid(pid, &st, 0);
        /* as root the open gets in anyway (CAP_SYS_ADMIN) and the mode can be asked;
         * as a user it fails with EBUSY while the mode is on */
        fd = open(name, O_RDWR | O_NOCTTY | O_NONBLOCK);
        ex = fd >= 0 ? exclusive_of(fd) : errno == EBUSY ? 1 : -1;
        if (handled)
            check(c && WIFSIGNALED(st) && WTERMSIG(st) == SIGTERM && ex == 0,
                    "SIGTERM: the port's exclusive mode is ended, and the signal still ends the process (mode %d)", ex);
        else
            check(c && ex == 1, "(without the handler the mode would outlive the process: %d)", ex);
        if (fd >= 0) {
            ioctl(fd, TIOCNXCL);
            close(fd);
        }
        close(master);
    }

    /* Started with SIGHUP and SIGINT ignored, as nohup and a shell's background job
     * start it: those stay ignored, and SIGTERM still ends it the same way */
    {
        int master = posix_openpt(O_RDWR | O_NOCTTY);
        char name[64], c;
        pid_t pid;
        int st = 0, fd, ex, hup_st;
        bool outlived;

        if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
            check(false, "a pseudo-terminal");
            return;
        }
        snprintf(name, sizeof(name), "%s", ptsname(master));
        fflush(stdout);
        if ((pid = fork()) == 0) {
            local_esp32c5_t l;
            memset(&l, 0, sizeof(l));
            signal(SIGHUP, SIG_IGN);
            signal(SIGINT, SIG_IGN);
            l.fd = open(name, O_RDWR | O_NOCTTY);
            ioctl(l.fd, TIOCEXCL);
            catch_end_signals(&l);
            c = 1;
            if (write(ready[1], &c, 1) < 0)
                _exit(1);
            for (;;)
                pause();
        }
        if (read(ready[0], &c, 1) != 1)
            c = 0;
        kill(pid, SIGHUP);
        kill(pid, SIGINT);
        usleep(300000);
        hup_st = waitpid(pid, &st, WNOHANG);
        outlived = hup_st == 0;
        if (outlived) {
            kill(pid, SIGTERM);
            waitpid(pid, &st, 0);
        }
        fd = open(name, O_RDWR | O_NOCTTY | O_NONBLOCK);
        ex = fd >= 0 ? exclusive_of(fd) : errno == EBUSY ? 1 : -1;
        check(c && outlived, "SIGHUP and SIGINT that it was started ignoring stay ignored (nohup, a "
                "background job): it goes on");
        check(c && WIFSIGNALED(st) && WTERMSIG(st) == SIGTERM && ex == 0,
                "... and SIGTERM still ends the mode, then the process (mode %d)", ex);
        if (fd >= 0) {
            ioctl(fd, TIOCNXCL);
            close(fd);
        }
        close(master);
    }
    close(ready[0]);
    close(ready[1]);
}

/* end_with_parent in a process forked the way the framework forks its capture
 * process: that process ends when its parent does, and at once when the parent has
 * gone before it could ask to.  The grandchild holds the write end of a pipe, so
 * the read end sees EOF once it has ended. */
static bool grandchild_outlives_parent(bool end, useconds_t parent_lives, useconds_t child_waits,
        pid_t *grandchild) {
    int p[2];
    pid_t child;
    struct pollfd pfd;
    char c;
    bool alive;

    if (pipe(p) < 0)
        return true;
    fflush(stdout);
    if ((child = fork()) == 0) {
        pid_t gc;
        close(p[0]);
        pthread_atfork(note_fork, NULL, NULL);
        if ((gc = fork()) == 0) {
            usleep(child_waits);
            if (end)
                end_with_parent();
            for (;;)
                pause();
        }
        if (write(p[1], &gc, sizeof(gc)) < 0)
            _exit(1);
        usleep(parent_lives);
        _exit(0);
    }
    close(p[1]);
    *grandchild = -1;
    if (read(p[0], grandchild, sizeof(*grandchild)) != sizeof(*grandchild))
        *grandchild = -1;
    waitpid(child, NULL, 0);
    pfd.fd = p[0];
    pfd.events = POLLIN;
    alive = !(poll(&pfd, 1, 1000) == 1 && read(p[0], &c, 1) == 0);
    close(p[0]);
    return alive;
}

#if defined(HAVE_CAPABILITY) && defined(__linux__)
/* Installed setuid root and started by a user, the capture process opens a port of
 * the user's with the user's file permissions (open_port), and the kernel clears the
 * parent-death signal whenever the file system uid changes.  The grandchild becomes
 * such a helper, asks to end with its parent, and opens the user's pseudo-terminal:
 * through serial_open, or, for the control, switching the file system uid by hand.
 * It says on a second pipe whether the open worked. */
static bool setuid_grandchild_outlives_parent(bool by_serial_open, const char *pty, pid_t *grandchild,
        bool *opened) {
    int p[2], okp[2];
    pid_t child;
    struct pollfd pfd;
    char c = 0;
    bool alive;

    *grandchild = -1;
    *opened = false;
    if (pipe(p) < 0)
        return true;
    if (pipe(okp) < 0) {
        close(p[0]);
        close(p[1]);
        return true;
    }
    fflush(stdout);
    if ((child = fork()) == 0) {
        pid_t gc;
        close(p[0]);
        close(okp[0]);
        pthread_atfork(note_fork, NULL, NULL);
        if ((gc = fork()) == 0) {
            char msg[STATUS_MAX];
            int fd;
            /* the user's groups, root's effective uid, and then no capability */
            if (setgroups(0, NULL) < 0 || setresgid(65534, 65534, 65534) < 0 ||
                    setresuid(65534, 0, 0) < 0)
                _exit(1);
            drop_capabilities();
            end_with_parent();
            if (by_serial_open) {
                fd = serial_open(pty, msg, sizeof(msg));
            } else {
                int was = setfsuid(getuid());
                fd = open(pty, O_RDWR | O_NOCTTY | O_NONBLOCK);
                setfsuid((uid_t) was);
            }
            c = fd >= 0 ? 'y' : 'n';
            if (write(okp[1], &c, 1) < 0)
                _exit(1);
            for (;;)
                pause();
        }
        if (write(p[1], &gc, sizeof(gc)) < 0)
            _exit(1);
        usleep(300000);
        _exit(0);
    }
    close(p[1]);
    close(okp[1]);
    if (read(p[0], grandchild, sizeof(*grandchild)) != sizeof(*grandchild))
        *grandchild = -1;
    pfd.fd = okp[0];
    pfd.events = POLLIN;
    *opened = poll(&pfd, 1, 2000) == 1 && read(okp[0], &c, 1) == 1 && c == 'y';
    waitpid(child, NULL, 0);
    pfd.fd = p[0];
    pfd.events = POLLIN;
    alive = !(poll(&pfd, 1, 1000) == 1 && read(p[0], &c, 1) == 0);
    close(p[0]);
    close(okp[0]);
    return alive;
}

static void test_setuid_end_with_parent(void) {
    struct group *tty = getgrnam("tty");
    char own[64];
    pid_t gc;
    bool alive, opened;
    int m;

    if (geteuid() != 0) {
        printf("SKIP setuid root: the capture process ends with its parent after opening a port of "
                "the user's: needs root\n");
        return;
    }
    if ((m = pty_of(65534, tty != NULL ? tty->gr_gid : 5, own, sizeof(own))) < 0) {
        check(false, "setuid root: a pseudo-terminal of the user's");
        return;
    }
    alive = setuid_grandchild_outlives_parent(false, own, &gc, &opened);
    check(gc > 0 && opened && alive, "(setuid root: opening a port of the user's with the user's file "
            "system uid clears the parent-death signal; not asked for again, the capture process "
            "would go on on its own)");
    if (gc > 0 && alive)
        kill(gc, SIGKILL);
    alive = setuid_grandchild_outlives_parent(true, own, &gc, &opened);
    check(gc > 0 && opened && !alive, "setuid root: serial_open asks for it again, and the capture "
            "process still ends with its parent (%s)", own);
    if (gc > 0 && alive)
        kill(gc, SIGKILL);
    close(m);
}
#endif

static void test_end_with_parent(void) {
    pid_t gc;
    bool alive;

    alive = grandchild_outlives_parent(true, 300000, 0, &gc);
    check(gc > 0 && !alive, "the capture process ends within a second of its parent");
    if (alive)
        kill(gc, SIGKILL);
    alive = grandchild_outlives_parent(true, 0, 300000, &gc);
    check(gc > 0 && !alive, "and at once when the parent had gone before it could ask");
    if (alive)
        kill(gc, SIGKILL);
    alive = grandchild_outlives_parent(false, 0, 0, &gc);
    check(gc > 0 && alive, "(without end_with_parent it would go on on its own)");
    if (gc > 0)
        kill(gc, SIGKILL);
#if defined(HAVE_CAPABILITY) && defined(__linux__)
    test_setuid_end_with_parent();
#else
    printf("SKIP setuid root: the capture process ends with its parent after opening a port of the "
            "user's: needs libcap and Linux\n");
#endif
}

/* ------------------------------------------------------------------------------
 * The remote login: from the environment, where the framework puts it, and the
 * warning for one that cannot log in
 * ---------------------------------------------------------------------------- */

#ifdef HAVE_LIBWEBSOCKETS
static bool has_args(char **argv, int argc, const char *a, const char *b) {
    for (int i = 0; i + 1 < argc; i++)
        if (strcmp(argv[i], a) == 0 && strcmp(argv[i + 1], b) == 0)
            return true;
    return false;
}

/* stderr, caught in a file between catch_stderr and caught (which returns it) */
static int stderr_saved = -1, stderr_file = -1;

static void catch_stderr(void) {
    char path[128];

    snprintf(path, sizeof(path), "%s/stderr", tree);
    fflush(stderr);
    stderr_saved = dup(2);
    stderr_file = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    unlink(path);
    dup2(stderr_file, 2);
}

static const char *caught(void) {
    static char buf[8192];
    ssize_t n;

    fflush(stderr);
    dup2(stderr_saved, 2);
    close(stderr_saved);
    lseek(stderr_file, 0, SEEK_SET);
    n = read(stderr_file, buf, sizeof(buf) - 1);
    buf[n > 0 ? n : 0] = '\0';
    close(stderr_file);
    return buf;
}

/* Does warn_login_cannot_pass warn about these arguments? */
static bool warns_cannot_pass(char **argv) {
    const char *err;
    int argc = 0;

    while (argv[argc] != NULL)
        argc++;
    catch_stderr();
    warn_login_cannot_pass(argc, argv);
    err = caught();
    return strstr(err, "WARNING: the Kismet user name holds ':' and the login '&'") != NULL &&
        strstr(err, "use an API key (--apikey or KISMET_CAP_APIKEY) instead of the login") != NULL;
}

/* What the framework said on stderr in the last parsed() */
static char parse_said[8192];

/* The framework's reading of argv, on a handler of its own */
static kis_capture_handler_t *parsed(char **argv, int *r) {
    kis_capture_handler_t *h = cf_handler_init("esp32c5");
    int argc = 0;

    while (argv[argc] != NULL)
        argc++;
    catch_stderr();
    *r = cf_handler_parse_opts(h, argc, argv);
    snprintf(parse_said, sizeof(parse_said), "%s", caught());
    return h;
}

/* What the value of an "Authorization: Basic" header says, decoded; "" for anything
 * else */
static const char *basic_login(const char *auth) {
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    static char out[8192];
    unsigned int acc = 0, bits = 0;
    size_t n = 0;
    const char *p;

    out[0] = '\0';
    if (auth == NULL || strncmp(auth, "Basic ", 6) != 0 || strlen(auth + 6) % 4 != 0)
        return out;
    for (p = auth + 6; *p != '\0' && *p != '='; p++) {
        const char *at = strchr(b64, *p);
        if (at == NULL || n + 1 >= sizeof(out)) {
            out[0] = '\0';
            return out;
        }
        acc = (acc << 6) | (unsigned int) (at - b64);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = (char) ((acc >> bits) & 0xFF);
        }
    }
    out[n] = '\0';
    return out;
}

#define WS_ENDPOINT "/datasource/remote/remotesource.ws"

/* The login in an Authorization header as user:password, and none in the URI or a cookie */
static bool login_in_basic(kis_capture_handler_t *h, const char *user_password) {
    return strcmp(basic_login(h->lwsauthorization), user_password) == 0 && h->lwscookie == NULL &&
        h->lwsuri != NULL && strcmp(h->lwsuri, WS_ENDPOINT) == 0;
}

/* The API key in the KISMET cookie, as cookie says it, and none in the URI */
static bool key_in_cookie(kis_capture_handler_t *h, const char *cookie) {
    return h->lwscookie != NULL && strcmp(h->lwscookie, cookie) == 0 && h->lwsauthorization == NULL &&
        h->lwsuri != NULL && strcmp(h->lwsuri, WS_ENDPOINT) == 0;
}
#endif

/* lwsuri and the login options exist only in a Kismet built with libwebsockets;
 * without it login_from_env adds nothing, and this checks just that */
static void test_login(void) {
    char *base[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    int n;

    unsetenv("KISMET_CAP_APIKEY");
    unsetenv("KISMET_CAP_USER");
    unsetenv("KISMET_CAP_PASSWORD");

#ifdef HAVE_LIBWEBSOCKETS
    char *eq[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect=localhost:2501",
        (char *) "--source=esp32c5-ttyACM0", NULL };
    char *given[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--apikey=abc", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *tcp[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:3501",
        (char *) "--tcp", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *local_only[] = { (char *) "kismet_cap_esp32c5", (char *) "--list", NULL };
    char *autodetect[] = { (char *) "kismet_cap_esp32c5", (char *) "--autodetect",
        (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *dashdash[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--source", (char *) "esp32c5-ttyACM0", (char *) "--", NULL };
    char *user_only[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--user", (char *) "kismet", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *password_only[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--password=pw", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *both[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--user", (char *) "me", (char *) "--password", (char *) "mine",
        (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    kis_capture_handler_t *h;
    char **out;
    int r;

    check(login_from_env(5, base, &n) == base && n == 5, "no login in the environment: argv as it is");

    setenv("KISMET_CAP_APIKEY", "k3y", 1);
    out = login_from_env(5, base, &n);
    check(out != base && n == 7 && strcmp(out[1], "--apikey") == 0 && strcmp(out[2], "k3y") == 0 &&
            strcmp(out[3], "--connect") == 0 && out[n] == NULL && base[5] == NULL,
            "KISMET_CAP_APIKEY becomes --apikey in a copy of argv, right after the name");
    h = parsed(out, &r);
    check(r == 2 && key_in_cookie(h, "KISMET=k3y"),
            "the framework takes it, and sends it as the cookie KISMET=k3y (URI %s)", h->lwsuri ? h->lwsuri : "");
    out = login_from_env(3, eq, &n);
    check(n == 5 && has_args(out, n, "--apikey", "k3y"), "--connect=host:port works too");
    check(login_from_env(6, given, &n) == given && n == 6, "an --apikey given on the command line wins");
    check(login_from_env(6, tcp, &n) == tcp, "legacy TCP takes no login");
    check(login_from_env(2, local_only, &n) == local_only, "not remote: nothing added");

    /* --autodetect finds the server by its announcement and is as remote as
     * --connect.  Only the arguments are checked: parsing them would wait for an
     * announcement on UDP 2501. */
    out = login_from_env(4, autodetect, &n);
    check(n == 6 && has_args(out, n, "--apikey", "k3y"), "--autodetect gets the login too");

    /* after a "--" getopt reads no options, so an appended login would be lost */
    out = login_from_env(6, dashdash, &n);
    h = parsed(out, &r);
    check(n == 8 && r == 2 && key_in_cookie(h, "KISMET=k3y"),
            "a \"--\" on the command line does not hide it (%s)", h->lwscookie ? h->lwscookie : "");

    setenv("KISMET_CAP_USER", "kismet", 1);
    setenv("KISMET_CAP_PASSWORD", "pw", 1);
    out = login_from_env(5, base, &n);
    check(n == 7 && has_args(out, n, "--apikey", "k3y"), "an API key is used before user and password");
    unsetenv("KISMET_CAP_APIKEY");
    out = login_from_env(5, base, &n);
    check(n == 9 && has_args(out, n, "--user", "kismet") && has_args(out, n, "--password", "pw"),
            "KISMET_CAP_USER and KISMET_CAP_PASSWORD become --user and --password");
    h = parsed(out, &r);
    check(r == 2 && login_in_basic(h, "kismet:pw") &&
            strcmp(h->lwsauthorization, "Basic a2lzbWV0OnB3") == 0,
            "the framework takes them, and sends them as Basic authorization (%s)",
            h->lwsauthorization ? h->lwsauthorization : "");
    check(login_from_env(9, both, &n) == both, "a whole login on the command line is used as it is");

    /* half a login on the command line, the secret in the environment */
    setenv("KISMET_CAP_APIKEY", "k3y", 1);
    unsetenv("KISMET_CAP_USER");
    out = login_from_env(7, user_only, &n);
    check(n == 9 && has_args(out, n, "--password", "pw") && !has_args(out, n, "--apikey", "k3y"),
            "--user alone gets KISMET_CAP_PASSWORD, and nothing else");
    h = parsed(out, &r);
    check(r == 2 && login_in_basic(h, "kismet:pw"), "the framework takes the two halves");
    setenv("KISMET_CAP_USER", "kismet", 1);
    out = login_from_env(6, password_only, &n);
    check(n == 8 && has_args(out, n, "--user", "kismet") && !has_args(out, n, "--apikey", "k3y"),
            "--password alone gets KISMET_CAP_USER");
    h = parsed(out, &r);
    check(r == 2 && login_in_basic(h, "kismet:pw"), "the framework takes those too");

    /* The framework's getopt_long takes any abbreviation that fits one option alone,
     * and so does login_from_env: --pass is --password, --conn is --connect */
    {
        char *pass_abbrev[] = { (char *) "kismet_cap_esp32c5", (char *) "--conn", (char *) "localhost:2501",
            (char *) "--pass", (char *) "pw", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *source_value[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--source", (char *) "--user=x", NULL };
        out = login_from_env(7, pass_abbrev, &n);
        check(n == 9 && has_args(out, n, "--user", "kismet") && !has_args(out, n, "--apikey", "k3y"),
                "--pass alone, --password abbreviated, gets KISMET_CAP_USER and not the API key");
        h = parsed(out, &r);
        check(r == 2 && login_in_basic(h, "kismet:pw"), "the framework takes it as the password");
        out = login_from_env(5, source_value, &n);
        check(n == 7 && has_args(out, n, "--apikey", "k3y"),
                "a word that is an option's value (--source --user=x) is no login option");
    }
    unsetenv("KISMET_CAP_APIKEY");

    unsetenv("KISMET_CAP_PASSWORD");
    check(login_from_env(5, base, &n) == base, "a user without a password is not enough");
    check(login_from_env(7, user_only, &n) == user_only, "--user with no password anywhere: nothing added");
    unsetenv("KISMET_CAP_USER");

    /* The framework (add-to-kismet.sh) sends the login in the request's headers, where
     * Kismet takes it as it is and a reverse proxy does not log it: a user and password
     * as Basic authorization, whatever they hold, an API key as the KISMET cookie,
     * percent-encoded as Kismet decodes it ('+' would be a space).  Only a user name
     * with ':', where Basic ends the user name, goes in the URI's query, percent-encoded,
     * and a URI too long for the framework's 1024 bytes is refused, not cut. */
    {
        char *odd[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "me you", (char *) "--password", (char *) "p&%41 s+w/rd~:x",
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *odd_key[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--apikey", (char *) "k 3y+%41", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "me:you", (char *) "--password", (char *) "a b%41",
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *key_and_login[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--apikey", (char *) "k3y", (char *) "--user", (char *) "me", (char *) "--password",
            (char *) "pw", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *endpoint[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--apikey", (char *) "k3y", (char *) "--endpoint", (char *) "/proxied/remote.ws",
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char long_pw[3001], fits[969], too_long[970], amps[401];
        char *long_basic[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "me", (char *) "--password", long_pw,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon_fits[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "a:b", (char *) "--password", fits,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon_too_long[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "a:b", (char *) "--password", too_long,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon_amps[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "a:b", (char *) "--password", amps,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char want[1100];

        h = parsed(odd, &r);
        check(r == 2 && login_in_basic(h, "me you:p&%41 s+w/rd~:x"),
                "a login with '&', a space, %%41, '+' and ':' goes in the Authorization header as it "
                "is, and the URI holds none of it (%s)", h->lwsuri ? h->lwsuri : "");
        h = parsed(odd_key, &r);
        check(r == 2 && key_in_cookie(h, "KISMET=k%203y%2B%2541"),
                "an API key goes in the cookie, percent-encoded, '+' too (%s)",
                h->lwscookie ? h->lwscookie : "");
        h = parsed(colon, &r);
        check(r == 2 && h->lwsauthorization == NULL && h->lwscookie == NULL && h->lwsuri != NULL &&
                strcmp(h->lwsuri, WS_ENDPOINT "?user=me%3Ayou&password=a%20b%2541") == 0,
                "a user name with ':' goes in the URI's query instead, percent-encoded (%s)",
                h->lwsuri ? h->lwsuri : "");
        h = parsed(key_and_login, &r);
        check(r == 2 && login_in_basic(h, "me:pw") &&
                strstr(parse_said, "WARNING: Ignoring APIKEY and using login information") != NULL,
                "a login and an API key: the login is used, as before, and the framework says so");
        h = parsed(endpoint, &r);
        check(r == 2 && h->lwsuri != NULL && strcmp(h->lwsuri, "/proxied/remote.ws") == 0 &&
                h->lwscookie != NULL && strcmp(h->lwscookie, "KISMET=k3y") == 0,
                "--endpoint is the URI as it is, and the key still goes in the cookie (%s)",
                h->lwsuri ? h->lwsuri : "");

        memset(long_pw, 'p', sizeof(long_pw) - 1);
        long_pw[sizeof(long_pw) - 1] = '\0';
        h = parsed(long_basic, &r);
        snprintf(want, sizeof(want), "me:%.40s", long_pw);
        check(r == 2 && strlen(basic_login(h->lwsauthorization)) == 3003 &&
                strncmp(basic_login(h->lwsauthorization), want, strlen(want)) == 0 &&
                strcmp(h->lwsuri, WS_ENDPOINT) == 0,
                "a 3000 character password goes whole in the header (whether it fits in the "
                "request is lws's to say, when it is sent)");

        /* 55 bytes of URI around the password, which is not encoded: 968 make 1023 */
        memset(fits, 'x', sizeof(fits) - 1);
        fits[sizeof(fits) - 1] = '\0';
        h = parsed(colon_fits, &r);
        snprintf(want, sizeof(want), WS_ENDPOINT "?user=a%%3Ab&password=%s", fits);
        check(r == 2 && h->lwsuri != NULL && strlen(h->lwsuri) == 1023 && strcmp(h->lwsuri, want) == 0,
                "a user name with ':': a URI of 1023 bytes is whole");
        memset(too_long, 'x', sizeof(too_long) - 1);
        too_long[sizeof(too_long) - 1] = '\0';
        h = parsed(colon_too_long, &r);
        check(r < 0 && h->lwsuri == NULL &&
                strstr(parse_said, "FATAL: A user name with ':' puts the login in the websocket URI, "
                    "which would be 1024 bytes long with it, more than the 1023 it can be; use an "
                    "API key") != NULL,
                "... and one of 1024 is refused with a reason, not cut short");
        memset(amps, '&', sizeof(amps) - 1);
        amps[sizeof(amps) - 1] = '\0';
        h = parsed(colon_amps, &r);
        check(r < 0 && strstr(parse_said, "which would be 1255 bytes long") != NULL,
                "400 '&' in the password are 1200 bytes encoded, and counted so");
    }

    /* A login cannot pass only when the user name holds ':', and so goes in the URI's
     * query, where Kismet cuts it at every '&' after decoding it: a warning then, however
     * the login came */
    {
        char *pw[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user", (char *) "me:x",
            (char *) "--password", (char *) "a&b", (char *) "--source", (char *) "esp32c5", NULL };
        char *pw_eq[] = { (char *) "x", (char *) "--connect=h:2501", (char *) "--password=a&b",
            (char *) "--user=me:x", NULL };
        char *usr[] = { (char *) "x", (char *) "--host", (char *) "h:2501", (char *) "--user", (char *) "m&e:x",
            (char *) "--password", (char *) "pw", NULL };
        char *abbrev[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--use", (char *) "me:x",
            (char *) "--pass", (char *) "a&b", NULL };
        char *abbrev_eq[] = { (char *) "x", (char *) "--conn=h:2501", (char *) "--us=m&e:x", (char *) "--passw=pw", NULL };
        char *amp_basic[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user", (char *) "m&e",
            (char *) "--password", (char *) "a&b c%41", NULL };
        char *colon_plain[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user",
            (char *) "me:x", (char *) "--password", (char *) "a%41 b", NULL };
        char *tcp_amp[] = { (char *) "x", (char *) "--connect", (char *) "h:3501", (char *) "--tcp",
            (char *) "--user", (char *) "me:x", (char *) "--password", (char *) "a&b", NULL };
        char *after_dashes[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--apikey",
            (char *) "k", (char *) "--", (char *) "--user", (char *) "me:x", (char *) "--password", (char *) "a&b", NULL };
        char *key_no_pw[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--apikey", (char *) "k",
            (char *) "--user", (char *) "a:b&c", NULL };
        char *value_amp[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--source",
            (char *) "--password=a&b", (char *) "--user", (char *) "me:x", (char *) "--password", (char *) "pw", NULL };
        char *later_wins[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user", (char *) "me:x",
            (char *) "--password", (char *) "a&b", (char *) "--password", (char *) "pw", NULL };
        check(warns_cannot_pass(pw) && warns_cannot_pass(pw_eq) && warns_cannot_pass(usr),
                "a user name with ':' and an '&' in the password or the user name: warned about, "
                "--opt value and --opt=value");
        check(warns_cannot_pass(abbrev) && warns_cannot_pass(abbrev_eq),
                "... and with the options abbreviated, as getopt_long takes them (--use, --pass, --us=)");
        check(!warns_cannot_pass(amp_basic) && !warns_cannot_pass(colon_plain),
                "not for an '&' in a login without ':' in its user name, which goes as Basic, nor for "
                "a user name with ':' and no '&'");
        check(!warns_cannot_pass(tcp_amp) && !warns_cannot_pass(after_dashes),
                "not over legacy TCP, which has no login, nor for options after \"--\"");
        check(!warns_cannot_pass(key_no_pw) && !warns_cannot_pass(value_amp) && !warns_cannot_pass(later_wins),
                "nor for a user without a password, a '&' in another option's value, or a password "
                "that a later one replaces");
        setenv("KISMET_CAP_USER", "me:x", 1);
        setenv("KISMET_CAP_PASSWORD", "a&b", 1);
        out = login_from_env(5, base, &n);
        check(warns_cannot_pass(out), "and for a login from KISMET_CAP_USER and KISMET_CAP_PASSWORD");
        setenv("KISMET_CAP_USER", "me", 1);
        out = login_from_env(5, base, &n);
        check(!warns_cannot_pass(out), "... but not when the user name there has no ':'");
        unsetenv("KISMET_CAP_USER");
        unsetenv("KISMET_CAP_PASSWORD");
    }
#else
    setenv("KISMET_CAP_APIKEY", "k3y", 1);
    check(login_from_env(5, base, &n) == base && n == 5, "no libwebsockets: no remote login, argv as it is");
    unsetenv("KISMET_CAP_APIKEY");
#endif
}

int main(void) {
    char empty_tty[PATH_MAX];

    caph = cf_handler_init("esp32c5");
    L = (local_esp32c5_t *) calloc(1, sizeof(local_esp32c5_t));
    caph->userdata = L;

    /* No test sees the machine's own sysfs: from here on no board is plugged in,
     * until test_sysfs plugs its own in */
    snprintf(tree, sizeof(tree), "/tmp/esp32c5-test-XXXXXX");
    if (mkdtemp(tree) == NULL) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(empty_sysfs, sizeof(empty_sysfs), "%s/empty", tree);
    snprintf(empty_tty, sizeof(empty_tty), "%s/class/tty", empty_sysfs);
    make_dirs(empty_tty);
    sysfs_root = empty_sysfs;

    test_framing();
    test_capturing();
    test_injection();
    test_154();
    test_wifi_freq();
    test_btle();
    test_definitions();
    test_sysfs();
    test_probe();
    test_remote_busy();
    test_open();
    test_exclusive();
    test_say_why();
    test_ping_watchdog();
    test_end_on_signal();
    test_end_with_parent();
    test_capabilities();
    test_login();

    nftw(tree, rm_one, 16, FTW_DEPTH | FTW_PHYS);

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("ALL OK\n");
    return 0;
}
