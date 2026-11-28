/* ZRTP (RFC 6189) key agreement engine. See zrtp.h. */
#include "zrtp.h"

#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/param_build.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/rand.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "zrtp_dh3k.inc"

#define MAXMSG 480
#define DH3K_BYTES 384

/* ---------- small helpers ---------- */

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static int eq(const uint8_t *a, const uint8_t *b, size_t n) { return CRYPTO_memcmp(a, b, n) == 0; }
static int rnd(uint8_t *p, size_t n) { return RAND_bytes(p, (int)n) == 1; }

static void sha256(const uint8_t *d, size_t n, uint8_t out[32]) {
    size_t ol = 0; EVP_Q_digest(NULL, "SHA256", NULL, d, n, out, &ol);
}
static void hmac256(const uint8_t *key, size_t kl, const uint8_t *d, size_t n, uint8_t out[32]) {
    size_t ol = 0; EVP_Q_mac(NULL, "HMAC", NULL, "SHA256", NULL, key, kl, d, n, out, 32, &ol);
}

/* A growing buffer, to hash or MAC several pieces at once. */
typedef struct { uint8_t *p; size_t n, cap; } buf_t;
static void bput(buf_t *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, d, n); b->n += n;
}
static void bput32(buf_t *b, uint32_t v) { uint8_t t[4]; put32(t, v); bput(b, t, 4); }
static void bfree(buf_t *b) { if (b->p) { OPENSSL_cleanse(b->p, b->cap); free(b->p); } b->p = NULL; b->n = b->cap = 0; }

void zrtp_kdf(const uint8_t *ki, size_t ki_len, const char *label, const uint8_t *ctx, size_t ctx_len, uint32_t bits, uint8_t *out) {
    buf_t b = {0}; uint8_t mac[32], zero = 0;
    bput32(&b, 1); bput(&b, label, strlen(label)); bput(&b, &zero, 1); bput(&b, ctx, ctx_len); bput32(&b, bits);
    hmac256(ki, ki_len, b.p, b.n, mac); bfree(&b);
    memcpy(out, mac, (bits + 7) / 8); OPENSSL_cleanse(mac, sizeof mac);
}

uint32_t zrtp_crc32c(const uint8_t *data, size_t len) {
    static uint32_t table[256]; static int ready;
    if (!ready) { for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = c & 1 ? (c >> 1) ^ 0x82F63B78u : c >> 1; table[i] = c; } ready = 1; }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

/* ---------- state ---------- */

typedef enum { Z_HELLO, Z_COMMIT, Z_DH2, Z_CONF2, Z_DH1, Z_CONF1, Z_SECURE, Z_CLEARING, Z_CLEAR, Z_FAILED } zstate;

typedef struct { uint8_t m[MAXMSG]; size_t n; } msg_t;

/* Retransmission of one message (identical every time), as the RFC's section 6 schedules it. */
typedef struct { const msg_t *msg; int active, count, max; uint32_t interval, cap; uint64_t due; } retry_t;

struct zrtp {
    zrtp_callbacks cb;
    zstate st;
    uint8_t zid[ZRTP_ZID_LEN], peer_zid[ZRTP_ZID_LEN];
    uint32_t ssrc; uint16_t seq; int started;
    uint8_t h0[32], h1[32], h2[32], h3[32];                  /* our hash chain */

    msg_t hello, peer_hello, commit, dh1, dh2, confirm;      /* confirm: the Confirm we sent last */
    int have_peer_hello, hello_acked, initiator;
    uint8_t peer_h3[32], peer_h2[32], peer_h1[32];           /* the other side's hash chain as it is revealed */
    int auth80;                                              /* chosen SRTP tag: 1 = HS80, 0 = HS32 */

    BIGNUM *x, *pub;                                         /* our DH secret and public value */
    EVP_PKEY *ec; uint8_t ecpub[64]; int kex, kex_made;      /* kex: 0 = DH3k, 1 = EC25; kex_made: which one x/pub or ec hold (1 + kex), 0 = none */
    int allow_clear, peer_allows_clear; msg_t clear_msg;     /* GoClear: we accept it from the other side / they accept it from us */
    int no_ec;                                               /* do not offer EC25 (tests, and peers that cannot do it) */
    uint8_t hvi[32];

    zrtp_cache_entry ce; int had_entry;                      /* what we remember about this peer */
    uint8_t rs1id_i[8], rs2id_i[8], rs1id_r[8], rs2id_r[8];  /* the ids we sent (random where we have no secret) */

    uint8_t total_hash[32], ctx[56];
    uint8_t s0[32];
    zrtp_keys keys; int have_keys;
    uint8_t mackey_i[32], mackey_r[32], zrtpkey_i[16], zrtpkey_r[16];
    uint8_t new_rs1[32]; int cache_mismatch, cache_pending; uint32_t peer_expires; int peer_verified;
    char sas[5];

    retry_t rt;
};

