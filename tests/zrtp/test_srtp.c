/* Tests of the SRTP layer: the RFC 3711 key derivation vectors, round trips with replay and tamper checks, and (when built with libsrtp) the same
 * packets protected by libsrtp, which must give byte-for-byte the same output. */
#include "../../native/zrtp/l1srtp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef WITH_LIBSRTP
#include "srtp.h"
#endif

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL  "); printf(__VA_ARGS__); printf("\n"); fails++; } else { printf("ok    "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static void hex(const char *s, uint8_t *out, size_t n) { for (size_t i = 0; i < n; i++) { unsigned v; sscanf(s + 2 * i, "%2x", &v); out[i] = v; } }

static size_t make_packet(uint8_t *p, uint16_t seq, uint32_t ts, uint32_t ssrc, size_t payload, int ext, int csrc) {
    size_t h = 12 + 4 * (size_t)csrc; memset(p, 0, 64);
    p[0] = 0x80 | (ext ? 0x10 : 0) | csrc; p[1] = 0; p[2] = seq >> 8; p[3] = seq; p[4] = ts >> 24; p[5] = ts >> 16; p[6] = ts >> 8; p[7] = ts;
    p[8] = ssrc >> 24; p[9] = ssrc >> 16; p[10] = ssrc >> 8; p[11] = ssrc;
    if (ext) { p[h] = 0xBE; p[h + 1] = 0xDE; p[h + 2] = 0; p[h + 3] = 1; h += 8; }
    for (size_t i = 0; i < payload; i++) p[h + i] = (uint8_t)(i * 7 + seq);
    return h + payload;
}

