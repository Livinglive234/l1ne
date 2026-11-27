/* SRTP / SRTCP (RFC 3711) with AES-CM-128 and HMAC-SHA1 tags of 80 or 32 bits, on OpenSSL's crypto. Used by the ZRTP transport, so that
 * ZRTP has no dependency on PJSIP's SRTP module. One context protects one direction of one RTP stream. */
#ifndef L1NE_SRTP_H
#define L1NE_SRTP_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t enc_key[16], salt[14], auth_key[20];             /* SRTP session keys */
    uint8_t rtcp_enc_key[16], rtcp_salt[14], rtcp_auth_key[20];
    int tag_len;                                             /* SRTP tag: 4 or 10; SRTCP always uses 10 */
    /* sending: one stream (a new SSRC starts again with rollover counter 0) */
    uint32_t tx_ssrc, tx_roc; uint16_t tx_last_seq; int tx_started; uint32_t srtcp_index;
    /* receiving: replay state per SSRC, for up to 4 streams */
    struct { int used; uint32_t ssrc, roc; uint16_t s_l; int started; uint64_t window; } rx[4]; unsigned rx_next;
    uint32_t rx_rtcp_max; int rx_rtcp_started; uint64_t rx_rtcp_window;
} l1srtp_t;

#define L1SRTP_MAX_OVERHEAD 16                               /* bytes added to a packet: tag (10) and the SRTCP index (4) */

/* Derives the session keys from a master key and salt (RFC 3711 section 4.3, key derivation rate 0). */
int l1srtp_init(l1srtp_t *c, const uint8_t master_key[16], const uint8_t master_salt[14], int tag_len);

/* In place; `cap` is the room in the buffer (the packet grows). Return 0 on success. */
int l1srtp_protect(l1srtp_t *c, uint8_t *pkt, size_t *len, size_t cap);
int l1srtp_unprotect(l1srtp_t *c, uint8_t *pkt, size_t *len);
int l1srtp_protect_rtcp(l1srtp_t *c, uint8_t *pkt, size_t *len, size_t cap);
int l1srtp_unprotect_rtcp(l1srtp_t *c, uint8_t *pkt, size_t *len);

/* exposed for tests */
void l1srtp_derive(const uint8_t master_key[16], const uint8_t master_salt[14], uint8_t label, uint8_t *out, size_t n);

#ifdef __cplusplus
}
#endif
#endif
