#include "l1ne_zrtp_tp.h"

#include <openssl/crypto.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "l1srtp.h"
#include "zrtp.h"

#define THIS_FILE "l1ne_zrtp"
#define MAXQ 8

/* ---------- the cache of retained secrets (one small text file) ---------- */

typedef struct { uint8_t zid[ZRTP_ZID_LEN]; zrtp_cache_entry e; } peer_t;
static struct {
    pj_mutex_t *lock; char path[512]; uint8_t zid[ZRTP_ZID_LEN]; int have_zid;
    peer_t *peers; int n, cap;
    l1ne_zrtp_listener listener; void *user;
} G;

static void hex_out(char *o, const uint8_t *b, size_t n) { for (size_t i = 0; i < n; i++) sprintf(o + 2 * i, "%02x", b[i]); }
static int hex_in(const char *s, uint8_t *b, size_t n) { for (size_t i = 0; i < n; i++) { unsigned v; if (sscanf(s + 2 * i, "%2x", &v) != 1) return 0; b[i] = (uint8_t)v; } return 1; }

static void cache_save(void) {
    if (!G.path[0]) return;
    char tmp[560]; snprintf(tmp, sizeof tmp, "%s.tmp", G.path);
    FILE *f = fopen(tmp, "w"); if (!f) return;
    chmod(tmp, 0600);
    char h[80]; hex_out(h, G.zid, ZRTP_ZID_LEN); fprintf(f, "zid %s\n", h);
    for (int i = 0; i < G.n; i++) {
        char z[32], a[80], b[80]; hex_out(z, G.peers[i].zid, ZRTP_ZID_LEN);
        if (G.peers[i].e.has_rs1) hex_out(a, G.peers[i].e.rs1, 32); else strcpy(a, "-");
        if (G.peers[i].e.has_rs2) hex_out(b, G.peers[i].e.rs2, 32); else strcpy(b, "-");
        fprintf(f, "peer %s %s %s %d %x\n", z, a, b, G.peers[i].e.verified, G.peers[i].e.expires);
    }
    fclose(f); rename(tmp, G.path);
}

static int cache_load_cb(void *u, const uint8_t zid[ZRTP_ZID_LEN], zrtp_cache_entry *e) {
    (void)u; int found = 0; pj_mutex_lock(G.lock);
    for (int i = 0; i < G.n; i++) if (!memcmp(G.peers[i].zid, zid, ZRTP_ZID_LEN)) { *e = G.peers[i].e; found = 1; break; }
    pj_mutex_unlock(G.lock); return found;
}

static void cache_store_cb(void *u, const uint8_t zid[ZRTP_ZID_LEN], const zrtp_cache_entry *e) {
    (void)u; pj_mutex_lock(G.lock); int i;
    for (i = 0; i < G.n; i++) if (!memcmp(G.peers[i].zid, zid, ZRTP_ZID_LEN)) break;
    if (!e->has_rs1 && !e->has_rs2) { if (i < G.n) { G.peers[i] = G.peers[--G.n]; cache_save(); } pj_mutex_unlock(G.lock); return; }
    if (i == G.n) { if (G.n == G.cap) { G.cap = G.cap ? G.cap * 2 : 16; G.peers = realloc(G.peers, (size_t)G.cap * sizeof *G.peers); } memcpy(G.peers[i].zid, zid, ZRTP_ZID_LEN); G.n++; }
    G.peers[i].e = *e; cache_save(); pj_mutex_unlock(G.lock);
}

