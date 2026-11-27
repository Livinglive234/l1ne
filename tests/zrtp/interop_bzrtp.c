/* Interoperability test: this repo's ZRTP engine against Linphone's bzrtp (GPLv3; fetched and built only by run-interop.sh, never shipped). */
#include "zrtp.h"
#include "bzrtp/bzrtp.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

static uint64_t T;                                   /* fake time, ms */
static uint64_t now_cb(void *u) { (void)u; return T; }

typedef struct { uint8_t d[600]; uint16_t n; } pk;
static pk to_b[64], to_a[64]; static int b_h, b_t, a_h, a_t;     /* queues */
static int drop_mod, sent;

/* --- my engine (A) --- */
static zrtp_keys a_rx, a_tx; static char a_sas[5]; static int a_secure, a_failed;
static void a_send(void *u, const uint8_t *p, size_t n) { (void)u; sent++; if (drop_mod && sent % drop_mod == 0) return; memcpy(to_b[b_t % 64].d, p, n); to_b[b_t % 64].n = (uint16_t)n; b_t++; }
static void a_rx_cb(void *u, const zrtp_keys *k) { (void)u; a_rx = *k; }
static void a_sec(void *u, const zrtp_keys *k) { (void)u; a_tx = *k; a_secure = 1; }
static void a_sas_cb(void *u, const char *s, int a, int b, int c) { (void)u; (void)a; (void)b; (void)c; strcpy(a_sas, s); }
static void a_fail(void *u, zrtp_failure w, int c) { (void)u; a_failed = 1; printf("   A failed: %d code %x\n", w, c); }

/* --- bzrtp (B) --- */
static int b_secure; static char b_sas[8]; static uint8_t b_self_key[16], b_self_salt[14], b_peer_key[16], b_peer_salt[14]; static int b_tag, b_role = -1;
static int b_send(void *u, const uint8_t *p, uint16_t n) { (void)u; sent++; if (drop_mod && sent % drop_mod == 0) return 0; memcpy(to_a[a_t % 64].d, p, n); to_a[a_t % 64].n = n; a_t++; return 0; }
static int b_status(void *u, const uint8_t l, const uint8_t id, const char *m) { (void)u; if (l <= 1) printf("   B status %d/%d: %s\n", l, id, m ? m : ""); return 0; }
static int b_secrets(void *u, const bzrtpSrtpSecrets_t *s, uint8_t part) {
    (void)u; if (part & ZRTP_SRTP_SECRETS_FOR_SENDER) { memcpy(b_self_key, s->selfSrtpKey, 16); memcpy(b_self_salt, s->selfSrtpSalt, 14); }
    if (part & ZRTP_SRTP_SECRETS_FOR_RECEIVER) { memcpy(b_peer_key, s->peerSrtpKey, 16); memcpy(b_peer_salt, s->peerSrtpSalt, 14); }
    b_tag = s->authTagAlgo; return 0;
}
static int b_start(void *u, const bzrtpSrtpSecrets_t *s, int32_t v) { (void)u; (void)v; strncpy(b_sas, s->sas, 7); b_secure = 1; return 0; }
static int b_ready(void *u, int zuid, uint8_t role) { (void)u; (void)zuid; b_role = role; return 0; }

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 10, ok = 0, bad = 0;
    for (int r = 0; r < rounds; r++) {
        drop_mod = r % 3 == 2 ? 4 : 0; sent = 0; T = 1000; b_h = b_t = a_h = a_t = 0; a_secure = a_failed = b_secure = 0; a_sas[0] = 0; b_sas[0] = 0;
        uint8_t zid[12]; memset(zid, 0x77 + r, 12);
        zrtp_callbacks cb = { .send = a_send, .keys_rx = a_rx_cb, .secure = a_sec, .sas = a_sas_cb, .failed = a_fail, .now_ms = now_cb };
        zrtp_t *a = zrtp_new(&cb, zid, 0x1111);
        bzrtpContext_t *b = bzrtp_createBzrtpContext(); bzrtpCallbacks_t bc; memset(&bc, 0, sizeof bc);
        bc.bzrtp_statusMessage = b_status; bc.bzrtp_messageLevel = BZRTP_MESSAGE_ERROR; bc.bzrtp_sendData = b_send; bc.bzrtp_srtpSecretsAvailable = b_secrets; bc.bzrtp_startSrtpSession = b_start; bc.bzrtp_contextReadyForExportedKeys = b_ready;
        int rc1 = bzrtp_setCallbacks(b, &bc); int rc2 = bzrtp_initBzrtpContext(b, 0x2222); int rc3 = bzrtp_setClientData(b, 0x2222, NULL);
        if (r == 0) printf("   setCallbacks %x init %x clientData %x\n", rc1, rc2, rc3);
        /* bzrtp has no cache here, and wants a self ZID: cacheless runtime */
        zrtp_start(a); int rc4 = bzrtp_startChannelEngine(b, 0x2222); if (r == 0) printf("   start %x\n", rc4);
        for (int step = 0; step < 3000 && !(a_secure && b_secure) && !a_failed; step++, T += 10) {
            while (b_h < b_t) { pk *p = &to_b[b_h++ % 64]; if (r == 0 && b_h < 5) printf("   A->B %.8s len %d\n", p->d + 16, p->n); bzrtp_processMessage(b, 0x2222, p->d, p->n); }
            while (a_h < a_t) { pk *p = &to_a[a_h++ % 64]; if (r == 0 && a_h < 3) { printf("   crc mine %08x stored %02x%02x%02x%02x len %d\n", zrtp_crc32c(p->d, p->n - 4), p->d[p->n-4], p->d[p->n-3], p->d[p->n-2], p->d[p->n-1], p->n); }
 if (r == 0 && a_h < 8) { printf("   B->A %.8s len %d crc %s\n", p->d + 20, p->n, zrtp_crc32c(p->d, p->n - 4) == (uint32_t)(p->d[p->n-4] << 24 | p->d[p->n-3] << 16 | p->d[p->n-2] << 8 | p->d[p->n-1]) ? "ok" : "BAD"); } zrtp_recv(a, p->d, p->n); }
            zrtp_poll(a); bzrtp_iterate(b, 0x2222, T);
        }
        printf("   packets: to_b=%d to_a=%d\n", b_t, a_t); int keys_ok = a_secure && b_secure && !memcmp(a_tx.tx.key, b_peer_key, 16) && !memcmp(a_tx.tx.salt, b_peer_salt, 14) && !memcmp(a_tx.rx.key, b_self_key, 16) && !memcmp(a_tx.rx.salt, b_self_salt, 14);
        int sas_ok = !strncmp(a_sas, b_sas, 4);
        printf("round %2d%s: secure A=%d B=%d keys %s SAS %s/%s (%s) role of bzrtp=%d tag=%d (mine %d)\n", r, drop_mod ? " (lossy)" : "", a_secure, b_secure, keys_ok ? "match" : "DIFFER", a_sas, b_sas, sas_ok ? "match" : "DIFFER", keys_ok && sas_ok ? "ok" : "BAD", b_role, b_tag, a_tx.tag_len);
        if (keys_ok && sas_ok) ok++; else bad++;
        zrtp_free(a); bzrtp_destroyBzrtpContext(b, 0x2222);
    }
    printf("%d ok, %d bad\n", ok, bad); return bad != 0;
}