static uint64_t now(zrtp_t *z) {
    if (z->cb.now_ms) return z->cb.now_ms(z->cb.user);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---------- packets ---------- */

static void send_msg(zrtp_t *z, const msg_t *m) {
    uint8_t pkt[ZRTP_MAX_PACKET]; if (m->n + 16 > sizeof pkt) return;
    pkt[0] = 0x10; pkt[1] = 0x00; pkt[2] = z->seq >> 8; pkt[3] = (uint8_t)z->seq; z->seq++;
    put32(pkt + 4, 0x5a525450); put32(pkt + 8, z->ssrc);
    memcpy(pkt + 12, m->m, m->n);
    { uint32_t c = zrtp_crc32c(pkt, 12 + m->n); uint8_t *w = pkt + 12 + m->n; w[0] = c; w[1] = c >> 8; w[2] = c >> 16; w[3] = c >> 24; }      /* the CRC goes out least significant byte first, as in SCTP */
    z->cb.send(z->cb.user, pkt, 16 + m->n);
}

static void retry_stop(zrtp_t *z) { z->rt.active = 0; }
static void retry_start(zrtp_t *z, const msg_t *m, uint32_t first, uint32_t cap, int max) {
    z->rt = (retry_t){ .msg = m, .active = 1, .count = 0, .max = max, .interval = first, .cap = cap, .due = now(z) + first };
    send_msg(z, m);
}

static void msg_begin(msg_t *m, const char type[8]) { memset(m, 0, sizeof *m); m->m[0] = 0x50; m->m[1] = 0x5a; memcpy(m->m + 4, type, 8); m->n = 12; }
static void msg_put(msg_t *m, const void *d, size_t n) { memcpy(m->m + m->n, d, n); m->n += n; }
static void msg_end_plain(msg_t *m) { m->m[2] = (m->n / 4) >> 8; m->m[3] = (m->n / 4) & 0xff; }
/* Ends a message with the 64-bit MAC (HMAC-SHA-256, first 8 bytes) over everything before it, keyed with a hash chain value. */
static void msg_end_mac(msg_t *m, const uint8_t key[32]) {
    uint8_t mac[32]; m->m[2] = ((m->n + 8) / 4) >> 8; m->m[3] = ((m->n + 8) / 4) & 0xff;
    hmac256(key, 32, m->m, m->n, mac); msg_put(m, mac, 8);
}
static int mac_ok(const msg_t *m, const uint8_t key[32]) {
    uint8_t mac[32]; if (m->n < 12 + 8) return 0;
    hmac256(key, 32, m->m, m->n - 8, mac); return eq(mac, m->m + m->n - 8, 8);
}
static int is_type(const uint8_t *m, const char *t) { return memcmp(m + 4, t, 8) == 0; }

/* ---------- Diffie-Hellman ---------- */

static BIGNUM *dh_p(void) { return BN_bin2bn(DH3K_P, sizeof DH3K_P, NULL); }

static int dh_generate(zrtp_t *z) {
    if (z->x) return 1;
    uint8_t sec[32]; BN_CTX *c = BN_CTX_new(); BIGNUM *p = dh_p(), *g = BN_new(), *pub = BN_new();
    int ok = c && p && g && pub && rnd(sec, sizeof sec);
    if (ok) { sec[0] |= 0x80; z->x = BN_bin2bn(sec, sizeof sec, NULL); BN_set_word(g, 2); ok = z->x && BN_mod_exp(pub, g, z->x, p, c); }
    OPENSSL_cleanse(sec, sizeof sec);
    if (ok) z->pub = pub; else BN_free(pub);
    BN_free(g); BN_free(p); BN_CTX_free(c);
    return ok;
}

/* The peer's public value must be neither 0, 1 nor p-1 (and below p). */
static int dh_valid(const uint8_t *pv) {
    BIGNUM *v = BN_bin2bn(pv, DH3K_BYTES, NULL), *p = dh_p(), *pm1 = BN_new(); int ok = 0;
    if (v && p && pm1) { BN_copy(pm1, p); BN_sub_word(pm1, 1); ok = BN_cmp(v, BN_value_one()) > 0 && BN_cmp(v, pm1) < 0; }
    BN_free(v); BN_free(p); BN_free(pm1); return ok;
}

static int dh_result(zrtp_t *z, const uint8_t *peer_pv, uint8_t out[DH3K_BYTES]) {
    BN_CTX *c = BN_CTX_new(); BIGNUM *v = BN_bin2bn(peer_pv, DH3K_BYTES, NULL), *p = dh_p(), *r = BN_new();
    int ok = c && v && p && r && BN_mod_exp(r, v, z->x, p, c) && BN_bn2binpad(r, out, DH3K_BYTES) == DH3K_BYTES;
    BN_clear_free(r); BN_free(v); BN_free(p); BN_CTX_free(c); return ok;
}

static void pub_bytes(zrtp_t *z, uint8_t out[DH3K_BYTES]) { BN_bn2binpad(z->pub, out, DH3K_BYTES); }

/* ---------- key agreement: DH3k (RFC 3526 group) or EC25 (ECDH on NIST P-256, public value X||Y) ---------- */

#define EC25_PV 64
static size_t pv_len(int kex) { return kex ? EC25_PV : DH3K_BYTES; }

static int kex_generate(zrtp_t *z) {
    if (z->kex_made == z->kex + 1) return 1;                 /* already made for this algorithm */
    BN_clear_free(z->x); BN_free(z->pub); EVP_PKEY_free(z->ec); z->x = NULL; z->pub = NULL; z->ec = NULL; z->kex_made = 0;
    if (!z->kex) { if (!dh_generate(z)) return 0; z->kex_made = 1; return 1; }
    z->ec = EVP_EC_gen("P-256");
    uint8_t buf[80]; size_t len = 0;
    if (!z->ec || EVP_PKEY_get_octet_string_param(z->ec, OSSL_PKEY_PARAM_PUB_KEY, buf, sizeof buf, &len) != 1 || len != 65 || buf[0] != 4) return 0;
    memcpy(z->ecpub, buf + 1, EC25_PV); z->kex_made = 2; return 1;
}

static void kex_pub(zrtp_t *z, uint8_t *out) { if (z->kex) memcpy(out, z->ecpub, EC25_PV); else pub_bytes(z, out); }

/* The peer's public value must be a valid one: for DH neither 0, 1 nor p-1; for EC a point on the curve. */
static int kex_valid(int kex, const uint8_t *pv) {
    if (!kex) return dh_valid(pv);
    uint8_t buf[65]; buf[0] = 4; memcpy(buf + 1, pv, EC25_PV);
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new(); OSSL_PARAM *par = NULL; EVP_PKEY_CTX *ctx = NULL, *chk = NULL; EVP_PKEY *k = NULL; int ok = 0;
    if (bld && OSSL_PARAM_BLD_push_utf8_string(bld, OSSL_PKEY_PARAM_GROUP_NAME, "P-256", 0) && OSSL_PARAM_BLD_push_octet_string(bld, OSSL_PKEY_PARAM_PUB_KEY, buf, sizeof buf) && (par = OSSL_PARAM_BLD_to_param(bld))
        && (ctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL)) && EVP_PKEY_fromdata_init(ctx) == 1 && EVP_PKEY_fromdata(ctx, &k, EVP_PKEY_PUBLIC_KEY, par) == 1 && k
        && (chk = EVP_PKEY_CTX_new_from_pkey(NULL, k, NULL))) ok = EVP_PKEY_public_check(chk) == 1;
    EVP_PKEY_CTX_free(chk); EVP_PKEY_free(k); EVP_PKEY_CTX_free(ctx); OSSL_PARAM_free(par); OSSL_PARAM_BLD_free(bld); return ok;
}

