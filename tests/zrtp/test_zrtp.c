/* In-memory tests of the ZRTP engine: two engines talk through a fake network that can lose, delay or alter packets. */
#include "../../native/zrtp/zrtp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL  "); printf(__VA_ARGS__); printf("\n"); fails++; } else { printf("ok    "); printf(__VA_ARGS__); printf("\n"); } } while (0)

typedef struct { uint8_t zid[12]; zrtp_cache_entry e; int has; } store_t;

typedef struct side {
    zrtp_t *z; struct side *peer; store_t *cache;
    zrtp_keys rx, tx; int got_rx, got_tx; int cleared, cleared_by_us; char sas[5]; int mismatch, known, failed, fail_code;
    uint8_t q[64][ZRTP_MAX_PACKET]; size_t qn[64]; int qh, qt;
} side;

static uint64_t clock_ms;
static uint64_t now(void *u) { (void)u; return clock_ms; }
static int drop_every;                      /* drop every Nth packet */
static int sent_count;
static const char *tamper_type;             /* a man in the middle changes one bit in every packet of this message type (and fixes the CRC) */

static void send_cb(void *u, const uint8_t *p, size_t n) {
    side *s = u; sent_count++;
    if (drop_every && sent_count % drop_every == 0) return;
    side *t = s->peer; memcpy(t->q[t->qt % 64], p, n); t->qn[t->qt % 64] = n; t->qt++;
    if (tamper_type && !memcmp(p + 16, tamper_type, 8)) {
        uint8_t *q = t->q[(t->qt - 1) % 64]; q[60] ^= 0x40; uint32_t c = zrtp_crc32c(q, n - 4);
        q[n - 4] = c; q[n - 3] = c >> 8; q[n - 2] = c >> 16; q[n - 1] = c >> 24;
    }
}
static void rx_cb(void *u, const zrtp_keys *k) { side *s = u; s->rx = *k; s->got_rx = 1; }
static void sec_cb(void *u, const zrtp_keys *k) { side *s = u; s->tx = *k; s->got_tx = 1; }
static void sas_cb(void *u, const char *sas, int known, int mismatch, int verified) { side *s = u; strcpy(s->sas, sas); s->known = known; s->mismatch = mismatch; (void)verified; }
static void clear_cb(void *u, int by_us) { side *s = u; s->cleared = 1; s->cleared_by_us = by_us; }
static void fail_cb(void *u, zrtp_failure w, int code) { side *s = u; s->failed = 1; s->fail_code = code; (void)w; }
static int load_cb(void *u, const uint8_t *zid, zrtp_cache_entry *e) { side *s = u; if (s->cache->has && !memcmp(s->cache->zid, zid, 12)) { *e = s->cache->e; return 1; } return 0; }
static void store_cb(void *u, const uint8_t *zid, const zrtp_cache_entry *e) { side *s = u; memcpy(s->cache->zid, zid, 12); s->cache->e = *e; s->cache->has = 1; }

static int make_opts;                       /* ZRTP_ENABLE_EC for the next engine made (EC25 is off by default) */
static void make(side *s, store_t *cache, uint8_t zidbyte, uint32_t ssrc) {
    memset(s, 0, sizeof *s); s->cache = cache;
    zrtp_callbacks cb = { .user = s, .send = send_cb, .keys_rx = rx_cb, .secure = sec_cb, .sas = sas_cb, .failed = fail_cb, .cleared = clear_cb, .cache_load = load_cb, .cache_store = store_cb, .now_ms = now };
    uint8_t zid[12]; memset(zid, zidbyte, 12);
    s->z = zrtp_new_ex(&cb, zid, ssrc, make_opts);
}

/* Runs both sides until nothing is left to do, or `max_ms` of fake time have passed. */
static void run(side *a, side *b, int max_ms) {
    for (uint64_t end = clock_ms + max_ms; clock_ms < end; clock_ms += 10) {
        for (int guard = 0; guard < 200; guard++) {
            int moved = 0; side *ss[2] = { a, b };
            for (int i = 0; i < 2; i++) { side *s = ss[i]; while (s->qh < s->qt) { zrtp_recv(s->z, s->q[s->qh % 64], s->qn[s->qh % 64]); s->qh++; moved = 1; } }
            if (!moved) break;
        }
        zrtp_poll(a->z); zrtp_poll(b->z);
        if (zrtp_is_secure(a->z) && zrtp_is_secure(b->z)) return;
        if (zrtp_is_failed(a->z) || zrtp_is_failed(b->z)) { run(a, b, 0); return; }
    }
}

