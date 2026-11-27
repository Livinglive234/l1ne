#include "l1srtp.h"

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <string.h>

#define RTCP_TAG 10

static void ctr(const uint8_t key[16], const uint8_t iv[16], const uint8_t *in, uint8_t *out, size_t n) {
    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new(); int l = 0, l2 = 0;
    if (c && EVP_EncryptInit_ex(c, EVP_aes_128_ctr(), NULL, key, iv) == 1) { EVP_EncryptUpdate(c, out, &l, in, (int)n); EVP_EncryptFinal_ex(c, out + l, &l2); }
    EVP_CIPHER_CTX_free(c);
}

static void hmac_sha1(const uint8_t *key, size_t kl, const uint8_t *a, size_t an, const uint8_t *b, size_t bn, uint8_t out[20]) {
    uint8_t buf[2048]; size_t ol = 0; if (an + bn > sizeof buf) { memset(out, 0, 20); return; }
    memcpy(buf, a, an); memcpy(buf + an, b, bn);
    EVP_Q_mac(NULL, "HMAC", NULL, "SHA1", NULL, key, kl, buf, an + bn, out, 20, &ol);
}

/* RFC 3711 4.3.1: the key stream for label `label` is AES-CM under the master key with IV = (key_id XOR master_salt) * 2^16, key_id = label || 0 (48 bits). */
void l1srtp_derive(const uint8_t mk[16], const uint8_t ms[14], uint8_t label, uint8_t *out, size_t n) {
    uint8_t iv[16] = {0}, zero[32] = {0};
    memcpy(iv, ms, 14); iv[7] ^= label;
    ctr(mk, iv, zero, out, n);
}

int l1srtp_init(l1srtp_t *c, const uint8_t mk[16], const uint8_t ms[14], int tag_len) {
    memset(c, 0, sizeof *c); c->tag_len = tag_len;
    l1srtp_derive(mk, ms, 0x00, c->enc_key, 16); l1srtp_derive(mk, ms, 0x01, c->auth_key, 20); l1srtp_derive(mk, ms, 0x02, c->salt, 14);
    l1srtp_derive(mk, ms, 0x03, c->rtcp_enc_key, 16); l1srtp_derive(mk, ms, 0x04, c->rtcp_auth_key, 20); l1srtp_derive(mk, ms, 0x05, c->rtcp_salt, 14);
    return 0;
}

/* Where the payload starts in an RTP packet; -1 when the header is not valid. */
static int rtp_header_len(const uint8_t *p, size_t n) {
    if (n < 12 || (p[0] >> 6) != 2) return -1;
    size_t h = 12 + 4 * (size_t)(p[0] & 15);
    if (p[0] & 0x10) { if (n < h + 4) return -1; h += 4 + 4 * (size_t)(((p[h + 2] << 8) | p[h + 3])); }
    return h <= n ? (int)h : -1;
}

static void packet_iv(const uint8_t salt[14], uint32_t ssrc, uint64_t index, uint8_t iv[16]) {
    memset(iv, 0, 16); memcpy(iv, salt, 14);
    iv[4] ^= ssrc >> 24; iv[5] ^= ssrc >> 16; iv[6] ^= ssrc >> 8; iv[7] ^= ssrc;
    for (int i = 0; i < 6; i++) iv[8 + i] ^= (uint8_t)(index >> (8 * (5 - i)));
}

int l1srtp_protect(l1srtp_t *c, uint8_t *p, size_t *len, size_t cap) {
    int h = rtp_header_len(p, *len); if (h < 0 || *len + (size_t)c->tag_len > cap) return -1;
    uint16_t seq = (uint16_t)(p[2] << 8 | p[3]); uint32_t ssrc = (uint32_t)p[8] << 24 | p[9] << 16 | p[10] << 8 | p[11];
    if (c->tx_started && seq < c->tx_last_seq && c->tx_last_seq - seq > 0x8000) c->tx_roc++;      /* the sequence number wrapped */
    c->tx_last_seq = seq; c->tx_started = 1;
    uint64_t index = ((uint64_t)c->tx_roc << 16) | seq; uint8_t iv[16];
    packet_iv(c->salt, ssrc, index, iv);
    ctr(c->enc_key, iv, p + h, p + h, *len - (size_t)h);
    uint8_t roc[4] = { c->tx_roc >> 24, c->tx_roc >> 16, c->tx_roc >> 8, c->tx_roc }, tag[20];
    hmac_sha1(c->auth_key, 20, p, *len, roc, 4, tag);
    memcpy(p + *len, tag, (size_t)c->tag_len); *len += (size_t)c->tag_len;
    return 0;
}

/* RFC 3711 appendix A: the packet index from the 16-bit sequence number and the rollover counter we hold. */
static uint32_t guess_roc(const l1srtp_t *c, uint16_t seq) {
    if (!c->rx_started) return c->rx_roc;
    if (c->rx_s_l < 32768) return (seq - c->rx_s_l > 32768) ? c->rx_roc - 1 : c->rx_roc;
    return (c->rx_s_l - 32768 > seq) ? c->rx_roc + 1 : c->rx_roc;
}