int l1ne_zrtp_init(const char *cache_path, l1ne_zrtp_listener listener, void *user) {
    if (!G.lock) {                                          /* needs pjsua_create() to have been called */
        pj_pool_t *pool = pjsua_pool_create("l1ne_zrtp", 512, 512);
        if (!pool || pj_mutex_create_recursive(pool, "zrtp", &G.lock) != PJ_SUCCESS) return -1;
    }
    pj_mutex_lock(G.lock);
    G.listener = listener; G.user = user; G.n = 0; G.have_zid = 0;
    snprintf(G.path, sizeof G.path, "%s", cache_path ? cache_path : "");
    FILE *f = G.path[0] ? fopen(G.path, "r") : NULL; char line[400];
    while (f && fgets(line, sizeof line, f)) {
        char t[8], a[100], b[100], c[100], d[100]; unsigned verified = 0, exp = 0xffffffffu;
        if (sscanf(line, "zid %99s", a) == 1 && strlen(a) == 24) { if (hex_in(a, G.zid, ZRTP_ZID_LEN)) G.have_zid = 1; }
        else if (sscanf(line, "%7s %99s %99s %99s %u %x", t, a, b, c, &verified, &exp) >= 4 && !strcmp(t, "peer") && strlen(a) == 24) {
            if (G.n == G.cap) { G.cap = G.cap ? G.cap * 2 : 16; G.peers = realloc(G.peers, (size_t)G.cap * sizeof *G.peers); }
            peer_t *p = &G.peers[G.n]; memset(p, 0, sizeof *p); (void)d;
            if (!hex_in(a, p->zid, ZRTP_ZID_LEN)) continue;
            if (strcmp(b, "-") && strlen(b) == 64) p->e.has_rs1 = hex_in(b, p->e.rs1, 32);
            if (strcmp(c, "-") && strlen(c) == 64) p->e.has_rs2 = hex_in(c, p->e.rs2, 32);
            p->e.verified = (int)verified; p->e.expires = exp; G.n++;
        }
    }
    if (f) fclose(f);
    if (!G.have_zid) { RAND_bytes(G.zid, ZRTP_ZID_LEN); G.have_zid = 1; cache_save(); }
    pj_mutex_unlock(G.lock); return 0;
}

/* ---------- accounts ---------- */

static int g_mode[PJSUA_MAX_ACC];
void l1ne_zrtp_set_account_mode(int acc_id, int mode) { if (acc_id >= 0 && acc_id < PJSUA_MAX_ACC) g_mode[acc_id] = mode; }

/* ---------- the transport ---------- */

typedef struct { uint8_t d[ZRTP_MAX_PACKET]; size_t n; } outpkt;

struct zt {
    pjmedia_transport base; pjmedia_transport *slave; pj_bool_t del_base; pj_pool_t *pool;
    void *s_user; void *s_ref; void (*s_rtp_cb)(void *, void *, pj_ssize_t); void (*s_rtp_cb2)(pjmedia_tp_cb_param *); void (*s_rtcp_cb)(void *, void *, pj_ssize_t);
    pj_lock_t *lock; pj_timer_entry timer; pj_bool_t destroyed;
    zrtp_t *z; int call_id, mandatory, started, ssrc_known; unsigned seq;
    l1srtp_t tx, rx; int have_tx, have_rx;
    l1ne_zrtp_info info; int notify;
    outpkt q[MAXQ]; int qn;
};

/* The live transports. A call can have more than one over its life (pjsua may create the media transport again), so they are found by call id,
 * newest first, rather than by a fixed slot per call. */
#define MAXLIVE 16
static struct zt *g_live[MAXLIVE]; static unsigned g_seq;
static struct zt *find_by_call(int call_id) {
    struct zt *best = NULL;
    for (int i = 0; i < MAXLIVE; i++) if (g_live[i] && g_live[i]->call_id == call_id && (!best || g_live[i]->seq > best->seq)) best = g_live[i];
    return best;
}

static pj_timer_heap_t *theap(void) { return pjsip_endpt_get_timer_heap(pjsua_get_pjsip_endpt()); }

/* engine callbacks: all run with t->lock held, so they only record what to do afterwards */
static void cb_send(void *u, const uint8_t *p, size_t n) { struct zt *t = u; if (t->qn < MAXQ && n <= ZRTP_MAX_PACKET) { memcpy(t->q[t->qn].d, p, n); t->q[t->qn].n = n; t->qn++; } }
static void cb_keys_rx(void *u, const zrtp_keys *k) { struct zt *t = u; l1srtp_init(&t->rx, k->rx.key, k->rx.salt, k->tag_len); t->have_rx = 1; }
static void cb_secure(void *u, const zrtp_keys *k) { struct zt *t = u; l1srtp_init(&t->tx, k->tx.key, k->tx.salt, k->tag_len); t->have_tx = 1; t->info.state = 1; t->notify = 1; }
static void cb_sas(void *u, const char *sas, int known, int mismatch, int verified) {
    struct zt *t = u; snprintf(t->info.sas, sizeof t->info.sas, "%s", sas); t->info.known_before = known; t->info.cache_mismatch = mismatch; t->info.verified = verified;
}
static void cb_failed(void *u, zrtp_failure why, int code) { struct zt *t = u; (void)code; t->info.state = 2; t->info.failure = (int)why; t->notify = 1; }

