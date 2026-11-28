#include "l1ne_autoanswer.h"

#include <ctype.h>
#include <string.h>

static int contains(const pj_str_t *v, const char *needle) {
    size_t n = strlen(needle); if (!v || v->slen < (pj_ssize_t)n) return 0;
    for (pj_ssize_t i = 0; i + (pj_ssize_t)n <= v->slen; i++) {
        size_t k = 0; while (k < n && tolower((unsigned char)v->ptr[i + (pj_ssize_t)k]) == needle[k]) k++;
        if (k == n) return 1;
    }
    return 0;
}

int l1ne_invite_auto_answer(const pjsip_rx_data *rdata) {
    if (!rdata || !rdata->msg_info.msg) return 0;
    static const char *alert[] = { "info=alert-autoanswer", "info=auto-answer", "info=autoanswer", "auto answer", "auto-answer", "intercom" };
    static const char *call[] = { "answer-after=0", "auto-answer", "autoanswer" };
    pj_str_t an = pj_str((char *)"Alert-Info"), cn = pj_str((char *)"Call-Info");
    const pjsip_hdr *h = NULL; pjsip_msg *msg = rdata->msg_info.msg;
    for (h = pjsip_msg_find_hdr_by_name(msg, &an, NULL); h; h = pjsip_msg_find_hdr_by_name(msg, &an, h->next)) {
        const pjsip_generic_string_hdr *g = (const pjsip_generic_string_hdr *)h;
        for (unsigned i = 0; i < sizeof alert / sizeof *alert; i++) if (contains(&g->hvalue, alert[i])) return 1;
        if (h->next == (const pjsip_hdr *)&msg->hdr) break;
    }
    for (h = pjsip_msg_find_hdr_by_name(msg, &cn, NULL); h; h = pjsip_msg_find_hdr_by_name(msg, &cn, h->next)) {
        const pjsip_generic_string_hdr *g = (const pjsip_generic_string_hdr *)h;
        for (unsigned i = 0; i < sizeof call / sizeof *call; i++) if (contains(&g->hvalue, call[i])) return 1;
        if (h->next == (const pjsip_hdr *)&msg->hdr) break;
    }
    return 0;
}