/* The shared secret: DH gives 384 bytes, EC the 32-byte X coordinate. Returns its length, 0 on failure. */
static size_t kex_result(zrtp_t *z, const uint8_t *peer_pv, uint8_t out[DH3K_BYTES]) {
    if (!z->kex) return dh_result(z, peer_pv, out) ? DH3K_BYTES : 0;
    uint8_t buf[65]; buf[0] = 4; memcpy(buf + 1, peer_pv, EC25_PV);
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new(); OSSL_PARAM *par = NULL; EVP_PKEY_CTX *ctx = NULL, *dctx = NULL; EVP_PKEY *peer = NULL; size_t len = 0, ret = 0;
    if (bld && OSSL_PARAM_BLD_push_utf8_string(bld, OSSL_PKEY_PARAM_GROUP_NAME, "P-256", 0) && OSSL_PARAM_BLD_push_octet_string(bld, OSSL_PKEY_PARAM_PUB_KEY, buf, sizeof buf) && (par = OSSL_PARAM_BLD_to_param(bld))
        && (ctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL)) && EVP_PKEY_fromdata_init(ctx) == 1 && EVP_PKEY_fromdata(ctx, &peer, EVP_PKEY_PUBLIC_KEY, par) == 1 && peer
        && (dctx = EVP_PKEY_CTX_new(z->ec, NULL)) && EVP_PKEY_derive_init(dctx) == 1 && EVP_PKEY_derive_set_peer(dctx, peer) == 1
        && EVP_PKEY_derive(dctx, NULL, &len) == 1 && len == 32 && EVP_PKEY_derive(dctx, out, &len) == 1 && len == 32) ret = 32;
    EVP_PKEY_CTX_free(dctx); EVP_PKEY_free(peer); EVP_PKEY_CTX_free(ctx); OSSL_PARAM_free(par); OSSL_PARAM_BLD_free(bld); return ret;
}

/* ---------- failure ---------- */

static void fail(zrtp_t *z, zrtp_failure why, int code, int send_error) {
    if (z->st == Z_FAILED) return;
    z->st = Z_FAILED; retry_stop(z);
    if (send_error) {
        msg_t e; msg_begin(&e, "Error   "); uint8_t c[4]; put32(c, (uint32_t)code); msg_put(&e, c, 4); msg_end_plain(&e);
        send_msg(z, &e);
    }
    if (z->cb.failed) z->cb.failed(z->cb.user, why, code);
}

/* ---------- lifecycle ---------- */

zrtp_t *zrtp_new(const zrtp_callbacks *cb, const uint8_t zid[ZRTP_ZID_LEN], uint32_t ssrc) { return zrtp_new_ex(cb, zid, ssrc, 0); }

zrtp_t *zrtp_new_ex(const zrtp_callbacks *cb, const uint8_t zid[ZRTP_ZID_LEN], uint32_t ssrc, int opts) {
    zrtp_t *z = calloc(1, sizeof *z); if (!z) return NULL;
    z->no_ec = (opts & ZRTP_ENABLE_EC) == 0; z->allow_clear = (opts & ZRTP_ALLOW_CLEAR) != 0;
    z->cb = *cb; memcpy(z->zid, zid, ZRTP_ZID_LEN); z->ssrc = ssrc; z->st = Z_HELLO;
    uint8_t s[2]; rnd(s, 2); z->seq = (uint16_t)(s[0] << 8 | s[1]);
    rnd(z->h0, 32); sha256(z->h0, 32, z->h1); sha256(z->h1, 32, z->h2); sha256(z->h2, 32, z->h3);
    /* Hello: version 1.10, one hash (S256), one cipher (AES1), two tags (HS80, HS32), one key agreement (DH3k), one SAS type (B32). */
    msg_t *h = &z->hello; msg_begin(h, "Hello   ");
    msg_put(h, "1.10", 4); msg_put(h, "L1ne ZRTP 0.1   ", 16); msg_put(h, z->h3, 32); msg_put(h, zid, ZRTP_ZID_LEN);
    /* the 32-bit word: 0 S M P | 8 unused | hc cc ac kc sc (4 bits each) */
    uint8_t flags[4];
    uint32_t w = (1u << 16) | (1u << 12) | (2u << 8) | ((z->no_ec ? 1u : 2u) << 4) | 1u; put32(flags, w);
    msg_put(h, flags, 4);
    msg_put(h, "S256", 4); msg_put(h, "AES1", 4); msg_put(h, "HS80", 4); msg_put(h, "HS32", 4); if (!z->no_ec) msg_put(h, "EC25", 4);                    /* the faster of the two, preferred */
    msg_put(h, "DH3k", 4); msg_put(h, "B32 ", 4);
    msg_end_mac(h, z->h2);
    return z;
}

void zrtp_free(zrtp_t *z) {
    if (!z) return;
    BN_clear_free(z->x); BN_free(z->pub); EVP_PKEY_free(z->ec); OPENSSL_cleanse(z, sizeof *z); free(z);
}

void zrtp_start(zrtp_t *z) {
    if (z->started) return; z->started = 1;
    retry_start(z, &z->hello, 50, 200, 62);                  /* 50, 100, then 200 ms: about 12 seconds in all */
}

void zrtp_set_ssrc(zrtp_t *z, uint32_t ssrc) { z->ssrc = ssrc; }
void zrtp_hello_hash(const zrtp_t *z, uint8_t out[32]) { sha256(z->hello.m, z->hello.n, out); }

int zrtp_is_zrtp(const uint8_t *p, size_t n) { return n >= 16 && p[0] == 0x10 && p[1] == 0x00 && be32(p + 4) == 0x5a525450; }
const char *zrtp_key_agreement(const zrtp_t *z) { return z->kex ? "EC25" : "DH3k"; }
int zrtp_is_secure(const zrtp_t *z) { return z->st == Z_SECURE; }
int zrtp_is_failed(const zrtp_t *z) { return z->st == Z_FAILED; }
const char *zrtp_sas(const zrtp_t *z) { return z->sas; }