int l1srtp_unprotect(l1srtp_t *c, uint8_t *p, size_t *len) {
    size_t t = (size_t)c->tag_len; if (*len < 12 + t) return -1;
    size_t n = *len - t; int h = rtp_header_len(p, n); if (h < 0) return -1;
    uint16_t seq = (uint16_t)(p[2] << 8 | p[3]); uint32_t ssrc = (uint32_t)p[8] << 24 | p[9] << 16 | p[10] << 8 | p[11];
    if (c->rx_ssrc_set && ssrc != c->rx_ssrc) return -1;                                          /* one stream per context */
    uint32_t roc = guess_roc(c, seq); uint64_t index = ((uint64_t)roc << 16) | seq;
    uint64_t top = ((uint64_t)c->rx_roc << 16) | c->rx_s_l;
    if (c->rx_started && index <= top && top - index >= 64) return -2;                           /* too old */
    if (c->rx_started && index <= top && (c->rx_window >> (top - index)) & 1) return -3;          /* replayed */
    uint8_t rocb[4] = { roc >> 24, roc >> 16, roc >> 8, roc }, tag[20];
    hmac_sha1(c->auth_key, 20, p, n, rocb, 4, tag);
    if (CRYPTO_memcmp(tag, p + n, t) != 0) return -4;
    uint8_t iv[16]; packet_iv(c->salt, ssrc, index, iv);
    ctr(c->enc_key, iv, p + h, p + h, n - (size_t)h);
    if (!c->rx_started || index > top) {                                                          /* moves the window */
        uint64_t shift = c->rx_started ? index - top : 0;
        c->rx_window = shift >= 64 ? 0 : c->rx_window << shift; c->rx_window |= 1; c->rx_roc = roc; c->rx_s_l = seq; c->rx_started = 1;
    } else c->rx_window |= 1ull << (top - index);
    c->rx_ssrc = ssrc; c->rx_ssrc_set = 1;
    *len = n; return 0;
}

/* SRTCP: the packet is encrypted after its first 8 bytes, then comes E||index (4 bytes) and the 80-bit tag over everything before it. */
int l1srtp_protect_rtcp(l1srtp_t *c, uint8_t *p, size_t *len, size_t cap) {
    if (*len < 8 || *len + 4 + RTCP_TAG > cap) return -1;
    uint32_t ssrc = (uint32_t)p[4] << 24 | p[5] << 16 | p[6] << 8 | p[7]; uint32_t index = ++c->srtcp_index & 0x7fffffffu;           /* libsrtp starts at 1 too */ uint8_t iv[16];
    packet_iv(c->rtcp_salt, ssrc, index, iv);
    ctr(c->rtcp_enc_key, iv, p + 8, p + 8, *len - 8);
    uint32_t e = 0x80000000u | index; p[*len] = e >> 24; p[*len + 1] = e >> 16; p[*len + 2] = e >> 8; p[*len + 3] = e; *len += 4;
    uint8_t tag[20]; hmac_sha1(c->rtcp_auth_key, 20, p, *len, NULL, 0, tag);
    memcpy(p + *len, tag, RTCP_TAG); *len += RTCP_TAG; return 0;
}

int l1srtp_unprotect_rtcp(l1srtp_t *c, uint8_t *p, size_t *len) {
    if (*len < 8 + 4 + RTCP_TAG) return -1;
    size_t n = *len - RTCP_TAG; uint8_t tag[20];
    hmac_sha1(c->rtcp_auth_key, 20, p, n, NULL, 0, tag);
    if (CRYPTO_memcmp(tag, p + n, RTCP_TAG) != 0) return -4;
    uint32_t e = (uint32_t)p[n - 4] << 24 | p[n - 3] << 16 | p[n - 2] << 8 | p[n - 1], index = e & 0x7fffffffu;
    if (c->rx_rtcp_started) {                                                                      /* replay window */
        if (index <= c->rx_rtcp_max && c->rx_rtcp_max - index >= 64) return -2;
        if (index <= c->rx_rtcp_max && (c->rx_rtcp_window >> (c->rx_rtcp_max - index)) & 1) return -3;
    }
    uint32_t ssrc = (uint32_t)p[4] << 24 | p[5] << 16 | p[6] << 8 | p[7]; uint8_t iv[16];
    if (e & 0x80000000u) { packet_iv(c->rtcp_salt, ssrc, index, iv); ctr(c->rtcp_enc_key, iv, p + 8, p + 8, n - 4 - 8); }
    if (!c->rx_rtcp_started || index > c->rx_rtcp_max) {
        uint32_t shift = c->rx_rtcp_started ? index - c->rx_rtcp_max : 0;
        c->rx_rtcp_window = shift >= 64 ? 0 : c->rx_rtcp_window << shift; c->rx_rtcp_window |= 1; c->rx_rtcp_max = index; c->rx_rtcp_started = 1;
    } else c->rx_rtcp_window |= 1ull << (c->rx_rtcp_max - index);
    *len = n - 4; return 0;
}