static void schedule(struct zt *t, int ms);

/* Sends what the engine queued, tells the app what changed, and arms the timer; call with the lock NOT held. */
static void flush(struct zt *t) {
    outpkt local[MAXQ]; int n; l1ne_zrtp_info info; int notify, ms;
    pj_lock_acquire(t->lock);
    ms = t->destroyed ? -1 : zrtp_poll(t->z);                  /* sends what is due (queued below) and may change the state */
    n = t->qn; memcpy(local, t->q, (size_t)n * sizeof local[0]); t->qn = 0; info = t->info; notify = t->notify; t->notify = 0;
    pj_lock_release(t->lock);
    for (int i = 0; i < n; i++) pjmedia_transport_send_rtp(t->slave, local[i].d, local[i].n);
    if (notify && G.listener) G.listener(G.user, t->call_id, &info);
    if (!t->destroyed) schedule(t, ms);
}

static void on_timer(pj_timer_heap_t *th, pj_timer_entry *e) { (void)th; struct zt *t = e->user_data; e->id = 0;  if (!t->destroyed) flush(t); }

static void schedule(struct zt *t, int ms) {
    pj_timer_heap_t *th = theap(); if (!th) return;
    pj_timer_heap_cancel_if_active(th, &t->timer, 0);
    if (ms < 0) return;
    if (ms < 5) ms = 5;
    pj_time_val d = { ms / 1000, ms % 1000 };
    if (t->base.grp_lock) pj_timer_heap_schedule_w_grp_lock(th, &t->timer, &d, 1, t->base.grp_lock); else pj_timer_heap_schedule(th, &t->timer, &d);
}

static pj_status_t zt_get_info(pjmedia_transport *tp, pjmedia_transport_info *info) { return pjmedia_transport_get_info(((struct zt *)tp)->slave, info); }

static void zt_rtp_cb2(pjmedia_tp_cb_param *param) {
    struct zt *t = param->user_data; if (!t || t->destroyed) return;
    uint8_t *pkt = param->pkt; size_t n = param->size > 0 ? (size_t)param->size : 0;
    if (zrtp_is_zrtp(pkt, n)) {
        pj_lock_acquire(t->lock); zrtp_recv(t->z, pkt, n); pj_lock_release(t->lock); flush(t); return;
    }
    pjmedia_tp_cb_param p2 = *param; p2.user_data = t->s_user;
    pj_lock_acquire(t->lock);
    if (t->have_rx) {                                       /* keys agreed: only packets that authenticate go on; anything in the clear is dropped */
        size_t len = n;
        if (l1srtp_unprotect(&t->rx, pkt, &len) != 0) { pj_lock_release(t->lock); return; }
        int was_secure = zrtp_is_secure(t->z); zrtp_srtp_seen(t->z); p2.size = (pj_ssize_t)len;
        pj_lock_release(t->lock); if (!was_secure) flush(t);          /* the first media from the other side completes the exchange for us */
    } else if (t->mandatory) { pj_lock_release(t->lock); return; }          /* ZRTP required: nothing is played before the keys are there */
    else pj_lock_release(t->lock);
    if (t->s_rtp_cb2) { t->s_rtp_cb2(&p2); param->rem_switch = p2.rem_switch; } else if (t->s_rtp_cb) t->s_rtp_cb(t->s_user, p2.pkt, p2.size);
}