static void do_clear(zrtp_t *z, int by_us);

int zrtp_poll(zrtp_t *z) {
    if (!z->rt.active) return -1;
    uint64_t t = now(z);
    while (z->rt.active && t >= z->rt.due) {
        if (++z->rt.count >= z->rt.max) {                    /* nobody answered */
            int hello = z->st == Z_HELLO; retry_stop(z);
            if (z->st == Z_CLEARING) { do_clear(z, 1); return -1; }          /* nobody acknowledged the GoClear: the keys go anyway (section 4.7.2) */
            if (hello && z->have_peer_hello) { return -1; }  /* they spoke ZRTP but never acknowledged; their Commit may still arrive */
            fail(z, ZRTP_FAIL_TIMEOUT, 0xB0, !hello); return -1;
        }
        send_msg(z, z->rt.msg);
        z->rt.interval = z->rt.interval * 2 > z->rt.cap ? z->rt.cap : z->rt.interval * 2;
        z->rt.due = t + z->rt.interval;
    }
    if (!z->rt.active) return -1;
    return (int)(z->rt.due > t ? z->rt.due - t : 0);
}

/* ---------- key derivation shared by both roles ---------- */

static void sha_cat(const msg_t *a, const msg_t *b, const msg_t *c, const msg_t *d, uint8_t out[32]) {
    buf_t x = {0}; bput(&x, a->m, a->n); bput(&x, b->m, b->n); bput(&x, c->m, c->n); bput(&x, d->m, d->n); sha256(x.p, x.n, out); bfree(&x);
}

/* The id of a retained secret as sent in DHPart1/DHPart2: MAC(secret, "Initiator"/"Responder") cut to 64 bits; random when we have none. */
static void secret_id(const uint8_t *secret, int have, const char *who, uint8_t out[8]) {
    uint8_t m[32]; if (!have) { rnd(out, 8); return; }
    hmac256(secret, 32, (const uint8_t *)who, strlen(who), m); memcpy(out, m, 8);
}

static void prepare_ids(zrtp_t *z) {
    secret_id(z->ce.rs1, z->ce.has_rs1, "Initiator", z->rs1id_i); secret_id(z->ce.rs2, z->ce.has_rs2, "Initiator", z->rs2id_i);
    secret_id(z->ce.rs1, z->ce.has_rs1, "Responder", z->rs1id_r); secret_id(z->ce.rs2, z->ce.has_rs2, "Responder", z->rs2id_r);
}

/* Which of our retained secrets the other side shares (section 4.3). `theirs1`/`theirs2` are the ids they sent; `who` is OUR role's tag used by
 * the other side for the ids ("Responder" when they are the responder). Returns the secret to use as s1, or NULL. */
static const uint8_t *shared_s1(zrtp_t *z, const uint8_t theirs1[8], const uint8_t theirs2[8], const char *their_role) {
    uint8_t id[8];
    const uint8_t *mine[2] = { z->ce.has_rs1 ? z->ce.rs1 : NULL, z->ce.has_rs2 ? z->ce.rs2 : NULL };
    if (!mine[0] && !mine[1]) return NULL;
    /* first the initiator's rs1, then its rs2; "initiator's" = ours when we are the initiator, theirs otherwise */
    if (z->initiator) {
        for (int k = 0; k < 2; k++) { if (!mine[k]) continue; secret_id(mine[k], 1, their_role, id); if (eq(id, theirs1, 8) || eq(id, theirs2, 8)) return mine[k]; }
        return NULL;
    }
    for (int t = 0; t < 2; t++) {
        const uint8_t *their = t == 0 ? theirs1 : theirs2;
        for (int k = 0; k < 2; k++) { if (!mine[k]) continue; secret_id(mine[k], 1, their_role, id); if (eq(id, their, 8)) return mine[k]; }
    }
    return NULL;
}

/* From the DH result and the exchanged messages to every key we need. Fills ctx, keys, SAS, confirm keys and the new retained secret. */
static int derive(zrtp_t *z, const uint8_t *dhresult, size_t dhlen, const uint8_t *s1) {
    const uint8_t *zid_i = z->initiator ? z->zid : z->peer_zid, *zid_r = z->initiator ? z->peer_zid : z->zid;
    const msg_t *hello_r = z->initiator ? &z->peer_hello : &z->hello;
    sha_cat(hello_r, &z->commit, &z->dh1, &z->dh2, z->total_hash);
    buf_t b = {0};
    bput32(&b, 1); bput(&b, dhresult, dhlen); bput(&b, "ZRTP-HMAC-KDF", 13); bput(&b, zid_i, 12); bput(&b, zid_r, 12); bput(&b, z->total_hash, 32);
    bput32(&b, s1 ? 32 : 0); if (s1) bput(&b, s1, 32);
    bput32(&b, 0);                                           /* s2: no auxiliary secret */
    bput32(&b, 0);                                           /* s3: no PBX secret */
    sha256(b.p, b.n, z->s0); bfree(&b);
    memcpy(z->ctx, zid_i, 12); memcpy(z->ctx + 12, zid_r, 12); memcpy(z->ctx + 24, z->total_hash, 32);
    uint8_t ki[16], si[14], kr[16], sr[14], sashash[32];
    zrtp_kdf(z->s0, 32, "Initiator SRTP master key", z->ctx, 56, 128, ki);  zrtp_kdf(z->s0, 32, "Initiator SRTP master salt", z->ctx, 56, 112, si);
    zrtp_kdf(z->s0, 32, "Responder SRTP master key", z->ctx, 56, 128, kr);  zrtp_kdf(z->s0, 32, "Responder SRTP master salt", z->ctx, 56, 112, sr);
    zrtp_kdf(z->s0, 32, "Initiator HMAC key", z->ctx, 56, 256, z->mackey_i); zrtp_kdf(z->s0, 32, "Responder HMAC key", z->ctx, 56, 256, z->mackey_r);
    zrtp_kdf(z->s0, 32, "Initiator ZRTP key", z->ctx, 56, 128, z->zrtpkey_i); zrtp_kdf(z->s0, 32, "Responder ZRTP key", z->ctx, 56, 128, z->zrtpkey_r);
    zrtp_kdf(z->s0, 32, "SAS", z->ctx, 56, 256, sashash);
    zrtp_kdf(z->s0, 32, "retained secret", z->ctx, 56, 256, z->new_rs1);
    static const char alphabet[] = "ybndrfg8ejkmcpqxot1uwisza345h769";
    uint32_t sasvalue = be32(sashash);
    for (int i = 0, shift = 27; i < 4; i++, shift -= 5) z->sas[i] = alphabet[(sasvalue >> shift) & 31];
    z->sas[4] = 0;
    z->keys.tag_len = z->auth80 ? 10 : 4;
    if (z->initiator) { memcpy(z->keys.tx.key, ki, 16); memcpy(z->keys.tx.salt, si, 14); memcpy(z->keys.rx.key, kr, 16); memcpy(z->keys.rx.salt, sr, 14); }
    else              { memcpy(z->keys.tx.key, kr, 16); memcpy(z->keys.tx.salt, sr, 14); memcpy(z->keys.rx.key, ki, 16); memcpy(z->keys.rx.salt, si, 14); }
    z->have_keys = 1;
    OPENSSL_cleanse(ki, 16); OPENSSL_cleanse(kr, 16); OPENSSL_cleanse(sashash, 32);
    z->cache_mismatch = z->had_entry && z->ce.has_rs1 && !s1;
    OPENSSL_cleanse(z->s0, sizeof z->s0);
    return 1;
}

