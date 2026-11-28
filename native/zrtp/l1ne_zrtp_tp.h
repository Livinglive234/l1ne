/* ZRTP as a PJSIP media transport: sits between the audio stream and the transport pjsua made for the call, runs the key agreement on the
 * media path, and protects RTP and RTCP with SRTP once the keys are agreed. Used by both apps (compiled into each). */
#ifndef L1NE_ZRTP_TP_H
#define L1NE_ZRTP_TP_H
#include <pjsua-lib/pjsua.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int state;               /* 0 negotiating, 1 secure, 2 failed (no ZRTP at the other end, or the exchange was refused), 3 switched to unencrypted on purpose */
    char sas[5];             /* the code to read out loud; "" until known */
    int cache_mismatch;      /* we had a secret from earlier calls with this peer, and they did not match: compare the code */
    int known_before;        /* we have talked to this peer before (key continuity) */
    int verified;            /* the user has confirmed the code with this peer before */
    int failure;             /* zrtp_failure when state is 2 */
    int can_go_clear;        /* secure, and the other side has said it accepts going unencrypted (never for a required-ZRTP call) */
    int clear_state;         /* 0 encrypted, 1 the call was switched to unencrypted and waits for the app to continue it, 2 unencrypted and flowing */
    int cleared_by_us;       /* the switch was our request */
} l1ne_zrtp_info;

/* Called from a media or timer thread whenever a call's state changes. */
typedef void (*l1ne_zrtp_listener)(void *user, int call_id, const l1ne_zrtp_info *info);

/* cache_path: the file with this installation's ZID and the secrets kept from earlier calls (created when missing). Returns 0 on success. */
int l1ne_zrtp_init(const char *cache_path, l1ne_zrtp_listener listener, void *user);

/* How calls of an account are keyed: 0 not at all (the transport is not added), 1 ZRTP when the other side has it (clear media otherwise), 2 ZRTP required
 * (no media is sent or accepted in the clear; the app is told when the exchange fails and ends the call). */
void l1ne_zrtp_set_account_mode(int acc_id, int mode);

/* Per-account ZRTP options (bits: 1 elliptic-curve key agreement, 2 accept a switch to unencrypted from the other side). Default 0. */
void l1ne_zrtp_set_account_options(int acc_id, int opts);

/* Ask to switch the call to unencrypted (returns 1 when the request went out; 0 when not allowed). The state reports it once the other side has agreed. */
int l1ne_zrtp_call_go_clear(int call_id);

/* After the other side switched the call to unencrypted, let the media flow (1), or leave it stopped so the app can hang up (0 does nothing). */
void l1ne_zrtp_call_resume_clear(int call_id);

/* Put this in pjsua_config.cb.on_create_media_transport. */
pjmedia_transport *l1ne_zrtp_on_create_media_transport(pjsua_call_id call_id, unsigned media_idx, pjmedia_transport *base_tp, unsigned flags);

/* The state of a call's ZRTP; returns 0 when the call has none. */
int l1ne_zrtp_call_info(int call_id, l1ne_zrtp_info *out);

/* The user compared the code with the other person: remember it (1), or the code did not match (0: forget this peer's secret). */
void l1ne_zrtp_call_verified(int call_id, int verified);

#ifdef __cplusplus
}
#endif
#endif
