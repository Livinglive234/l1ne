/* Thin JNI bridge over pjsua for L1ne (Android). Events go up through one Kotlin callback:
   Native.onEvent(type, a, b, s1, s2). Calls go down as plain functions. Mirrors ios/SIPEngine.swift. */
#include <android/log.h>
#include <jni.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pjsua-lib/pjsua.h>

#define THIS_FILE "l1ne_sip"
static JavaVM *g_vm;
static jclass g_cls;
static jmethodID g_event;
static pj_pool_t *g_pool;
static pjsua_transport_id g_tls = -1;
static int g_accept_early = 0;

static JNIEnv *env_attach(int *attached) {
    JNIEnv *e = NULL; *attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void **)&e, JNI_VERSION_1_6) == JNI_OK) return e;
    if ((*g_vm)->AttachCurrentThread(g_vm, &e, NULL) == JNI_OK) { *attached = 1; return e; }
    return NULL;
}
static void emit(const char *type, int a, int b, const char *s1, const char *s2) {
    int at; JNIEnv *e = env_attach(&at); if (!e) return;
    jstring jt = (*e)->NewStringUTF(e, type), j1 = (*e)->NewStringUTF(e, s1 ? s1 : ""), j2 = (*e)->NewStringUTF(e, s2 ? s2 : "");
    (*e)->CallStaticVoidMethod(e, g_cls, g_event, jt, a, b, j1, j2);
    (*e)->DeleteLocalRef(e, jt); (*e)->DeleteLocalRef(e, j1); (*e)->DeleteLocalRef(e, j2);
    if (at) (*g_vm)->DetachCurrentThread(g_vm);
}
static void cstr(pj_str_t s, char *out, size_t n) { size_t l = s.slen < (pj_ssize_t)n - 1 ? (size_t)s.slen : n - 1; memcpy(out, s.ptr, l); out[l] = 0; }
static pj_str_t pjdup(const char *c) { pj_str_t o; pj_strdup2_with_null(g_pool, &o, c); return o; }
static void reg_thread(void) { if (!pj_thread_is_registered()) { static pj_thread_desc d[8]; static int i; pj_thread_t *t; pj_thread_register("jni", d[i++ % 8], &t); } }