/* ---------- Confirm ---------- */

static int cfb(const uint8_t key[16], const uint8_t iv[16], const uint8_t *in, size_t n, uint8_t *out, int enc) {
    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new(); int l = 0, l2 = 0, ok = 0;
    if (c && EVP_CipherInit_ex(c, EVP_aes_128_cfb128(), NULL, key, iv, enc) == 1 && EVP_CipherUpdate(c, out, &l, in, (int)n) == 1 && EVP_CipherFinal_ex(c, out + l, &l2) == 1) ok = 1;
    EVP_CIPHER_CTX_free(c); return ok;
}

static void build_confirm(zrtp_t *z, int responder) {
    msg_t *m = &z->confirm; msg_begin(m, responder ? "Confirm1" : "Confirm2");
    uint8_t plain[40], iv[16], ct[40], mac[32];
    memcpy(plain, z->h0, 32);
    uint32_t flags = (z->ce.verified ? 0x4 : 0) | (z->allow_clear ? 0x2 : 0);     /* V: SAS verified earlier; A: we accept GoClear */               /* V: we verified the SAS with this peer in an earlier call */
    put32(plain + 32, flags); put32(plain + 36, 0xffffffffu);
    rnd(iv, 16);
    cfb(responder ? z->zrtpkey_r : z->zrtpkey_i, iv, plain, 40, ct, 1);
    hmac256(responder ? z->mackey_r : z->mackey_i, 32, ct, 40, mac);
    msg_put(m, mac, 8); msg_put(m, iv, 16); msg_put(m, ct, 40);
    msg_end_plain(m); OPENSSL_cleanse(plain, sizeof plain);
}

/* Checks and opens a received Confirm. Gives H0, the flags and the cache expiry. */
static int open_confirm(zrtp_t *z, const msg_t *m, int from_responder, uint8_t h0[32], uint32_t *flags, uint32_t *expires) {
    if (m->n < 76) return 0;
    uint8_t mac[32], plain[40];
    if (m->n != 76) return 0;
    hmac256(from_responder ? z->mackey_r : z->mackey_i, 32, m->m + 36, 40, mac);
    if (!eq(mac, m->m + 12, 8)) return 0;
    cfb(from_responder ? z->zrtpkey_r : z->zrtpkey_i, m->m + 20, m->m + 36, 40, plain, 0);
    memcpy(h0, plain, 32); *flags = be32(plain + 32); *expires = be32(plain + 36);
    OPENSSL_cleanse(plain, sizeof plain); return 1;
}

/* ---------- cache ---------- */

static void store_cache(zrtp_t *z) {
    uint32_t exp = z->peer_expires < 0xffffffffu ? z->peer_expires : 0xffffffffu;
    if (exp == 0) return;
    zrtp_cache_entry e = z->ce;
    if (e.has_rs1) { memcpy(e.rs2, e.rs1, 32); e.has_rs2 = 1; }
    memcpy(e.rs1, z->new_rs1, 32); e.has_rs1 = 1; e.expires = exp;
    if (z->cb.cache_store) z->cb.cache_store(z->cb.user, z->peer_zid, &e);
    z->ce = e; z->cache_pending = 0;
}

static void update_cache(zrtp_t *z) {
    if (z->cache_mismatch && !z->ce.verified) { z->cache_pending = 1; return; }      /* section 4.6.1.1: not before the user has compared the code */
    store_cache(z);
}

void zrtp_set_verified(zrtp_t *z, int verified) {
    if (!z->have_keys) return;
    if (verified) {
        z->ce.verified = 1;
        if (z->cache_pending) store_cache(z);
        else if (z->cb.cache_store && z->ce.has_rs1) z->cb.cache_store(z->cb.user, z->peer_zid, &z->ce);
    } else {                                                 /* the code did not match: do not trust what this peer left in the cache */
        memset(&z->ce, 0, sizeof z->ce); z->cache_pending = 0;
        if (z->cb.cache_store) z->cb.cache_store(z->cb.user, z->peer_zid, &z->ce);
    }
}

/* ---------- handlers ---------- */

static void go_secure(zrtp_t *z) {
    retry_stop(z); z->st = Z_SECURE;
    update_cache(z);
    if (z->cb.secure) z->cb.secure(z->cb.user, &z->keys);
}

static void announce_keys(zrtp_t *z) {
    if (z->cb.keys_rx) z->cb.keys_rx(z->cb.user, &z->keys);
    if (z->cb.sas) z->cb.sas(z->cb.user, z->sas, z->had_entry && z->ce.has_rs1, z->cache_mismatch, z->ce.verified);
}

