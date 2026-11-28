/* A media peer that speaks ZRTP, for the mock PBX: listens on a UDP port (the one the mock PBX puts in its SDP), runs this repo's ZRTP engine, and
 * prints what happened so a test can check it. When the keys are agreed it sends SRTP of its own and counts the SRTP it receives and can read.
 * usage: zrtp_peer [port]   (default 40000) */
#include "../../native/zrtp/l1srtp.h"
#include "../../native/zrtp/zrtp.h"

#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <math.h>
/* G.711 mu-law of one 16-bit sample */
static uint8_t ulaw(int16_t pcm) {
    int s = pcm < 0 ? 0x80 : 0, v = pcm < 0 ? -pcm : pcm; if (v > 32635) v = 32635; v += 0x84;
    int e = 7; for (int m = 0x4000; (v & m) == 0 && e > 0; m >>= 1) e--;
    return (uint8_t)~(s | (e << 4) | ((v >> (e + 3)) & 0x0f));
}
static int sock; static struct sockaddr_in remote; static int have_remote;
static l1srtp_t rx, tx; static int have_rx, have_tx;

static void out(void *u, const uint8_t *p, size_t n) { (void)u; if (have_remote) sendto(sock, p, n, 0, (struct sockaddr *)&remote, sizeof remote); }
/* a small in-memory cache, so a second call from the same phone is recognized (key continuity), as a real phone would */
static struct { uint8_t zid[12]; zrtp_cache_entry e; int used; } cache[8];
static int cache_load(void *u, const uint8_t zid[12], zrtp_cache_entry *e) { (void)u; for (int i = 0; i < 8; i++) if (cache[i].used && !memcmp(cache[i].zid, zid, 12)) { *e = cache[i].e; return 1; } return 0; }
static void cache_store(void *u, const uint8_t zid[12], const zrtp_cache_entry *e) {
    (void)u; int k = -1; for (int i = 0; i < 8; i++) if (cache[i].used && !memcmp(cache[i].zid, zid, 12)) k = i;
    for (int i = 0; i < 8 && k < 0; i++) if (!cache[i].used) k = i; if (k < 0) k = 0;
    memcpy(cache[k].zid, zid, 12); cache[k].e = *e; cache[k].used = 1;
}
static void keys_rx(void *u, const zrtp_keys *k) { (void)u; l1srtp_init(&rx, k->rx.key, k->rx.salt, k->tag_len); have_rx = 1; }
static void secure(void *u, const zrtp_keys *k) { (void)u; l1srtp_init(&tx, k->tx.key, k->tx.salt, k->tag_len); have_tx = 1; printf("zrtp-peer: secure\n"); fflush(stdout); }
static void sas(void *u, const char *s, int known, int mismatch, int verified) { (void)u; printf("zrtp-peer: sas %s known=%d mismatch=%d verified=%d\n", s, known, mismatch, verified); fflush(stdout); }
static void failed(void *u, zrtp_failure w, int code) { (void)u; printf("zrtp-peer: failed %d code %x\n", w, code); fflush(stdout); }

int main(int argc, char **argv) {
    int port = argc > 1 ? atoi(argv[1]) : 40000;
    sock = socket(AF_INET, SOCK_DGRAM, 0); int one = 1; setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(sock, (struct sockaddr *)&a, sizeof a) != 0) { perror("bind"); return 1; }
    uint8_t zid[12]; srand((unsigned)getpid()); for (int i = 0; i < 12; i++) zid[i] = (uint8_t)rand();
    zrtp_callbacks cb = { .send = out, .keys_rx = keys_rx, .secure = secure, .sas = sas, .failed = failed, .cache_load = cache_load, .cache_store = cache_store };
    zrtp_t *z = zrtp_new(&cb, zid, 0x70707070u);
    int started = 0, seq = 0, got = 0; uint32_t ts = 0;          /* a new caller (another source port) starts a new session */
    for (;;) {
        struct pollfd p = { sock, POLLIN, 0 }; int ms = zrtp_poll(z); if (ms < 0 || ms > 20) ms = 20;
        if (poll(&p, 1, ms) > 0) {
            uint8_t buf[1600]; struct sockaddr_in from; socklen_t fl = sizeof from;
            ssize_t n = recvfrom(sock, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
            if (n > 0) {
                if (!have_remote || from.sin_port != remote.sin_port) {
                    if (have_remote) { zrtp_free(z); z = zrtp_new(&cb, zid, 0x70707070u); started = 0; seq = 0; got = 0; have_rx = have_tx = 0; }
                    remote = from; have_remote = 1;
                }
                if (!started) { started = 1; zrtp_start(z); }
                if (zrtp_is_zrtp(buf, (size_t)n)) zrtp_recv(z, buf, (size_t)n);
                else if (!have_rx) { static int clear_n; if (clear_n++ < 2) { printf("zrtp-peer: media in the clear before keys: %zd bytes\n", n); fflush(stdout); } }
                else if (have_rx && !(buf[0] == 0x80 && n > 0 && (buf[1] & 0x7f) >= 72 && (buf[1] & 0x7f) <= 76)) {      /* RTP; RTCP is not looked at */
                    size_t len = (size_t)n;
                    int rc = l1srtp_unprotect(&rx, buf, &len);
                    static int shown; if (rc != 0 && shown++ < 3) { printf("zrtp-peer: could not read an SRTP packet (%d), %zd bytes\n", rc, n); fflush(stdout); }
                    if (rc == 0) { zrtp_srtp_seen(z); if (++got % 25 == 1) { printf("zrtp-peer: srtp-rx %d\n", got); fflush(stdout); } }
                }
            }
        }
        zrtp_poll(z);
        static struct timespec last; struct timespec nowt; clock_gettime(CLOCK_MONOTONIC, &nowt);
        if (have_tx && have_remote && (nowt.tv_sec - last.tv_sec) * 1000 + (nowt.tv_nsec - last.tv_nsec) / 1000000 >= 20) {        /* 20 ms of tone */
            uint8_t pkt[200]; memset(pkt, 0xff, sizeof pkt); static int phase;
            for (int i = 0; i < 160; i++) pkt[12 + i] = ulaw((int16_t)(6000 * sin(2 * 3.14159265 * 440 * phase++ / 8000.0)));       /* a 440 Hz tone: what you hear when SRTP works */
            if (phase > 80000) phase = 0; pkt[0] = 0x80; pkt[1] = 0; pkt[2] = seq >> 8; pkt[3] = (uint8_t)seq; seq++;
            pkt[4] = ts >> 24; pkt[5] = ts >> 16; pkt[6] = ts >> 8; pkt[7] = (uint8_t)ts; ts += 160; pkt[8] = 0x70; pkt[9] = 0x70; pkt[10] = 0x70; pkt[11] = 0x70;
            size_t len = 12 + 160; if (l1srtp_protect(&tx, pkt, &len, sizeof pkt) == 0) sendto(sock, pkt, len, 0, (struct sockaddr *)&remote, sizeof remote);
            last = nowt;
        }
    }
}