int main(void) {
    /* RFC 3711 appendix B.3 */
    uint8_t mk[16], ms[14], out[20], want[20];
    hex("E1F97A0D3E018BE0D64FA32C06DE4139", mk, 16); hex("0EC675AD498AFEEBB6960B3AABE6", ms, 14);
    l1srtp_derive(mk, ms, 0x00, out, 16); hex("C61E7A93744F39EE10734AFE3FF7A087", want, 16); CHECK(!memcmp(out, want, 16), "RFC 3711 B.3: cipher key");
    l1srtp_derive(mk, ms, 0x02, out, 14); hex("30CBBC08863D8C85D49DB34A9AE1", want, 14); CHECK(!memcmp(out, want, 14), "RFC 3711 B.3: cipher salt");
    l1srtp_derive(mk, ms, 0x01, out, 20); hex("CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4", want, 20); CHECK(!memcmp(out, want, 20), "RFC 3711 B.3: auth key");

    for (int tag = 4; tag <= 10; tag += 6) {
        l1srtp_t tx, rx; l1srtp_init(&tx, mk, ms, tag); l1srtp_init(&rx, mk, ms, tag);
        uint8_t p[1500], orig[1500]; size_t n = make_packet(p, 1000, 160, 0xDEADBEEF, 160, 0, 0); memcpy(orig, p, n); size_t len = n;
        CHECK(l1srtp_protect(&tx, p, &len, sizeof p) == 0 && len == n + (size_t)tag && memcmp(p + 12, orig + 12, 160) != 0, "tag %d: protect encrypts and adds the tag", tag);
        uint8_t copy[1500]; memcpy(copy, p, len); size_t clen = len;
        CHECK(l1srtp_unprotect(&rx, p, &len) == 0 && len == n && !memcmp(p, orig, n), "tag %d: unprotect restores the packet", tag);
        CHECK(l1srtp_unprotect(&rx, copy, &clen) != 0, "tag %d: a replayed packet is refused", tag);
        make_packet(p, 1001, 320, 0xDEADBEEF, 160, 0, 0); len = n; l1srtp_protect(&tx, p, &len, sizeof p); p[20] ^= 1;
        CHECK(l1srtp_unprotect(&rx, p, &len) != 0, "tag %d: a changed packet is refused", tag);
        /* rollover of the sequence number */
        l1srtp_t t2, r2; l1srtp_init(&t2, mk, ms, tag); l1srtp_init(&r2, mk, ms, tag); int ok = 1;
        for (uint32_t i = 0; i < 70000 && ok; i += 1) {
            uint16_t seq = (uint16_t)(65000 + i); n = make_packet(p, seq, i * 160, 0x1234, 40, i % 3 == 0, i % 2); memcpy(orig, p, n); len = n;
            if (l1srtp_protect(&t2, p, &len, sizeof p) || l1srtp_unprotect(&r2, p, &len) || len != n || memcmp(p, orig, n)) { ok = 0; printf("   broke at %u\n", i); }
        }
        CHECK(ok, "tag %d: 70000 packets across several sequence number rollovers, with extension headers and CSRCs", tag);
        /* SRTCP */
        uint8_t r[200] = { 0x81, 200, 0, 6, 0xCA, 0xFE, 0xBA, 0xBE, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 };
        size_t rl = 28, ro = rl; uint8_t ro_copy[200]; memcpy(ro_copy, r, rl);
        CHECK(l1srtp_protect_rtcp(&tx, r, &rl, sizeof r) == 0 && rl == ro + 14 && memcmp(r + 8, ro_copy + 8, 20) != 0, "tag %d: SRTCP protect", tag);
        CHECK(l1srtp_unprotect_rtcp(&rx, r, &rl) == 0 && rl == ro && !memcmp(r, ro_copy, ro), "tag %d: SRTCP unprotect restores the packet", tag);
    }

#ifdef WITH_LIBSRTP
    if (srtp_init() != srtp_err_status_ok) { printf("libsrtp init failed\n"); return 1; }
    for (int tag = 4; tag <= 10; tag += 6) {
        srtp_policy_t pol; memset(&pol, 0, sizeof pol);
        if (tag == 10) srtp_crypto_policy_set_aes_cm_128_hmac_sha1_80(&pol.rtp); else srtp_crypto_policy_set_aes_cm_128_hmac_sha1_32(&pol.rtp);
        srtp_crypto_policy_set_aes_cm_128_hmac_sha1_80(&pol.rtcp);
        uint8_t key[30]; memcpy(key, mk, 16); memcpy(key + 16, ms, 14);
        pol.ssrc.type = ssrc_any_outbound; pol.key = key; pol.window_size = 128; pol.allow_repeat_tx = 0;
        srtp_t s; CHECK(srtp_create(&s, &pol) == srtp_err_status_ok, "libsrtp session (tag %d)", tag);
        l1srtp_t tx; l1srtp_init(&tx, mk, ms, tag); int same = 1;
        for (uint32_t i = 0; i < 70000 && same; i++) {
            uint8_t a[1500], b[1500]; uint16_t seq = (uint16_t)(65000 + i); size_t n = make_packet(a, seq, i * 160, 0x1234, 40 + i % 100, i % 3 == 0, i % 2); memcpy(b, a, n);
            int la = (int)n; size_t lb = n;
            if (srtp_protect(s, a, &la) != srtp_err_status_ok || l1srtp_protect(&tx, b, &lb, sizeof b) != 0 || (size_t)la != lb || memcmp(a, b, lb)) { same = 0; printf("   differs at packet %u\n", i); }
        }
        CHECK(same, "tag %d: 70000 packets are byte-for-byte what libsrtp produces", tag);
        uint8_t r[200] = { 0x81, 200, 0, 6, 0x12, 0x34, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 }, r2[200]; memcpy(r2, r, 28);
        int rl = 28; size_t rl2 = 28;
        srtp_protect_rtcp(s, r, &rl); l1srtp_protect_rtcp(&tx, r2, &rl2, sizeof r2);
        for (size_t i = 0; i < rl2 && rl == (int)rl2; i++) if (r[i] != r2[i]) { printf("   first difference at byte %zu: libsrtp %02x mine %02x (len %d vs %zu)\n", i, r[i], r2[i], rl, rl2); break; }
        CHECK((size_t)rl == rl2 && !memcmp(r, r2, rl2), "tag %d: SRTCP is byte-for-byte what libsrtp produces", tag);
        srtp_dealloc(s);
    }
#endif
    printf(fails ? "\n%d FAILED\n" : "\nALL PASSED\n", fails);
    return fails ? 1 : 0;
}