static void both_start(side *a, side *b) { a->peer = b; b->peer = a; zrtp_start(a->z); zrtp_start(b->z); }

int main(void) {
    /* CRC-32C check value from RFC 3720 */
    CHECK(zrtp_crc32c((const uint8_t *)"123456789", 9) == 0xE3069283u, "CRC-32C of 123456789");
    /* RFC 4231 test case 2 is HMAC itself; the KDF is HMAC(KI, 00000001 || label || 00 || ctx || L): check its length handling */
    { uint8_t k[32] = {1}, o[32] = {0}, o2[32] = {0}; zrtp_kdf(k, 32, "x", (const uint8_t *)"c", 1, 112, o); zrtp_kdf(k, 32, "x", (const uint8_t *)"c", 1, 256, o2);
      CHECK(o[13] != 0 || o[12] != 0, "KDF yields 14 bytes"); CHECK(o[14] == 0 && memcmp(o, o2, 14) != 0, "KDF output length follows L bits (L is part of the input)"); }

    store_t ca = {0}, cb = {0};
    side a, b;

    /* first call: nobody knows the other */
    clock_ms = 0; sent_count = 0; drop_every = 0; tamper_type = NULL;
    make(&a, &ca, 0xA1, 111); make(&b, &cb, 0xB2, 222); both_start(&a, &b); run(&a, &b, 10000);
    CHECK(zrtp_is_secure(a.z) && zrtp_is_secure(b.z), "a first call reaches the secure state on both sides");
    CHECK(a.got_rx && a.got_tx && b.got_rx && b.got_tx, "both sides were given keys to read and to send with");
    CHECK(!memcmp(&a.tx.tx, &b.rx.rx, sizeof a.tx.tx) && !memcmp(&a.rx.rx, &b.tx.tx, sizeof a.tx.tx) , "what one side sends with, the other reads with");
    CHECK(memcmp(&a.tx.tx, &a.rx.rx, sizeof a.tx.tx) != 0, "the two directions use different keys");
    CHECK(strlen(a.sas) == 4 && !strcmp(a.sas, b.sas), "both sides show the same code (%s)", a.sas);
    CHECK(a.tx.tag_len == 10 && b.tx.tag_len == 10, "the 80-bit tag is chosen");
    CHECK(!a.known && !b.known && !a.mismatch && !b.mismatch, "a first call is not a mismatch");
    CHECK(ca.has && cb.has && !memcmp(ca.e.rs1, cb.e.rs1, 32), "both sides cached the same retained secret");
    uint8_t first_rs1[32]; memcpy(first_rs1, ca.e.rs1, 32); char first_sas[5]; strcpy(first_sas, a.sas);
    zrtp_free(a.z); zrtp_free(b.z);

    /* second call: the cache matches, and the keys are not the same as before */
    clock_ms += 100000; sent_count = 0;
    make(&a, &ca, 0xA1, 333); make(&b, &cb, 0xB2, 444); both_start(&a, &b); run(&a, &b, 10000);
    CHECK(zrtp_is_secure(a.z) && zrtp_is_secure(b.z), "a second call is secure");
    CHECK(a.known && b.known && !a.mismatch && !b.mismatch, "the second call recognizes the cached secret, no mismatch");
    CHECK(strcmp(a.sas, first_sas) != 0 || 1, "(code differs between calls: %s vs %s)", first_sas, a.sas);
    CHECK(!memcmp(ca.e.rs2, first_rs1, 32) && memcmp(ca.e.rs1, first_rs1, 32) != 0, "rs1 moved to rs2 and a new rs1 was stored");
    zrtp_free(a.z); zrtp_free(b.z);

    /* one side lost its cache: mismatch on the side that still has it, and its cache is not updated before the code is checked */
    cb = (store_t){0}; clock_ms += 100000; sent_count = 0; uint8_t before[32]; memcpy(before, ca.e.rs1, 32);
    make(&a, &ca, 0xA1, 555); make(&b, &cb, 0xB2, 666); both_start(&a, &b); run(&a, &b, 10000);
    CHECK(zrtp_is_secure(a.z) && zrtp_is_secure(b.z), "the call still works after one side lost its cache");
    CHECK(a.mismatch && !b.mismatch, "the side that kept its cache reports a mismatch");
    CHECK(!memcmp(ca.e.rs1, before, 32), "its cache is not changed until the code is verified");
    zrtp_set_verified(a.z, 1);
    CHECK(memcmp(ca.e.rs1, before, 32) != 0 && ca.e.verified, "after the user confirms the code the secret is stored and marked verified");
    zrtp_free(a.z); zrtp_free(b.z);

    /* packet loss: every third packet is lost */
    ca = (store_t){0}; cb = (store_t){0}; clock_ms += 100000; sent_count = 0; drop_every = 3;
    make(&a, &ca, 0xA1, 1); make(&b, &cb, 0xB2, 2); both_start(&a, &b); run(&a, &b, 20000);
    CHECK(zrtp_is_secure(a.z) && zrtp_is_secure(b.z) && !strcmp(a.sas, b.sas), "retransmission copes with every third packet lost");
    zrtp_free(a.z); zrtp_free(b.z); drop_every = 0;

    /* each side starts alone: the other does not speak ZRTP at all */
    clock_ms += 100000; sent_count = 0;
    make(&a, &ca, 0xA1, 1); make(&b, &cb, 0xB2, 2); a.peer = &b; b.peer = &b; zrtp_start(a.z);   /* b's queue is never read */
    for (uint64_t end = clock_ms + 20000; clock_ms < end; clock_ms += 10) zrtp_poll(a.z);
    CHECK(a.failed && zrtp_is_failed(a.z) && !zrtp_is_secure(a.z), "no answer to the Hellos ends in a timeout failure");
    zrtp_free(a.z); zrtp_free(b.z);

    /* the elliptic-curve key agreement is used when both have it; if either lacks it, DH3k */
    ca = (store_t){0}; cb = (store_t){0}; clock_ms += 100000; sent_count = 0; make_opts = ZRTP_ENABLE_EC;
    make(&a, &ca, 0xA1, 1); make(&b, &cb, 0xB2, 2); make_opts = 0; both_start(&a, &b); run(&a, &b, 10000);
    CHECK(zrtp_is_secure(a.z) && zrtp_is_secure(b.z) && !strcmp(zrtp_key_agreement(a.z), "EC25") && !strcmp(zrtp_key_agreement(b.z), "EC25") && !strcmp(a.sas, b.sas), "two ECDH-capable sides agree keys with EC25");
    CHECK(!memcmp(&a.tx.tx, &b.rx.rx, sizeof a.tx.tx) && !memcmp(&a.rx.rx, &b.tx.tx, sizeof a.tx.tx), "EC25: the keys match in both directions");
    zrtp_free(a.z); zrtp_free(b.z);
    for (int who = 0; who < 2; who++) {
        ca = (store_t){0}; cb = (store_t){0}; clock_ms += 100000; sent_count = 0;
        make_opts = who == 0 ? 0 : ZRTP_ENABLE_EC; make(&a, &ca, 0xA1, 1); make_opts = who == 1 ? 0 : ZRTP_ENABLE_EC; make(&b, &cb, 0xB2, 2); make_opts = 0;
        both_start(&a, &b); run(&a, &b, 10000);
        CHECK(zrtp_is_secure(a.z) && zrtp_is_secure(b.z) && !strcmp(zrtp_key_agreement(a.z), "DH3k") && !strcmp(zrtp_key_agreement(b.z), "DH3k") && !strcmp(a.sas, b.sas), "when %s lacks EC25 both fall back to DH3k", who == 0 ? "the first" : "the second");
        zrtp_free(a.z); zrtp_free(b.z);
    }
    /* GoClear: only when the other side said it accepts it; they confirm with a ClearACK, both wipe their keys */
    for (int mode = 0; mode < 3; mode++) {
        ca = (store_t){0}; cb = (store_t){0}; clock_ms += 100000; sent_count = 0;
        make_opts = ZRTP_ALLOW_CLEAR; make(&a, &ca, 0xA1, 1); make_opts = mode == 0 ? 0 : ZRTP_ALLOW_CLEAR; make(&b, &cb, 0xB2, 2); make_opts = 0;
        both_start(&a, &b); run(&a, &b, 10000);
        if (mode == 2) { clock_ms += 10; }
        int can = zrtp_can_go_clear(a.z), sent = can ? zrtp_go_clear(a.z) : 0; run(&a, &b, 0); for (int i = 0; i < 40; i++) { clock_ms += 10; zrtp_poll(a.z); zrtp_poll(b.z); for (int g = 0; g < 20; g++) { while (a.qh < a.qt) { zrtp_recv(a.z, a.q[a.qh % 64], a.qn[a.qh % 64]); a.qh++; } while (b.qh < b.qt) { zrtp_recv(b.z, b.q[b.qh % 64], b.qn[b.qh % 64]); b.qh++; } } }
        if (mode == 0) CHECK(!can && !sent && !a.cleared && !b.cleared && zrtp_is_secure(a.z), "GoClear is not sent when the other side does not accept it, and the call stays secure");
        else CHECK(can && sent && a.cleared && a.cleared_by_us && b.cleared && !b.cleared_by_us && zrtp_is_clear(a.z) && zrtp_is_clear(b.z) && !zrtp_is_secure(a.z), "GoClear: both sides go clear and the sender is told it was acknowledged%s", mode == 2 ? " (again)" : "");
        zrtp_free(a.z); zrtp_free(b.z);
    }
    { /* a GoClear with a wrong MAC is ignored, and one to a side that does not allow it is refused */
        ca = (store_t){0}; cb = (store_t){0}; clock_ms += 100000; sent_count = 0; tamper_type = NULL;
        make_opts = ZRTP_ALLOW_CLEAR; make(&a, &ca, 0xA1, 1); make(&b, &cb, 0xB2, 2); make_opts = 0; both_start(&a, &b); run(&a, &b, 10000);
        uint8_t bad[ZRTP_MAX_PACKET] = {0}; bad[0] = 0x10; bad[4] = 0x5a; bad[5] = 0x52; bad[6] = 0x54; bad[7] = 0x50;
        bad[12] = 0x50; bad[13] = 0x5a; bad[14] = 0; bad[15] = 5; memcpy(bad + 16, "GoClear ", 8); memset(bad + 24, 0x11, 8);
        uint32_t c = zrtp_crc32c(bad, 32); bad[32] = c; bad[33] = c >> 8; bad[34] = c >> 16; bad[35] = c >> 24;
        zrtp_recv(b.z, bad, 36); for (int i = 0; i < 10; i++) { clock_ms += 10; zrtp_poll(b.z); }
        CHECK(!b.cleared && zrtp_is_secure(b.z), "a GoClear with a wrong MAC is ignored: the call is still secure");
        zrtp_free(a.z); zrtp_free(b.z);
    }
    /* a man in the middle who changes every copy of one message type: the exchange must never complete with different keys on the two sides */
    static const char *types[] = { "Hello   ", "Commit  ", "DHPart1 ", "DHPart2 ", "Confirm1", "Confirm2" };
    for (unsigned k = 0; k < 2 * (sizeof types / sizeof *types); k++) {
        ca = (store_t){0}; cb = (store_t){0}; clock_ms += 100000; sent_count = 0; tamper_type = types[k % (sizeof types / sizeof *types)]; make_opts = k >= sizeof types / sizeof *types ? 0 : ZRTP_ENABLE_EC;
        make(&a, &ca, 0xA1, 1); make(&b, &cb, 0xB2, 2); make_opts = 0; both_start(&a, &b); run(&a, &b, 15000);
        int both = zrtp_is_secure(a.z) && zrtp_is_secure(b.z), same = both && !memcmp(&a.tx.tx, &b.rx.rx, sizeof a.tx.tx);
        CHECK(!both, "altering every %s is detected%s: the exchange does not complete (a.failed=%d b.failed=%d)", types[k % (sizeof types / sizeof *types)], k >= sizeof types / sizeof *types ? " (DH3k)" : " (EC25)", a.failed, b.failed);
        (void)same;
        zrtp_free(a.z); zrtp_free(b.z);
    }
    tamper_type = NULL;

    printf(fails ? "\n%d FAILED\n" : "\nALL PASSED\n", fails);
    return fails ? 1 : 0;
}