static int hello_ok(zrtp_t *z, const msg_t *h) {
    if (h->n < 12 + 4 + 16 + 32 + 12 + 4 + 8 || memcmp(h->m + 12, "1.1", 3) != 0) return 0;
    if (memcmp(h->m + 64, z->zid, ZRTP_ZID_LEN) == 0) return 0;                      /* equal ZIDs */
    uint32_t w = be32(h->m + 76); unsigned hc = (w >> 16) & 15, cc = (w >> 12) & 15, ac = (w >> 8) & 15, kc = (w >> 4) & 15, sc = w & 15;
    if (hc > 7 || cc > 7 || ac > 7 || kc > 7 || sc > 7) return 0;
    return h->n == 12 + 4 + 16 + 32 + 12 + 4 + 4 * (hc + cc + ac + kc + sc) + 8;
}

/* Does the other side list this key agreement (EC25 only; DH3k is mandatory and always available)? */
static int peer_offers(const msg_t *h, const char *kex) {
    uint32_t w = be32(h->m + 76); unsigned hc = (w >> 16) & 15, cc = (w >> 12) & 15, ac = (w >> 8) & 15, kc = (w >> 4) & 15;
    const uint8_t *k = h->m + 80 + 4 * (hc + cc + ac);
    for (unsigned i = 0; i < kc; i++) if (!memcmp(k + 4 * i, kex, 4)) return 1;
    return 0;
}

static void send_helloack(zrtp_t *z) { msg_t a; msg_begin(&a, "HelloACK"); msg_end_plain(&a); send_msg(z, &a); }

/* Both Hellos are in and ours was acknowledged: start the key agreement. */
static void try_commit(zrtp_t *z) {
    if (z->st != Z_HELLO || !z->have_peer_hello || !z->hello_acked) return;
    z->initiator = 1;
    z->kex = !z->no_ec && peer_offers(&z->peer_hello, "EC25");      /* the faster one when both have it */
    if (!kex_generate(z)) { fail(z, ZRTP_FAIL_PROTOCOL, 0x20, 1); return; }
    prepare_ids(z);
    /* DHPart2 is complete before the Commit goes out: hvi commits to it (section 4.4.1.1) */
    msg_t *d = &z->dh2; msg_begin(d, "DHPart2 ");
    msg_put(d, z->h1, 32); msg_put(d, z->rs1id_i, 8); msg_put(d, z->rs2id_i, 8);
    uint8_t aux[16]; rnd(aux, 16); msg_put(d, aux, 16);      /* auxsecretID and pbxsecretID: nothing to match, so random */
    uint8_t pv[DH3K_BYTES]; kex_pub(z, pv); msg_put(d, pv, pv_len(z->kex));
    msg_end_mac(d, z->h0);
    buf_t b = {0}; bput(&b, d->m, d->n); bput(&b, z->peer_hello.m, z->peer_hello.n); sha256(b.p, b.n, z->hvi); bfree(&b);
    msg_t *c = &z->commit; msg_begin(c, "Commit  ");
    z->auth80 = 1;                                           /* HS80 and HS32 are both mandatory to implement: the stronger tag is always available */
    msg_put(c, z->h2, 32); msg_put(c, z->zid, 12); msg_put(c, "S256", 4); msg_put(c, "AES1", 4); msg_put(c, z->auth80 ? "HS80" : "HS32", 4);
    msg_put(c, z->kex ? "EC25" : "DH3k", 4); msg_put(c, "B32 ", 4); msg_put(c, z->hvi, 32);
    msg_end_mac(c, z->h1);
    z->st = Z_COMMIT;
    retry_start(z, c, 150, 1200, 10);
}

static void on_hello(zrtp_t *z, const msg_t *m) {
    if (!hello_ok(z, m)) { return; }
    if (!z->have_peer_hello) {
        z->peer_hello = *m; z->have_peer_hello = 1; memcpy(z->peer_zid, m->m + 64, 12); memcpy(z->peer_h3, m->m + 32, 32);
        z->had_entry = z->cb.cache_load ? z->cb.cache_load(z->cb.user, z->peer_zid, &z->ce) : 0;
        if (!z->had_entry) memset(&z->ce, 0, sizeof z->ce);
    } else if (m->n != z->peer_hello.n || memcmp(m->m, z->peer_hello.m, m->n) != 0) return;
    send_helloack(z);
    try_commit(z);
}

static void on_helloack(zrtp_t *z) {
    if (z->st != Z_HELLO || z->hello_acked) return;
    z->hello_acked = 1; retry_stop(z); try_commit(z);
}

/* Responder side: a Commit arrives (also repeated, and in contention with ours). */
static void on_commit(zrtp_t *z, const msg_t *m) {
    if (m->n != 116 || !z->have_peer_hello) return;
    if (z->st == Z_DH1 || z->st == Z_CONF1) { if (m->n == z->commit.n && !memcmp(m->m, z->commit.m, m->n)) { if (z->st == Z_DH1) send_msg(z, &z->dh1); else send_msg(z, &z->confirm); } return; }
    if (z->st != Z_HELLO && z->st != Z_COMMIT) return;
    const uint8_t *h2 = m->m + 12, *hash = m->m + 56;
    uint8_t chk[32]; sha256(h2, 32, chk);
    if (!eq(chk, z->peer_h3, 32)) return;                                            /* not from whoever sent the Hello */
    if (memcmp(m->m + 44, z->peer_zid, 12) != 0) return;
    if (memcmp(hash, "S256", 4) || memcmp(hash + 4, "AES1", 4) || memcmp(hash + 16, "B32 ", 4)) { fail(z, ZRTP_FAIL_PROTOCOL, 0x51, 1); return; }
    int kex = !memcmp(hash + 12, "EC25", 4) ? 1 : 0;
    if (kex ? z->no_ec : memcmp(hash + 12, "DH3k", 4)) { fail(z, ZRTP_FAIL_PROTOCOL, 0x53, 1); return; }          /* a key agreement we did not offer */
    int a80 = !memcmp(hash + 8, "HS80", 4); if (!a80 && memcmp(hash + 8, "HS32", 4)) { fail(z, ZRTP_FAIL_PROTOCOL, 0x54, 1); return; }
    if (z->st == Z_COMMIT) {                                                         /* both sent a Commit: the lower hvi gives way (section 4.2) */
        int c = memcmp(z->hvi, m->m + 76, 32);
        if (c > 0) return;                                                           /* ours is higher: they give way, we carry on as initiator */
    }
    z->initiator = 0; z->hello_acked = 1; retry_stop(z);
    z->commit = *m; z->auth80 = a80; z->kex = kex; memcpy(z->peer_h2, h2, 32);
    if (!kex_generate(z)) { fail(z, ZRTP_FAIL_PROTOCOL, 0x20, 1); return; }
    prepare_ids(z);
    msg_t *d = &z->dh1; msg_begin(d, "DHPart1 ");
    msg_put(d, z->h1, 32); msg_put(d, z->rs1id_r, 8); msg_put(d, z->rs2id_r, 8);
    uint8_t aux[16]; rnd(aux, 16); msg_put(d, aux, 16);
    uint8_t pv[DH3K_BYTES]; kex_pub(z, pv); msg_put(d, pv, pv_len(z->kex));
    msg_end_mac(d, z->h0);
    z->st = Z_DH1;
    send_msg(z, d);                                                                   /* the initiator repeats the Commit if this is lost */
}

