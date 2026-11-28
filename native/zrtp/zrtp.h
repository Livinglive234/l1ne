/* ZRTP (RFC 6189) media key agreement: a clean-room implementation, MIT licensed, built on OpenSSL's crypto only.
 * The engine does no network or timer work of its own: it is given packets (zrtp_recv), asked what is due (zrtp_poll) and hands
 * packets to send and keys to install back through callbacks, so it runs the same on iOS and Android and can be tested in memory.
 *
 * Supported: Diffie-Hellman mode with DH3k and ECDH on P-256 (EC25), SHA-256, AES-128, SRTP HMAC-SHA1 tags of 80 and 32 bits, base32 SAS, a cache of retained
 * secrets (key continuity) with the SAS verified flag, Hello/Commit/DHPart/Confirm retransmission, commit contention.
 * Not supported (the RFC leaves them optional): Preshared and Multistream modes, GoClear, PBX trusted-MiTM, signatures, EC and DH2k. */
#ifndef L1NE_ZRTP_H
#define L1NE_ZRTP_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZRTP_ZID_LEN 12
#define ZRTP_MAX_PACKET 520

typedef struct { uint8_t key[16]; uint8_t salt[14]; } zrtp_master;
typedef struct {
    zrtp_master tx, rx;        /* the keys for what we send and for what we receive */
    int tag_len;               /* SRTP authentication tag: 4 (HS32) or 10 (HS80) bytes */
} zrtp_keys;

/* What is remembered about one peer between calls. */
typedef struct {
    uint8_t rs1[32], rs2[32];
    int has_rs1, has_rs2;
    int verified;              /* the user once confirmed the short authentication string with this peer */
    uint32_t expires;          /* seconds the secret may be kept (0xffffffff: always), 0: do not keep */
} zrtp_cache_entry;

typedef enum {
    ZRTP_FAIL_TIMEOUT = 1,         /* the other side never answered (it does not speak ZRTP) */
    ZRTP_FAIL_PROTOCOL,            /* a message was wrong, or the other side sent an Error */
    ZRTP_FAIL_ATTACK,              /* a check that only fails when someone changed messages on the way (hvi, hash chain, MACs) */
} zrtp_failure;

typedef struct {
    void *user;
    /* Sends one ZRTP packet (header, message, CRC) on the media path. */
    void (*send)(void *user, const uint8_t *packet, size_t len);
    /* Keys for what the other side sends us: install them so SRTP can be read. */
    void (*keys_rx)(void *user, const zrtp_keys *k);
    /* The exchange is confirmed: start protecting what we send. (Called after keys_rx, on both sides.) */
    void (*secure)(void *user, const zrtp_keys *k);
    /* The short authentication string to read out loud, and what is known about the peer. */
    void (*sas)(void *user, const char sas[5], int peer_known_before, int cache_mismatch, int verified_before);
    void (*failed)(void *user, zrtp_failure why, int code);
    /* The cache of retained secrets. load returns 1 when the peer is known. */
    int (*cache_load)(void *user, const uint8_t zid[ZRTP_ZID_LEN], zrtp_cache_entry *entry);
    void (*cache_store)(void *user, const uint8_t zid[ZRTP_ZID_LEN], const zrtp_cache_entry *entry);
    /* Milliseconds from any steady clock; NULL: the system's monotonic clock. */
    uint64_t (*now_ms)(void *user);
} zrtp_callbacks;

typedef struct zrtp zrtp_t;

/* zrtp_new_ex options */
#define ZRTP_ENABLE_EC 1         /* also offer the elliptic-curve key agreement (EC25), preferred when both have it. Off by default: DH3k takes only a few milliseconds even on a modest phone,
                          * and EC25 has not been tested against another implementation (see tests/zrtp/README) */

/* zid: this installation's 96-bit ZRTP id. ssrc: the SSRC of the RTP stream these packets belong to. */
zrtp_t *zrtp_new(const zrtp_callbacks *cb, const uint8_t zid[ZRTP_ZID_LEN], uint32_t ssrc);
zrtp_t *zrtp_new_ex(const zrtp_callbacks *cb, const uint8_t zid[ZRTP_ZID_LEN], uint32_t ssrc, int opts);
void zrtp_free(zrtp_t *z);

/* Starts sending Hello messages. Call once the media path can carry packets. */
void zrtp_start(zrtp_t *z);

/* The SSRC of our RTP stream, once it is known (it is put into the header of every ZRTP packet). */
void zrtp_set_ssrc(zrtp_t *z, uint32_t ssrc);
/* SHA-256 of our Hello message: what goes into the a=zrtp-hash SDP attribute (section 8.1). */
void zrtp_hello_hash(const zrtp_t *z, uint8_t out[32]);

/* True and consumed when the packet is a ZRTP packet (first byte 0x10 and the 'ZRTP' cookie). */
int zrtp_is_zrtp(const uint8_t *pkt, size_t len);
int zrtp_recv(zrtp_t *z, const uint8_t *pkt, size_t len);

/* Sends what is due. Returns the milliseconds until the next call is needed, or -1 when nothing is waiting. Call it when the time is up and after recv. */
int zrtp_poll(zrtp_t *z);

/* The first correctly authenticated SRTP packet from the other side counts as the answer to our Confirm2. */
void zrtp_srtp_seen(zrtp_t *z);

/* The user said the code matched (1) or did not (0). Saves or removes the retained secret, and is sent as the verified flag next time. */
void zrtp_set_verified(zrtp_t *z, int verified);

const char *zrtp_key_agreement(const zrtp_t *z);   /* "EC25" or "DH3k", once chosen */
int zrtp_is_secure(const zrtp_t *z);
int zrtp_is_failed(const zrtp_t *z);
const char *zrtp_sas(const zrtp_t *z);          /* 4 characters once known, else "" */

/* The ZRTP packet CRC (CRC-32C), exposed for tests. */
uint32_t zrtp_crc32c(const uint8_t *data, size_t len);
/* The key derivation function of section 4.5.1 with HMAC-SHA-256, exposed for tests. */
void zrtp_kdf(const uint8_t *ki, size_t ki_len, const char *label, const uint8_t *ctx, size_t ctx_len, uint32_t bits, uint8_t *out);

#ifdef __cplusplus
}
#endif
#endif