static void zt_rtcp_cb(void *user_data, void *pkt, pj_ssize_t size) {
    struct zt *t = user_data; if (!t || t->destroyed || !t->s_rtcp_cb) return;
    size_t len = size > 0 ? (size_t)size : 0;
    pj_lock_acquire(t->lock);
    if (t->have_rx) { if (l1srtp_unprotect_rtcp(&t->rx, pkt, &len) != 0) { pj_lock_release(t->lock); return; } }
    else if (t->mandatory) { pj_lock_release(t->lock); return; }
    pj_lock_release(t->lock);
    t->s_rtcp_cb(t->s_user, pkt, (pj_ssize_t)len);
}

static pj_status_t zt_attach2(pjmedia_transport *tp, pjmedia_transport_attach_param *att) {
    struct zt *t = (struct zt *)tp; pj_status_t st;
    t->s_user = att->user_data; t->s_rtp_cb2 = att->rtp_cb2; t->s_rtp_cb = att->rtp_cb2 ? NULL : att->rtp_cb; t->s_rtcp_cb = att->rtcp_cb; t->s_ref = att->stream;
    att->rtp_cb2 = &zt_rtp_cb2; att->rtp_cb = NULL; att->rtcp_cb = &zt_rtcp_cb; att->user_data = t;
    st = pjmedia_transport_attach2(t->slave, att);
    if (st != PJ_SUCCESS) { t->s_user = NULL; t->s_rtp_cb = NULL; t->s_rtp_cb2 = NULL; t->s_rtcp_cb = NULL; t->s_ref = NULL; return st; }
    pj_lock_acquire(t->lock); int first = !t->started; t->started = 1; if (first) zrtp_start(t->z); pj_lock_release(t->lock);
    if (first) flush(t);
    return PJ_SUCCESS;
}

static void zt_detach(pjmedia_transport *tp, void *strm) {
    struct zt *t = (struct zt *)tp; (void)strm;
    if (t->s_user != NULL || t->s_rtp_cb2 || t->s_rtp_cb) { pjmedia_transport_detach(t->slave, t); t->s_user = NULL; t->s_rtp_cb = NULL; t->s_rtp_cb2 = NULL; t->s_rtcp_cb = NULL; t->s_ref = NULL; }
}

static pj_status_t zt_send_rtp(pjmedia_transport *tp, const void *pkt, pj_size_t size) {
    struct zt *t = (struct zt *)tp; uint8_t buf[1600];
    if (size < 12 || size + L1SRTP_MAX_OVERHEAD > sizeof buf) return PJ_ETOOBIG;
    pj_lock_acquire(t->lock);
    if (!t->ssrc_known) { const uint8_t *p = pkt; zrtp_set_ssrc(t->z, (uint32_t)p[8] << 24 | p[9] << 16 | p[10] << 8 | p[11]); t->ssrc_known = 1; }
    if (t->have_tx) {
        size_t len = size; memcpy(buf, pkt, size);
        int rc = l1srtp_protect(&t->tx, buf, &len, sizeof buf); pj_lock_release(t->lock);
        return rc == 0 ? pjmedia_transport_send_rtp(t->slave, buf, len) : PJ_EINVAL;
    }
    int drop = t->mandatory; pj_lock_release(t->lock);
    return drop ? PJ_SUCCESS : pjmedia_transport_send_rtp(t->slave, pkt, size);       /* required: nothing leaves in the clear */
}

static pj_status_t zt_send_rtcp(pjmedia_transport *tp, const void *pkt, pj_size_t size) {
    struct zt *t = (struct zt *)tp; uint8_t buf[1600];
    if (size < 8 || size + L1SRTP_MAX_OVERHEAD > sizeof buf) return PJ_ETOOBIG;
    pj_lock_acquire(t->lock);
    if (t->have_tx) { size_t len = size; memcpy(buf, pkt, size); int rc = l1srtp_protect_rtcp(&t->tx, buf, &len, sizeof buf); pj_lock_release(t->lock); return rc == 0 ? pjmedia_transport_send_rtcp(t->slave, buf, len) : PJ_EINVAL; }
    int drop = t->mandatory; pj_lock_release(t->lock);
    return drop ? PJ_SUCCESS : pjmedia_transport_send_rtcp(t->slave, pkt, size);
}