/* Initiator side: the responder's DHPart1. */
static void on_dhpart1(zrtp_t *z, const msg_t *m) {
    if (z->st == Z_DH2 || z->st == Z_CONF2) { send_msg(z, &z->dh2); return; }
    if (z->st != Z_COMMIT || m->n != 84 + pv_len(z->kex)) return;
    const uint8_t *h1 = m->m + 12; uint8_t h2[32];
    sha256(h1, 32, h2); { uint8_t h3[32]; sha256(h2, 32, h3); if (!eq(h3, z->peer_h3, 32)) return; }     /* false packet */
    if (!mac_ok(&z->peer_hello, h2)) { fail(z, ZRTP_FAIL_ATTACK, 0x40, 1); return; }                     /* the Hello was changed on the way */
    const uint8_t *pvr = m->m + 76;
    if (!kex_valid(z->kex, pvr)) { fail(z, ZRTP_FAIL_ATTACK, 0x61, 1); return; }
    memcpy(z->peer_h1, h1, 32); memcpy(z->peer_h2, h2, 32);
    z->dh1 = *m;
    uint8_t dh[DH3K_BYTES]; size_t dhlen = kex_result(z, pvr, dh);
    if (!dhlen) { fail(z, ZRTP_FAIL_PROTOCOL, 0x20, 1); return; }
    const uint8_t *s1 = shared_s1(z, m->m + 44, m->m + 52, "Responder");
    derive(z, dh, dhlen, s1); OPENSSL_cleanse(dh, sizeof dh);
    z->st = Z_DH2;
    retry_start(z, &z->dh2, 150, 1200, 10);
}

/* Responder: DHPart2 arrives. */
static void on_dhpart2(zrtp_t *z, const msg_t *m) {
    if (z->st == Z_CONF1) { send_msg(z, &z->confirm); return; }
    if (z->st != Z_DH1 || m->n != 84 + pv_len(z->kex)) return;
    const uint8_t *h1 = m->m + 12; uint8_t chk[32];
    sha256(h1, 32, chk); if (!eq(chk, z->peer_h2, 32)) return;                       /* false packet */
    if (!mac_ok(&z->commit, h1)) { fail(z, ZRTP_FAIL_ATTACK, 0x62, 1); return; }
    if (!mac_ok(&z->peer_hello, z->peer_h2)) { fail(z, ZRTP_FAIL_ATTACK, 0x40, 1); return; }
    const uint8_t *pvi = m->m + 76;
    if (!kex_valid(z->kex, pvi)) { fail(z, ZRTP_FAIL_ATTACK, 0x61, 1); return; }
    buf_t b = {0}; bput(&b, m->m, m->n); bput(&b, z->hello.m, z->hello.n); sha256(b.p, b.n, chk); bfree(&b);
    if (!eq(chk, z->commit.m + 76, 32)) { fail(z, ZRTP_FAIL_ATTACK, 0x62, 1); return; }               /* hvi does not match: a man in the middle */
    memcpy(z->peer_h1, h1, 32); z->dh2 = *m;
    uint8_t dh[DH3K_BYTES]; size_t dhlen = kex_result(z, pvi, dh);
    if (!dhlen) { fail(z, ZRTP_FAIL_PROTOCOL, 0x20, 1); return; }
    const uint8_t *s1 = shared_s1(z, m->m + 44, m->m + 52, "Initiator");
    derive(z, dh, dhlen, s1); OPENSSL_cleanse(dh, sizeof dh);
    build_confirm(z, 1);
    z->st = Z_CONF1;
    send_msg(z, &z->confirm);
}

/* Initiator: Confirm1. */
static void on_confirm1(zrtp_t *z, const msg_t *m) {
    if (z->st == Z_CONF2) { send_msg(z, &z->confirm); return; }
    if (z->st != Z_DH2) return;
    uint8_t h0[32], chk[32]; uint32_t flags, exp;
    if (!open_confirm(z, m, 1, h0, &flags, &exp)) { fail(z, ZRTP_FAIL_ATTACK, 0x70, 1); return; }
    sha256(h0, 32, chk); if (!eq(chk, z->peer_h1, 32)) { fail(z, ZRTP_FAIL_ATTACK, 0x70, 1); return; }
    if (!mac_ok(&z->dh1, h0)) { fail(z, ZRTP_FAIL_ATTACK, 0x70, 1); return; }
    z->peer_expires = exp < 0xffffffffu ? exp : 0xffffffffu; z->peer_verified = (flags & 4) != 0; z->peer_allows_clear = (flags & 2) != 0;
    build_confirm(z, 0);
    z->st = Z_CONF2;
    announce_keys(z);
    retry_start(z, &z->confirm, 150, 1200, 10);
}

