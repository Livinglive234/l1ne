/* Does an incoming INVITE ask the phone to answer by itself (an intercom or page)? Shared by both apps. */
#ifndef L1NE_AUTOANSWER_H
#define L1NE_AUTOANSWER_H
#include <pjsua-lib/pjsua.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the INVITE carries one of the usual auto-answer signals: Call-Info with "answer-after=0" (or "auto-answer"), or Alert-Info with
 * "info=alert-autoanswer", "info=auto-answer", "Auto Answer" or "intercom" (Asterisk paging and intercom, Cisco, Polycom, Yealink, Grandstream). */
int l1ne_invite_auto_answer(const pjsip_rx_data *rdata);

#ifdef __cplusplus
}
#endif
#endif
