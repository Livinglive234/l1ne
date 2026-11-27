package com.livenet.l1ne.sip

/** The JNI surface of libl1nesip (app/src/main/cpp/l1ne_sip.c). Events come back through [onEvent] on a PJSIP thread. */
object Native {
    init { System.loadLibrary("l1nesip") }

    var listener: ((type: String, a: Int, b: Int, s1: String, s2: String) -> Unit)? = null

    @JvmStatic fun onEvent(type: String, a: Int, b: Int, s1: String, s2: String) {
        if (type == "log") { com.livenet.l1ne.core.SipLog.add(s1); return }          // the in-app SIP log (Settings, Help)
        listener?.invoke(type, a, b, s1, s2)
    }

    @JvmStatic external fun nInit(caFile: String?, ipv6: Boolean): Int
    @JvmStatic external fun nAddAccount(id: String, reg: String, route: String, user: String, pass: String, srtp: Int, mandatory: Boolean,
                                        secureSig: Boolean, expires: Int, mwi: Boolean, ipv6: Boolean,
                                        stun: String, ice: Boolean, turn: Boolean, turnUser: String, turnPass: String): Int
    @JvmStatic external fun nDelAccount(acc: Int)
    @JvmStatic external fun nCall(acc: Int, uri: String): Int
    @JvmStatic external fun nAnswer(call: Int, code: Int)
    @JvmStatic external fun nHangup(call: Int)
    @JvmStatic external fun nHangupAll()
    @JvmStatic external fun nDtmf(call: Int, digits: String)
    @JvmStatic external fun nMute(call: Int, on: Boolean)
    @JvmStatic external fun nHold(call: Int, on: Boolean): Boolean
    @JvmStatic external fun nIpChange()
    @JvmStatic external fun nSound(on: Boolean)
    @JvmStatic external fun nSendText(acc: Int, to: String, text: String, tag: Int): Int
    @JvmStatic external fun nVersion(): String
    @JvmStatic external fun nEarlyMedia(on: Boolean)
    @JvmStatic external fun nCodecs(): String
    @JvmStatic external fun nSetCodec(id: String, priority: Int)
    @JvmStatic external fun nRecord(call: Int, path: String, on: Boolean): Boolean
    @JvmStatic external fun nXfer(call: Int, dest: String): Boolean
    @JvmStatic external fun nStats(call: Int): String
}