/* Responder: Confirm2. */
static void on_confirm2(zrtp_t *z, const msg_t *m) {
    if (z->st == Z_SECURE && !z->initiator) { msg_t a; msg_begin(&a, "Conf2ACK"); msg_end_plain(&a); send_msg(z, &a); return; }
    if (z->st != Z_CONF1) return;
    uint8_t h0[32], chk[32]; uint32_t flags, exp;
    if (!open_confirm(z, m, 0, h0, &flags, &exp)) { fail(z, ZRTP_FAIL_ATTACK, 0x70, 1); return; }
    sha256(h0, 32, chk); if (!eq(chk, z->peer_h1, 32)) { fail(z, ZRTP_FAIL_ATTACK, 0x70, 1); return; }
    if (!mac_ok(&z->dh2, h0)) { fail(z, ZRTP_FAIL_ATTACK, 0x70, 1); return; }
    z->peer_expires = exp < 0xffffffffu ? exp : 0xffffffffu; z->peer_verified = (flags & 4) != 0; z->peer_allows_clear = (flags & 2) != 0;
    msg_t a; msg_begin(&a, "Conf2ACK"); msg_end_plain(&a); send_msg(z, &a);
    announce_keys(z);
    go_secure(z);
}

static void on_conf2ack(zrtp_t *z) { if (z->st == Z_CONF2) go_secure(z); }

/* ---------- GoClear ---------- */

static void do_clear(zrtp_t *z, int by_us) {
    if (z->st == Z_CLEAR) return;
    retry_stop(z); z->st = Z_CLEAR;
    OPENSSL_cleanse(&z->keys, sizeof z->keys); OPENSSL_cleanse(z->mackey_i, 32); OPENSSL_cleanse(z->mackey_r, 32); OPENSSL_cleanse(z->zrtpkey_i, 16); OPENSSL_cleanse(z->zrtpkey_r, 16);
    z->have_keys = 0;
    if (z->cb.cleared) z->cb.cleared(z->cb.user, by_us);
}

/* clear_mac = MAC(mackey of the sender, "GoClear ") cut to 64 bits */
static void clear_mac(zrtp_t *z, int sender_is_initiator, uint8_t out[8]) {
    uint8_t m[32]; hmac256(sender_is_initiator ? z->mackey_i : z->mackey_r, 32, (const uint8_t *)"GoClear ", 8, m); memcpy(out, m, 8);
}

int zrtp_can_go_clear(const zrtp_t *z) { return z->st == Z_SECURE && z->peer_allows_clear; }
int zrtp_is_clear(const zrtp_t *z) { return z->st == Z_CLEAR; }

int zrtp_go_clear(zrtp_t *z) {
    if (!zrtp_can_go_clear(z)) return 0;
    uint8_t mac[8]; clear_mac(z, z->initiator, mac);
    msg_begin(&z->clear_msg, "GoClear "); msg_put(&z->clear_msg, mac, 8); msg_end_plain(&z->clear_msg);
    z->st = Z_CLEARING; retry_start(z, &z->clear_msg, 150, 1200, 10);
    return 1;
}

static void on_goclear(zrtp_t *z, const msg_t *m) {
    if (m->n != 20 || (z->st != Z_SECURE && z->st != Z_CLEARING)) return;
    if (!z->allow_clear) { msg_t e; msg_begin(&e, "Error   "); uint8_t c[4]; put32(c, 0x100); msg_put(&e, c, 4); msg_end_plain(&e); send_msg(z, &e); return; }     /* not allowed here */
    uint8_t mac[8]; clear_mac(z, !z->initiator, mac);
    if (!eq(mac, m->m + 12, 8)) return;                      /* not from the other side: no ClearACK, no action */
    msg_t a; msg_begin(&a, "ClearACK"); msg_end_plain(&a); send_msg(z, &a);
    do_clear(z, 0);
}
void zrtp_srtp_seen(zrtp_t *z) { if (z->st == Z_CONF2) go_secure(z); }

int zrtp_recv(zrtp_t *z, const uint8_t *pkt, size_t len) {
    if (!zrtp_is_zrtp(pkt, len)) return 0;
    if (len < 16 + 12 || len > ZRTP_MAX_PACKET) return 1;
    { const uint8_t *w = pkt + len - 4; uint32_t got = (uint32_t)w[0] | (uint32_t)w[1] << 8 | (uint32_t)w[2] << 16 | (uint32_t)w[3] << 24; if (got != zrtp_crc32c(pkt, len - 4)) return 1; }                  /* damaged: dropped */
    const uint8_t *m = pkt + 12; size_t n = len - 16;
    if (m[0] != 0x50 || m[1] != 0x5a || n < 12 || (size_t)((m[2] << 8) | m[3]) * 4 != n || n > MAXMSG) return 1;
    if (z->st == Z_FAILED || z->st == Z_CLEAR) return 1;
    msg_t msg; memcpy(msg.m, m, n); msg.n = n;
    if (is_type(m, "Hello   ")) on_hello(z, &msg);
    else if (is_type(m, "HelloACK")) on_helloack(z);
    else if (is_type(m, "Commit  ")) on_commit(z, &msg);
    else if (is_type(m, "DHPart1 ")) on_dhpart1(z, &msg);
    else if (is_type(m, "DHPart2 ")) on_dhpart2(z, &msg);
    else if (is_type(m, "Confirm1")) on_confirm1(z, &msg);
    else if (is_type(m, "Confirm2")) on_confirm2(z, &msg);
    else if (is_type(m, "Conf2ACK")) on_conf2ack(z);
    else if (is_type(m, "GoClear ")) on_goclear(&*z, &msg);
    else if (is_type(m, "ClearACK")) { if (z->st == Z_CLEARING) do_clear(z, 1); }
    else if (is_type(m, "Error   ") && (z->st == Z_SECURE || z->st == Z_CLEARING)) { msg_t a; msg_begin(&a, "ErrorACK"); msg_end_plain(&a); send_msg(z, &a); }      /* an Error after the keys are agreed (such as "GoClear not allowed") does not end the call */
    else if (is_type(m, "Error   ")) { msg_t a; msg_begin(&a, "ErrorACK"); msg_end_plain(&a); send_msg(z, &a); fail(z, ZRTP_FAIL_PROTOCOL, n >= 16 ? (int)be32(m + 12) : 0, 0); }
    else if (is_type(m, "Ping    ")) { /* optional: answered with nothing */ }
    return 1;
}