#include "l1ne_autoanswer.h"
static int g_auto[PJSUA_MAX_CALLS];            /* the INVITE asked to be answered automatically (an intercom or page) */
static void send_call(pjsua_call_id id, const char *type) {
    pjsua_call_info ci; if (pjsua_call_get_info(id, &ci) != 0) return;
    char remote[256], lbl[128], s2[512];
    cstr(ci.remote_info, remote, sizeof remote); cstr(ci.last_status_text, lbl, sizeof lbl);
    /* s2: role|lastStatus|reason|connectedSeconds|media|account|asksForAutoAnswer */
    snprintf(s2, sizeof s2, "%d|%d|%s|%ld|%d|%d|%d", (int)ci.role, (int)ci.last_status, lbl, (long)ci.connect_duration.sec, (int)ci.media_status, (int)ci.acc_id, id >= 0 && id < PJSUA_MAX_CALLS ? g_auto[id] : 0);
    emit(type, id, (int)ci.state, remote, s2);
}
/* A muted call must stay muted when PJSIP reports a state or media change (hold/resume, re-INVITE): the microphone is only reconnected for calls not muted. */
static int g_muted[PJSUA_MAX_CALLS];
static void mic_connect(pjsua_call_id call, int slot) { pjsua_conf_connect(slot, 0); if (call < 0 || call >= PJSUA_MAX_CALLS || !g_muted[call]) pjsua_conf_connect(0, slot); }
/* ZRTP: "state|code|cacheMismatch|knownBefore|verified|failure" for a call, as it changes (see native/zrtp) */
#include "l1ne_zrtp_tp.h"
static char g_zrtp_path[512];
static void zrtp_listener(void *u, int call, const l1ne_zrtp_info *i) {
    (void)u; char s[80]; snprintf(s, sizeof s, "%d|%s|%d|%d|%d|%d|%d|%d|%d", i->state, i->sas, i->cache_mismatch, i->known_before, i->verified, i->failure, i->can_go_clear, i->clear_state, i->cleared_by_us);
    emit("zrtp", call, i->state, s, "");
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nZrtpCache(JNIEnv *env, jclass c, jstring p) {
    (void)c; const char *s = (*env)->GetStringUTFChars(env, p, NULL); strncpy(g_zrtp_path, s, sizeof g_zrtp_path - 1); (*env)->ReleaseStringUTFChars(env, p, s);
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nZrtpOptions(JNIEnv *e, jclass c, jint acc, jint opts) { (void)e; (void)c; l1ne_zrtp_set_account_options(acc, opts); }
JNIEXPORT jboolean JNICALL Java_com_livenet_l1ne_sip_Native_nZrtpGoClear(JNIEnv *e, jclass c, jint call) { (void)e; (void)c; reg_thread(); return l1ne_zrtp_call_go_clear(call) ? JNI_TRUE : JNI_FALSE; }
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nZrtpResumeClear(JNIEnv *e, jclass c, jint call) { (void)e; (void)c; reg_thread(); l1ne_zrtp_call_resume_clear(call); }
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nZrtpVerified(JNIEnv *e, jclass c, jint call, jboolean on) { (void)e; (void)c; reg_thread(); l1ne_zrtp_call_verified(call, on ? 1 : 0); }
static void on_incoming(pjsua_acc_id acc, pjsua_call_id call, pjsip_rx_data *rd) { (void)acc; if (call >= 0 && call < PJSUA_MAX_CALLS) { g_muted[call] = 0; g_auto[call] = l1ne_invite_auto_answer(rd); } send_call(call, "incoming"); }
static void on_call_state(pjsua_call_id call, pjsip_event *e) {
    (void)e; pjsua_call_info ci;
    if (pjsua_call_get_info(call, &ci) == 0 && ci.state == PJSIP_INV_STATE_CONFIRMED && ci.media_status == PJSUA_CALL_MEDIA_ACTIVE && ci.conf_slot >= 0) { mic_connect(call, ci.conf_slot); }   /* belt and braces */
    send_call(call, "call");
}
static void on_media_state(pjsua_call_id call) {
    pjsua_call_info ci; if (pjsua_call_get_info(call, &ci) != 0) return;
    if (ci.media_status == PJSUA_CALL_MEDIA_ACTIVE && (ci.role != PJSIP_ROLE_UAC || ci.state != PJSIP_INV_STATE_EARLY || g_accept_early)  /* early media only exists on calls we placed: answering an incoming call starts media while it still reads EARLY */) { mic_connect(call, ci.conf_slot); }
    send_call(call, "call");
}
static void on_reg_state(pjsua_acc_id acc) {
    pjsua_acc_info i; if (pjsua_acc_get_info(acc, &i) != 0) return;
    char t[128]; cstr(i.status_text, t, sizeof t); emit("reg", acc, (int)i.status, t, "");
}
static void on_mwi(pjsua_acc_id acc, pjsua_mwi_info *info) {
    /* count after "Voice-Message:" in the body, e.g. "Voice-Message: 3/1 (0/0)" */
    if (!info || !info->rdata || !info->rdata->msg_info.msg || !info->rdata->msg_info.msg->body) return;
    pjsip_msg_body *b = info->rdata->msg_info.msg->body; char buf[512]; size_t n = b->len < sizeof buf - 1 ? b->len : sizeof buf - 1;
    memcpy(buf, b->data, n); buf[n] = 0;
    char *p = strcasestr(buf, "voice-message:"); int cnt = 0;
    if (p) cnt = atoi(p + 14); else if (strcasestr(buf, "messages-waiting: yes")) cnt = 1;
    emit("mwi", acc, cnt, "", "");
}
static void on_pager(pjsua_call_id c, const pj_str_t *from, const pj_str_t *to, const pj_str_t *contact, const pj_str_t *mime, const pj_str_t *body, pjsip_rx_data *rd, pjsua_acc_id acc) {
    (void)c; (void)to; (void)contact; (void)rd;
    char m[64], f[256]; static char text[8192];
    cstr(*mime, m, sizeof m); if (strncasecmp(m, "text/plain", 10)) return;
    cstr(*from, f, sizeof f); cstr(*body, text, sizeof text); emit("message", acc, 0, f, text);
}
static void on_pager_status(pjsua_call_id c, const pj_str_t *to, const pj_str_t *body, void *user, pjsip_status_code st, const pj_str_t *reason, pjsip_tx_data *tx, pjsip_rx_data *rd, pjsua_acc_id acc) {
    (void)c; (void)to; (void)body; (void)tx; (void)rd; (void)acc;
    char r[128]; cstr(*reason, r, sizeof r); emit("sent", (int)(intptr_t)user, (int)st, r, "");
}

/* How a transfer you asked for is going: the other side reports it as it goes (100 Trying, 180 Ringing, then a final 200 or an error). */
static void on_xfer_status(pjsua_call_id c, int code, const pj_str_t *txt, pj_bool_t final, pj_bool_t *cont) {
    (void)cont; char r[128]; cstr(*txt, r, sizeof r); emit("xfer", c, code, r, final ? "1" : "0");
}

static void log_cb(int level, const char *data, int len) {
    /* pjlib log writer: android log, and the in-app SIP log */
    __android_log_print(level <= 2 ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO, "pjsip", "%.*s", len, data);
    if (len <= 0 || !g_cls) return;
    char buf[4096]; int n = len < (int)sizeof buf - 1 ? len : (int)sizeof buf - 1;
    for (int i = 0; i < n; i++) { unsigned char c = (unsigned char)data[i]; buf[i] = (c >= 32 && c < 127) || c == '\n' || c == '\r' || c == '\t' ? (char)c : '?'; }   /* plain ASCII only: JNI needs valid UTF-8 */
    buf[n] = 0;
    emit("log", level, 0, buf, "");
}

JNIEXPORT jint JNICALL Java_com_livenet_l1ne_sip_Native_nInit(JNIEnv *env, jclass cls, jstring caFile, jboolean ipv6) {
    (*env)->GetJavaVM(env, &g_vm);
    g_cls = (*env)->NewGlobalRef(env, cls);
    g_event = (*env)->GetStaticMethodID(env, cls, "onEvent", "(Ljava/lang/String;IILjava/lang/String;Ljava/lang/String;)V");
    pj_status_t st = pjsua_create(); if (st != PJ_SUCCESS) return st;
    l1ne_zrtp_init(g_zrtp_path, zrtp_listener, NULL);
    pjsua_config cfg; pjsua_config_default(&cfg); cfg.max_calls = 4;
    cfg.cb.on_incoming_call = on_incoming; cfg.cb.on_call_state = on_call_state; cfg.cb.on_call_media_state = on_media_state;
    cfg.cb.on_reg_state = on_reg_state; cfg.cb.on_mwi_info = on_mwi; cfg.cb.on_pager2 = on_pager; cfg.cb.on_pager_status2 = on_pager_status; cfg.cb.on_call_transfer_status = on_xfer_status; cfg.cb.on_create_media_transport = l1ne_zrtp_on_create_media_transport;
    pjsua_logging_config lc; pjsua_logging_config_default(&lc); lc.console_level = 0; lc.level = 5; lc.cb = log_cb;
    pjsua_media_config mc; pjsua_media_config_default(&mc); mc.snd_auto_close_time = 5;
    if ((st = pjsua_init(&cfg, &lc, &mc)) != PJ_SUCCESS) return st;
    pj_log_set_level(5); pj_log_set_log_func((void (*)(int, const char *, int))log_cb);
    pjsua_transport_config t; pjsua_transport_config_default(&t);
    t.tls_setting.verify_server = PJ_TRUE;
    static char ca[512];
    if (caFile) { const char *c = (*env)->GetStringUTFChars(env, caFile, NULL); strncpy(ca, c, sizeof ca - 1); (*env)->ReleaseStringUTFChars(env, caFile, c); t.tls_setting.ca_list_file = pj_str(ca); }
    if ((st = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &t, &g_tls)) != PJ_SUCCESS) return st;
    pjsua_transport_config o; pjsua_transport_config_default(&o); pjsua_transport_id id;
    pjsua_transport_create(PJSIP_TRANSPORT_UDP, &o, &id); pjsua_transport_create(PJSIP_TRANSPORT_TCP, &o, &id);
    if (ipv6) { pjsua_transport_create(PJSIP_TRANSPORT_TLS6, &t, &id); pjsua_transport_create(PJSIP_TRANSPORT_UDP6, &o, &id); pjsua_transport_create(PJSIP_TRANSPORT_TCP6, &o, &id); }
    g_pool = pjsua_pool_create("l1ne-cfg", 2048, 2048);
    if ((st = pjsua_start()) != PJ_SUCCESS) return st;
    pjsua_set_no_snd_dev();
    return 0;
}

/* srtp: 0 none, 1 SDES, 2 DTLS, 3 ZRTP; mandatory 0/1 */
JNIEXPORT jint JNICALL Java_com_livenet_l1ne_sip_Native_nAddAccount(JNIEnv *env, jclass c, jstring jid, jstring jreg, jstring jroute, jstring juser, jstring jpass,
        jint srtp, jboolean mandatory, jboolean secureSig, jint expires, jboolean mwi, jboolean ipv6, jstring jstun, jboolean ice, jboolean turn, jstring jtuser, jstring jtpass) {
    (void)c; reg_thread();
    const char *id = (*env)->GetStringUTFChars(env, jid, NULL), *reg = (*env)->GetStringUTFChars(env, jreg, NULL), *route = (*env)->GetStringUTFChars(env, jroute, NULL),
               *user = (*env)->GetStringUTFChars(env, juser, NULL), *pass = (*env)->GetStringUTFChars(env, jpass, NULL);
    pjsua_acc_config ac; pjsua_acc_config_default(&ac);
    ac.id = pjdup(id); ac.reg_uri = pjdup(reg);
    ac.proxy_cnt = 1; ac.proxy[0] = pjdup(route);
    ac.reg_timeout = expires < 60 ? 60 : expires; ac.reg_retry_interval = 30; ac.mwi_enabled = mwi; ac.rtp_cfg.port = 0;
    ac.cred_count = 1; ac.cred_info[0].realm = pj_str("*"); ac.cred_info[0].scheme = pj_str("digest");
    ac.cred_info[0].username = pjdup(user); ac.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD; ac.cred_info[0].data = pjdup(pass);
    if (srtp == 0 || srtp == 3) ac.use_srtp = PJMEDIA_SRTP_DISABLED;          /* ZRTP keys the media itself (native/zrtp), PJSIP's SRTP stays off */
    else { ac.use_srtp = mandatory ? PJMEDIA_SRTP_MANDATORY : PJMEDIA_SRTP_OPTIONAL; ac.srtp_secure_signaling = srtp == 1 ? (secureSig ? 1 : 0) : 0;
           ac.srtp_opt.keying_count = 1; ac.srtp_opt.keying[0] = srtp == 1 ? PJMEDIA_SRTP_KEYING_SDES : PJMEDIA_SRTP_KEYING_DTLS_SRTP; }
    ac.ipv6_sip_use = ac.ipv6_media_use = ipv6 ? PJSUA_IPV6_ENABLED_PREFER_IPV4 : PJSUA_IPV6_DISABLED;
    const char *stun = (*env)->GetStringUTFChars(env, jstun, NULL), *tu = (*env)->GetStringUTFChars(env, jtuser, NULL), *tp = (*env)->GetStringUTFChars(env, jtpass, NULL);
    pjsua_media_config mc; pjsua_media_config_default(&mc);
    if (stun[0] && (ice || turn)) { pj_str_t srv = pjdup(stun); pjsua_update_stun_servers(1, &srv, PJ_FALSE); }
    else { ac.media_stun_use = PJSUA_STUN_USE_DISABLED; }      /* pjsua's STUN list is global: an account without STUN must not put another account's server's addresses in its calls */
    if (ice) { ac.ice_cfg_use = PJSUA_ICE_CONFIG_USE_CUSTOM; pjsua_ice_config_from_media_config(g_pool, &ac.ice_cfg, &mc); ac.ice_cfg.enable_ice = PJ_TRUE; }
    if (turn && stun[0]) {
        ac.turn_cfg_use = PJSUA_TURN_CONFIG_USE_CUSTOM; pjsua_turn_config_from_media_config(g_pool, &ac.turn_cfg, &mc);
        ac.turn_cfg.enable_turn = PJ_TRUE; ac.turn_cfg.turn_server = pjdup(stun);
        ac.turn_cfg.turn_auth_cred.type = PJ_STUN_AUTH_CRED_STATIC; ac.turn_cfg.turn_auth_cred.data.static_cred.realm = pj_str("*");
        ac.turn_cfg.turn_auth_cred.data.static_cred.username = pjdup(tu); ac.turn_cfg.turn_auth_cred.data.static_cred.data_type = PJ_STUN_PASSWD_PLAIN;
        ac.turn_cfg.turn_auth_cred.data.static_cred.data = pjdup(tp);
    }
    (*env)->ReleaseStringUTFChars(env, jstun, stun); (*env)->ReleaseStringUTFChars(env, jtuser, tu); (*env)->ReleaseStringUTFChars(env, jtpass, tp);
    pjsua_acc_id out = -1;
    // PJSIP aborts the whole app if its account table (PJSUA_MAX_ACC) is full; report an error instead
    pj_status_t st = pjsua_acc_get_count() >= PJSUA_MAX_ACC ? PJ_ETOOMANY : pjsua_acc_add(&ac, PJ_TRUE, &out);
    (*env)->ReleaseStringUTFChars(env, jid, id); (*env)->ReleaseStringUTFChars(env, jreg, reg); (*env)->ReleaseStringUTFChars(env, jroute, route);
    (*env)->ReleaseStringUTFChars(env, juser, user); (*env)->ReleaseStringUTFChars(env, jpass, pass);
    if (st == PJ_SUCCESS) l1ne_zrtp_set_account_mode(out, srtp == 3 ? (mandatory ? 2 : 1) : 0);
    return st == PJ_SUCCESS ? out : -st;
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nDelAccount(JNIEnv *e, jclass c, jint acc) { (void)e; (void)c; reg_thread(); pjsua_acc_del(acc); }

JNIEXPORT jint JNICALL Java_com_livenet_l1ne_sip_Native_nCall(JNIEnv *env, jclass c, jint acc, jstring juri) {
    (void)c; reg_thread(); const char *u = (*env)->GetStringUTFChars(env, juri, NULL); pj_str_t uri = pj_str((char *)u);
    pjsua_call_setting cs; pjsua_call_setting_default(&cs); cs.txt_cnt = 0; pjsua_call_id id = -1;          /* audio only: no real-time-text stream in the offer (PJSIP defaults to one) */
    pj_status_t st = pjsua_call_make_call(acc, &uri, &cs, NULL, NULL, &id);
    (*env)->ReleaseStringUTFChars(env, juri, u); return st == PJ_SUCCESS ? id : -1;
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nAnswer(JNIEnv *e, jclass c, jint call, jint code) { (void)e; (void)c; reg_thread(); pjsua_call_answer(call, code, NULL, NULL); }
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nHangup(JNIEnv *e, jclass c, jint call) { (void)e; (void)c; reg_thread(); pjsua_call_hangup(call, 0, NULL, NULL); }
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nHangupAll(JNIEnv *e, jclass c) { (void)e; (void)c; reg_thread(); pjsua_call_hangup_all(); }
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nDtmf(JNIEnv *env, jclass c, jint call, jstring d) {
    (void)c; reg_thread(); const char *s = (*env)->GetStringUTFChars(env, d, NULL); pj_str_t p = pj_str((char *)s); pjsua_call_dial_dtmf(call, &p); (*env)->ReleaseStringUTFChars(env, d, s);
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nMute(JNIEnv *e, jclass c, jint call, jboolean on) {
    (void)e; (void)c; reg_thread(); pjsua_call_info ci; if (pjsua_call_get_info(call, &ci) != 0 || ci.conf_slot < 0) return;
    if (call >= 0 && call < PJSUA_MAX_CALLS) g_muted[call] = on;
    if (on) pjsua_conf_disconnect(0, ci.conf_slot); else pjsua_conf_connect(0, ci.conf_slot);
}
JNIEXPORT jboolean JNICALL Java_com_livenet_l1ne_sip_Native_nHold(JNIEnv *e, jclass c, jint call, jboolean on) {
    (void)e; (void)c; reg_thread(); return (on ? pjsua_call_set_hold(call, NULL) : pjsua_call_reinvite(call, PJSUA_CALL_UNHOLD, NULL)) == PJ_SUCCESS;
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nIpChange(JNIEnv *e, jclass c) { (void)e; (void)c; reg_thread(); pjsua_ip_change_param p; pjsua_ip_change_param_default(&p); pjsua_handle_ip_change(&p); }
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nSound(JNIEnv *e, jclass c, jboolean on) {
    (void)e; (void)c; reg_thread(); if (on) pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV); else pjsua_set_no_snd_dev();
}
JNIEXPORT jint JNICALL Java_com_livenet_l1ne_sip_Native_nSendText(JNIEnv *env, jclass c, jint acc, jstring jto, jstring jtext, jint tag) {
    (void)c; reg_thread(); const char *t = (*env)->GetStringUTFChars(env, jto, NULL), *x = (*env)->GetStringUTFChars(env, jtext, NULL);
    pj_str_t to = pj_str((char *)t), mime = pj_str("text/plain"), body = pj_str((char *)x);
    pj_status_t st = pjsua_im_send(acc, &to, &mime, &body, NULL, (void *)(intptr_t)tag);
    (*env)->ReleaseStringUTFChars(env, jto, t); (*env)->ReleaseStringUTFChars(env, jtext, x); return st;
}
JNIEXPORT jstring JNICALL Java_com_livenet_l1ne_sip_Native_nVersion(JNIEnv *env, jclass c) { (void)c; return (*env)->NewStringUTF(env, pj_get_version()); }

/* codecs: "id|priority\n" lines */
JNIEXPORT jstring JNICALL Java_com_livenet_l1ne_sip_Native_nCodecs(JNIEnv *env, jclass c) {
    (void)c; reg_thread(); pjsua_codec_info ci[32]; unsigned n = 32; static char out[2048]; out[0] = 0;
    if (pjsua_enum_codecs(ci, &n) != PJ_SUCCESS) return (*env)->NewStringUTF(env, "");
    for (unsigned i = 0; i < n; i++) { char id[64]; cstr(ci[i].codec_id, id, sizeof id); size_t l = strlen(out); snprintf(out + l, sizeof out - l, "%s|%d\n", id, (int)ci[i].priority); }
    return (*env)->NewStringUTF(env, out);
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nSetCodec(JNIEnv *env, jclass c, jstring jid, jint prio) {
    (void)c; reg_thread(); const char *s = (*env)->GetStringUTFChars(env, jid, NULL); pj_str_t id = pj_str((char *)s); pjsua_codec_set_priority(&id, (pj_uint8_t)prio); (*env)->ReleaseStringUTFChars(env, jid, s);
}
static pjsua_recorder_id g_rec[PJSUA_MAX_CALLS + 4];
JNIEXPORT jboolean JNICALL Java_com_livenet_l1ne_sip_Native_nRecord(JNIEnv *env, jclass c, jint call, jstring jpath, jboolean on) {
    (void)c; reg_thread(); int k = call % (PJSUA_MAX_CALLS + 4);
    if (!on) { if (g_rec[k] > 0) { pjsua_recorder_destroy(g_rec[k] - 1); g_rec[k] = 0; } return JNI_TRUE; }
    pjsua_call_info ci; if (pjsua_call_get_info(call, &ci) != 0 || ci.conf_slot < 0) return JNI_FALSE;
    const char *p = (*env)->GetStringUTFChars(env, jpath, NULL); pj_str_t f = pj_str((char *)p); pjsua_recorder_id r = -1;
    pj_status_t st = pjsua_recorder_create(&f, 0, NULL, 0, 0, &r); (*env)->ReleaseStringUTFChars(env, jpath, p);
    if (st != PJ_SUCCESS) return JNI_FALSE;
    int port = pjsua_recorder_get_conf_port(r);
    pjsua_conf_connect(ci.conf_slot, port); pjsua_conf_connect(0, port); g_rec[k] = r + 1;
    return JNI_TRUE;
}
/* Attended transfer: tells the person on hold (call) to replace our call to the new person (dest) with their own. */
JNIEXPORT jboolean JNICALL Java_com_livenet_l1ne_sip_Native_nXferReplaces(JNIEnv *env, jclass c, jint call, jint dest) {
    (void)env; (void)c; reg_thread(); return pjsua_call_xfer_replaces(call, dest, 0, NULL) == PJ_SUCCESS;
}
JNIEXPORT jboolean JNICALL Java_com_livenet_l1ne_sip_Native_nXfer(JNIEnv *env, jclass c, jint call, jstring jdest) {
    (void)c; reg_thread(); const char *d = (*env)->GetStringUTFChars(env, jdest, NULL); pj_str_t dest = pj_str((char *)d);
    pj_status_t st = pjsua_call_xfer(call, &dest, NULL); (*env)->ReleaseStringUTFChars(env, jdest, d); return st == PJ_SUCCESS;
}
/* "lossPackets|rxPackets|rttMs|jitterMs|srtp|dtls" */
JNIEXPORT jstring JNICALL Java_com_livenet_l1ne_sip_Native_nStats(JNIEnv *env, jclass cls, jint call) {
    (void)cls; reg_thread(); pjsua_stream_stat st; pjsua_stream_info si; char out[256]; out[0] = 0;
    int srtp = 0, dtls = 0, zrtp = 0; l1ne_zrtp_info zi; if (l1ne_zrtp_call_info(call, &zi) && zi.state == 1) zrtp = 1;
    if (pjsua_call_get_stream_info(call, 0, &si) == PJ_SUCCESS && si.type == PJMEDIA_TYPE_AUDIO) {
        srtp = (si.info.aud.proto & PJMEDIA_TP_PROFILE_SRTP) != 0; dtls = (si.info.aud.proto & PJMEDIA_TP_PROTO_DTLS) != 0; }
    if (pjsua_call_get_stream_stat(call, 0, &st) == PJ_SUCCESS)
        snprintf(out, sizeof out, "%u|%u|%u|%u|%d|%d|%d", st.rtcp.rx.loss, st.rtcp.rx.pkt, (unsigned)(st.rtcp.rtt.last / 1000), (unsigned)(st.rtcp.rx.jitter.mean / 1000), srtp || zrtp, dtls, zrtp);
    return (*env)->NewStringUTF(env, out);
}
JNIEXPORT void JNICALL Java_com_livenet_l1ne_sip_Native_nEarlyMedia(JNIEnv *e, jclass c, jboolean on) { (void)e; (void)c; g_accept_early = on; }