static pj_status_t zt_send_rtcp2(pjmedia_transport *tp, const pj_sockaddr_t *addr, unsigned addr_len, const void *pkt, pj_size_t size) {
    struct zt *t = (struct zt *)tp; uint8_t buf[1600];
    if (size < 8 || size + L1SRTP_MAX_OVERHEAD > sizeof buf) return PJ_ETOOBIG;
    pj_lock_acquire(t->lock);
    if (t->have_tx) { size_t len = size; memcpy(buf, pkt, size); int rc = l1srtp_protect_rtcp(&t->tx, buf, &len, sizeof buf); pj_lock_release(t->lock); return rc == 0 ? pjmedia_transport_send_rtcp2(t->slave, addr, addr_len, buf, len) : PJ_EINVAL; }
    int drop = t->mandatory; pj_lock_release(t->lock);
    return drop ? PJ_SUCCESS : pjmedia_transport_send_rtcp2(t->slave, addr, addr_len, pkt, size);
}

static pj_status_t zt_media_create(pjmedia_transport *tp, pj_pool_t *sdp_pool, unsigned options, const pjmedia_sdp_session *rem, unsigned idx) {
    return pjmedia_transport_media_create(((struct zt *)tp)->slave, sdp_pool, options, rem, idx);
}

/* a=zrtp-hash:1.10 <SHA-256 of our Hello, in hex>: tells the other side we speak ZRTP and which Hello to expect (RFC 6189 section 8) */
static pj_status_t zt_encode_sdp(pjmedia_transport *tp, pj_pool_t *sdp_pool, pjmedia_sdp_session *local, const pjmedia_sdp_session *rem, unsigned idx) {
    struct zt *t = (struct zt *)tp; uint8_t h[32]; char hx[65], val[80];
    pj_lock_acquire(t->lock); zrtp_hello_hash(t->z, h); pj_lock_release(t->lock);
    for (int i = 0; i < 32; i++) sprintf(hx + 2 * i, "%02x", h[i]);
    snprintf(val, sizeof val, "1.10 %s", hx);
    pjmedia_sdp_media *m = local->media[idx];
    pjmedia_sdp_attr *old = pjmedia_sdp_media_find_attr2(m, "zrtp-hash", NULL); if (old) pjmedia_sdp_media_remove_attr(m, old);
    pjmedia_sdp_attr *a = PJ_POOL_ALLOC_T(sdp_pool, pjmedia_sdp_attr);
    pj_strdup2(sdp_pool, &a->name, "zrtp-hash"); pj_strdup2(sdp_pool, &a->value, val);
    pjmedia_sdp_media_add_attr(m, a);
    return pjmedia_transport_encode_sdp(t->slave, sdp_pool, local, rem, idx);
}

static pj_status_t zt_media_start(pjmedia_transport *tp, pj_pool_t *pool, const pjmedia_sdp_session *l, const pjmedia_sdp_session *r, unsigned idx) {
    return pjmedia_transport_media_start(((struct zt *)tp)->slave, pool, l, r, idx);
}
static pj_status_t zt_media_stop(pjmedia_transport *tp) { return pjmedia_transport_media_stop(((struct zt *)tp)->slave); }
static pj_status_t zt_simulate_lost(pjmedia_transport *tp, pjmedia_dir dir, unsigned pct) { return pjmedia_transport_simulate_lost(((struct zt *)tp)->slave, dir, pct); }

static void zt_on_destroy(void *arg) {
    struct zt *t = arg;
    zrtp_free(t->z); OPENSSL_cleanse(&t->tx, sizeof t->tx); OPENSSL_cleanse(&t->rx, sizeof t->rx);
    pj_lock_destroy(t->lock); pj_pool_release(t->pool);
}

static pj_status_t zt_destroy(pjmedia_transport *tp) {
    struct zt *t = (struct zt *)tp;
    pj_lock_acquire(t->lock); t->destroyed = PJ_TRUE; pj_lock_release(t->lock);
    pj_timer_heap_t *th = theap(); if (th) pj_timer_heap_cancel_if_active(th, &t->timer, 0);
    pj_mutex_lock(G.lock); for (int i = 0; i < MAXLIVE; i++) if (g_live[i] == t) g_live[i] = NULL; pj_mutex_unlock(G.lock);
    if (t->del_base) pjmedia_transport_close(t->slave);
    if (t->base.grp_lock) pj_grp_lock_dec_ref(t->base.grp_lock); else zt_on_destroy(t);
    return PJ_SUCCESS;
}

static pjmedia_transport_op zt_op = {
    &zt_get_info, NULL, &zt_detach, &zt_send_rtp, &zt_send_rtcp, &zt_send_rtcp2, &zt_media_create, &zt_encode_sdp, &zt_media_start, &zt_media_stop,
    &zt_simulate_lost, &zt_destroy, &zt_attach2,
};

pjmedia_transport *l1ne_zrtp_on_create_media_transport(pjsua_call_id call_id, unsigned media_idx, pjmedia_transport *base, unsigned flags) {
    pjsua_call_info ci; (void)media_idx;
    if (!base || !G.lock || pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return base;
    int mode = ci.acc_id >= 0 && ci.acc_id < PJSUA_MAX_ACC ? g_mode[ci.acc_id] : 0;
    if (mode == 0) return base;
    pj_pool_t *pool = pjmedia_endpt_create_pool(pjsua_get_pjmedia_endpt(), "l1ne_zrtp%p", 1024, 1024);
    struct zt *t = PJ_POOL_ZALLOC_T(pool, struct zt);
    t->pool = pool; t->slave = base; t->del_base = (flags & PJSUA_MED_TP_CLOSE_MEMBER) != 0; t->call_id = call_id; t->mandatory = mode == 2;
    pj_ansi_strxcpy(t->base.name, pool->obj_name, sizeof t->base.name);
    t->base.type = (pjmedia_transport_type)(PJMEDIA_TRANSPORT_TYPE_USER + 2); t->base.op = &zt_op;
    pj_lock_create_recursive_mutex(pool, "zrtp", &t->lock);
    pj_timer_entry_init(&t->timer, 0, t, &on_timer);
    zrtp_callbacks cb = { .user = t, .send = cb_send, .keys_rx = cb_keys_rx, .secure = cb_secure, .sas = cb_sas, .failed = cb_failed, .cache_load = cache_load_cb, .cache_store = cache_store_cb };
    uint8_t rnd[4]; RAND_bytes(rnd, 4);
    t->z = zrtp_new(&cb, G.zid, (uint32_t)rnd[0] << 24 | rnd[1] << 16 | rnd[2] << 8 | rnd[3]);
    if (!t->z) { pj_pool_release(pool); return base; }
    if (base->grp_lock) { t->base.grp_lock = base->grp_lock; pj_grp_lock_add_ref(base->grp_lock); pj_grp_lock_add_handler(base->grp_lock, pool, t, &zt_on_destroy); }
    pj_mutex_lock(G.lock); t->seq = ++g_seq;
    for (int i = 0; i < MAXLIVE; i++) if (!g_live[i]) { g_live[i] = t; break; }
    pj_mutex_unlock(G.lock);
    PJ_LOG(4, (THIS_FILE, "call %d: ZRTP %s", call_id, t->mandatory ? "required" : "when the other side has it"));
    return &t->base;
}

int l1ne_zrtp_call_info(int call_id, l1ne_zrtp_info *out) {
    pj_mutex_lock(G.lock); struct zt *t = find_by_call(call_id); if (!t) { pj_mutex_unlock(G.lock); return 0; }
    pj_lock_acquire(t->lock); *out = t->info; pj_lock_release(t->lock); pj_mutex_unlock(G.lock); return 1;
}

void l1ne_zrtp_call_verified(int call_id, int verified) {
    pj_mutex_lock(G.lock); struct zt *t = find_by_call(call_id); if (!t) { pj_mutex_unlock(G.lock); return; }
    pj_lock_acquire(t->lock); zrtp_set_verified(t->z, verified); t->info.verified = verified; pj_lock_release(t->lock); pj_mutex_unlock(G.lock);
}
