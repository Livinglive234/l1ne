package com.livenet.l1ne.sip

import android.content.Context
import com.livenet.l1ne.core.CallQuality
import com.livenet.l1ne.core.RegistrationText
import com.livenet.l1ne.core.SipAddress
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Media
import com.livenet.l1ne.core.Transport
import com.livenet.l1ne.data.AccountStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

data class CallInfo(val id: Int, val remote: String, val incoming: Boolean, val state: Int, val status: Int, val reason: String,
                    val connectedSecs: Long, val accountID: String?) {
    val active get() = state == 5                     // PJSIP_INV_STATE_CONFIRMED
    val ended get() = state == 6                      // DISCONNECTED
    val ringing get() = state in 1..4 && !active
    /** user@domain of the other side, for the call log */
    val peerAddress: String get() = SipAddress.address(remote)
    /** "sip:7001@host" or "\"Name\" <sip:7001@host>" -> the user part */
    val number: String get() = SipAddress.user(remote)
    /** What the caller sent as their name (the PBX's caller ID, such as "(612) 555-0142"), else the number. */
    val sentName: String get() = com.livenet.l1ne.core.PhoneFormat.pretty(SipAddress.displayName(remote) ?: number)
}

/** pjsua behind the JNI bridge: accounts, registration state and calls. The Kotlin twin of SIPEngine.swift. */
class SipEngine(private val app: Context, private val store: AccountStore, private val settings: com.livenet.l1ne.data.AppSettings) {
    private val main = Handler(Looper.getMainLooper())
    private val audio = app.getSystemService(AudioManager::class.java)
    private var started = false
    private val pjAcc = HashMap<String, Int>()           // account id -> pj acc id
    internal val accOfPJ = HashMap<Int, String>()

    private val _registration = MutableStateFlow<Map<String, String>>(emptyMap())
    val registration: StateFlow<Map<String, String>> = _registration
    private val _calls = MutableStateFlow<List<CallInfo>>(emptyList())
    val calls: StateFlow<List<CallInfo>> = _calls
    private val _mwi = MutableStateFlow<Map<String, Int>>(emptyMap())
    val voicemail: StateFlow<Map<String, Int>> = _mwi
    val muted = MutableStateFlow(setOf<Int>())
    val held = MutableStateFlow(setOf<Int>())
    fun callVoicemail(accountID: String) { val a = store.account(accountID) ?: return; a.voicemailTarget?.let { callUri(it, a) } }
    var telecom: CallTelecom? = null
    private val telecomKnown = HashSet<Int>()
    fun displayName(id: Int): String { val c = _calls.value.firstOrNull { it.id == id } ?: return "Call"; return contactName(c) }
    var contactResolver: ((String, String) -> String?)? = null
    private fun contactName(c: CallInfo) = contactResolver?.invoke(c.number, c.peerAddress.substringAfter('@', "")) ?: c.sentName
    var callLog: com.livenet.l1ne.data.CallLogStore? = null
    var messages: com.livenet.l1ne.data.MessageStore? = null
    private val userEnded = HashSet<Int>()
    // A call still ringing when the network changes is redialled once: the request it was waiting on went out over the old
    // connection, which is gone after the switch, so the PBX's answer could never reach us.
    internal class Redial(val number: String?, val uri: String?, val accountId: String, val attempt: Int)
    internal val outgoingTargets = HashMap<Int, Redial>()
    private val unansweredAtChange = HashSet<Int>()
    @Volatile internal var lastNetworkEvent = 0L
    private val sendTags = HashMap<Int, String>()          // tag -> message id
    private var nextTag = 1
    val currentCall: CallInfo? get() = _calls.value.firstOrNull { it.id == currentId.value } ?: _calls.value.firstOrNull { it.active } ?: _calls.value.firstOrNull()

    fun start() {
        if (started) return
        val ca = File(app.filesDir, "cacert.pem").also { f -> app.assets.open("cacert.pem").use { i -> f.outputStream().use { o -> i.copyTo(o) } } }
        Native.listener = { t, a, b, s1, s2 -> main.post { event(t, a, b, s1, s2) } }
        Native.nZrtpCache(java.io.File(app.filesDir, "zrtp.cache").absolutePath)
        started = Native.nInit(ca.absolutePath, settings.allowIPv6) == 0
        if (started) { applyCodecs(); Native.nEarlyMedia(settings.acceptEarlyMedia) }
        watchNetwork(); main.postDelayed(statsLoop, 2000)
    }

    /** Everything PJSIP tells us arrives here (internal so tests can feed it events without a network). */
    internal fun event(type: String, a: Int, b: Int, s1: String, s2: String) {
        when (type) {
            "reg" -> accOfPJ[a]?.let { id -> setReg(id, RegistrationText.status(b, s1)) }
            "message" -> incomingText(a, s1, s2)
            "xfer" -> transferProgress(a, b, s1, s2 == "1")
            "zrtp" -> zrtpChanged(a, s1)
            "sent" -> sendResult(a, b, s1)
            "mwi" -> accOfPJ[a]?.let { id -> _mwi.value = _mwi.value + (id to b) }
            "incoming", "call" -> {
                val f = s2.split("|")
                val ci = CallInfo(a, s1, f.getOrNull(0) == "1", b, f.getOrNull(1)?.toIntOrNull() ?: 0, f.getOrNull(2) ?: "", f.getOrNull(3)?.toLongOrNull() ?: 0,
                    f.getOrNull(5)?.toIntOrNull()?.let { accOfPJ[it] })
                val old = _calls.value.firstOrNull { it.id == a }
                if (telecom != null) {
                    if (a !in telecomKnown && !ci.ended && ci.incoming) { telecomKnown.add(a); if (!telecom!!.reportIncoming(a, contactName(ci), ci.peerAddress)) telecomKnown.remove(a) }
                    if (ci.active && old?.active != true) telecom!!.active(a)
                    if (ci.ended && a in telecomKnown) { telecomKnown.remove(a); telecom!!.ended(a, a !in userEnded) }
                }
                if (ci.active && a !in connectedAt) connectedAt[a] = System.currentTimeMillis() - ci.connectedSecs * 1000
                if (ci.ended) connectedAt.remove(a)
                if (type == "incoming" && started) Native.nAnswer(a, if (settings.allowOutgoingEarlyMedia) 183 else 180)
                _calls.value = if (ci.ended) _calls.value.filter { it.id != a } else if (old == null) _calls.value + ci else _calls.value.map { if (it.id == a) ci.copy(accountID = old.accountID) else it }
                if (ci.active && old?.active != true && settings.autoRecord) toggleRecord(a)
                if (ci.active && old?.active != true && muteWhenActive.remove(a)) setMuted(a, true)          // auto-answered with the microphone off
                if (type == "incoming" && f.getOrNull(6) == "1") maybeAutoAnswer(a)
                updateAudio(); updateRingback()
                if (ci.ended) {
                    val zrtpEnded = zrtp.value[a]; val encEnded = encryption.value[a]
                    muted.value -= a; held.value -= a; zrtp.value -= a; encryption.value -= a; autoAnswered.value -= a; muteWhenActive.remove(a)          // a finished call leaves nothing behind (call ids are reused, so the next call would start with its label)
                    val mine = old ?: ci; val byYou = a in userEnded; userEnded.remove(a)
                    val dir = when { !mine.incoming -> com.livenet.l1ne.data.Direction.OUTGOING
                        ci.connectedSecs > 0 || byYou -> com.livenet.l1ne.data.Direction.INCOMING
                        else -> com.livenet.l1ne.data.Direction.MISSED }
                    val target = outgoingTargets.remove(a)
                    unansweredAtChange.remove(a)
                    val record = com.livenet.l1ne.data.CallRecord(peer = if (mine.incoming) mine.peerAddress else (store.account(ci.accountID ?: mine.accountID)?.withoutOutboundPrefix(mine.peerAddress) ?: mine.peerAddress), accountID = ci.accountID ?: mine.accountID, direction = dir, duration = ci.connectedSecs.toInt(), callerName = if (mine.incoming) com.livenet.l1ne.core.SipAddress.callerIdName(mine.remote) else "",
                        security = when { ci.connectedSecs == 0L -> ""; encEnded == Security.ZRTP -> if (zrtpEnded?.verified == true) "zrtp-verified" else "zrtp"; encEnded == Security.DTLS -> "dtls"; encEnded == Security.SRTP -> "srtp"; else -> "" })
                    // A call that dies unanswered with a server/transport error right around a network change is redialled once.
                    // Android reports the dead connection and the new network in either order, so wait a moment before deciding.
                    if (!mine.incoming && ci.connectedSecs == 0L && !byYou && target != null && target.attempt == 0 && ci.status >= 500) {
                        val t0 = System.currentTimeMillis()
                        main.postDelayed({ if (lastNetworkEvent >= t0 - 15000) redialLater(target, 0) else callLog?.add(record) }, 2500)
                    } else callLog?.add(record)
                    recording.value -= a; consultEnded(a); setNote(a, null)
                }
            }
        }
    }


    /** [password] lets an account be tried before it is saved; otherwise the saved one is used. */
    fun register(a: Account, password: String? = null) {
        start(); if (!started) return
        unregister(a.id)
        if (!a.enabled) { setReg(a.id, "Off"); return }
        if (settings.wifiOnly && !onWifi()) { setReg(a.id, "Waiting for Wi-Fi"); return }
        val hostPort = "sip:${a.domain}:${a.port};transport=${a.transport.wire}"
        val reg = a.registrarURI.ifEmpty { hostPort }
        var route = a.outboundProxy.ifEmpty { reg }
        if (!route.contains(";lr")) route += ";lr"
        val name = a.displayName.replace("\"", "")
        val id = Native.nAddAccount(if (name.isEmpty()) "sip:${a.username}@${a.domain}" else "\"$name\" <sip:${a.username}@${a.domain}>", reg, route,
            a.authUser.ifEmpty { a.username }, password ?: store.secret(a.id),
            when (a.media) { Media.NONE -> 0; Media.SRTP_SDES -> 1; Media.SRTP_DTLS -> 2; Media.ZRTP -> 3 }, a.mediaMandatory, a.transport == Transport.TLS,
            maxOf(60, a.expires), a.mwiEnabled, settings.allowIPv6, a.stunServer, a.iceEnabled, a.turnEnabled, a.turnUser, store.turnSecret(a.id))
        if (id < 0) { setReg(a.id, "Could not add account (error ${-id})"); return }
        pjAcc[a.id] = id; accOfPJ[id] = a.id
        setReg(a.id, "Registering…")
    }

    /** The network changed. With "Use only Wi-Fi networks" on, accounts sign out when the phone leaves Wi-Fi (they wait for it) and sign in again when it is back;
     *  a call in progress is never cut for that. Otherwise PJSIP just moves to the new network. */
    private fun networkChanged() {
        if (settings.wifiOnly && !onWifi()) {
            if (_calls.value.none { !it.ended }) store.accounts.value.forEach { if (it.enabled) { unregister(it.id); setReg(it.id, "Waiting for Wi-Fi") } }
            return
        }
        if (settings.wifiOnly) registerMissing()
        Native.nIpChange()
    }

    private fun onWifi(): Boolean {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        return cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private fun setReg(id: String, text: String) { _registration.value = _registration.value + (id to text) }
    fun unregister(id: String) { pjAcc.remove(id)?.let { val live = _calls.value.filter { c -> c.accountID == id && !c.active && !c.ended }.map { c -> c.id } /* only calls still setting up are at risk */; accOfPJ.remove(it); deleteWhenIdle(live, it) }; _registration.value = _registration.value - id }

    /** PJSIP can crash if an account is deleted while one of its calls is still setting up its media (ICE). So the calls of that account are hung up
     *  first, and the account is deleted once they are gone (or after about three seconds, whichever comes first). */
    private fun deleteWhenIdle(calls: List<Int>, pj: Int, tries: Int = 0) {
        val live = calls.filter { id -> _calls.value.any { it.id == id && !it.ended } }
        if (live.isNotEmpty() && tries < 20) {
            if (tries == 0) live.forEach { userEnded.add(it); Native.nHangup(it) }
            main.postDelayed({ deleteWhenIdle(live, pj, tries + 1) }, 150); return
        }
        Native.nDelAccount(pj)
    }

    fun registerAll() = store.accounts.value.forEach { register(it) }
    /** Registers the accounts that are not registered with PJSIP yet and leaves the rest alone. Starting the service or the activity must use this,
     *  not registerAll(): that deletes and re-adds every account, which ends any call in progress (and every call start refreshes the service). */
    fun registerMissing() = store.accounts.value.filter { it.enabled && pjAcc[it.id] == null }.forEach { register(it) }

    /** Dials again once the network is back and the account has re-registered; tries for a few seconds, then gives up quietly. */
    private fun redialLater(t: Redial, tries: Int) {
        main.postDelayed({
            val acc = store.account(t.accountId) ?: return@postDelayed
            val ready = _registration.value[acc.id] == "Registered" && pjAcc[acc.id] != null
            val ok = ready && (if (t.uri != null) callUri(t.uri, acc, 1) else call(t.number!!, acc, 1))
            if (!ok && tries < 8) redialLater(t, tries + 1)
        }, if (tries == 0) 1500L else 1000L)
    }

    fun call(number: String, from: Account? = null, attempt: Int = 0): Boolean {
        start()
        val a = from ?: store.accounts.value.firstOrNull { _registration.value[it.id] == "Registered" } ?: store.accounts.value.firstOrNull() ?: return false
        val pj = pjAcc[a.id] ?: return false
        val full = number.contains("@")
        val id = Native.nCall(pj, a.dialUri(number))
        if (id < 0) return false
        return placed(id, if (full) "sip:$number" else "sip:$number@${a.domain}", Redial(number, null, a.id, attempt), a.id, number, "$number@${a.domain}")
    }

    /** Shows a call that was just placed, remembers how to redial it, and tells Telecom and the background service. */
    private fun placed(id: Int, remote: String, redial: Redial, accountID: String, display: String, address: String): Boolean {
        _calls.value = _calls.value + CallInfo(id, remote, false, 1, 0, "Calling", 0, accountID)
        outgoingTargets[id] = redial
        holdOthers(except = id); currentId.value = id                  // a new call puts the active one on hold and is the one shown
        telecomKnown.add(id); if (telecom?.reportOutgoing(id, display, address) != true) telecomKnown.remove(id); KeepAliveService.start(app)
        updateAudio(); return true
    }

    /** Dials a full sip: address (the voicemail target) */
    fun callUri(uri: String, from: Account, attempt: Int = 0): Boolean {
        start(); val pj = pjAcc[from.id] ?: return false
        val id = Native.nCall(pj, uri); if (id < 0) return false
        return placed(id, uri, Redial(null, uri, from.id, attempt), from.id, uri.removePrefix("sip:").substringBefore('@'), uri.removePrefix("sip:"))
    }
    fun answer(id: Int) { if (started) { holdOthers(except = id); currentId.value = id; Native.nAnswer(id, 200) } }
    private fun holdOthers(except: Int) { _calls.value.filter { it.id != except && it.active && it.id !in held.value }.forEach { toggleHold(it.id) } }
    fun hangup(id: Int) { userEnded.add(id); if (started) Native.nHangup(id) }
    fun hangupAll() { _calls.value.forEach { userEnded.add(it.id) }; Native.nHangupAll() }
    fun dtmf(id: Int, d: String) = Native.nDtmf(id, d)
    /** Calls this phone answered by itself (an intercom or page), and whether its microphone was turned on for them. See Account.autoAnswer. */
    val autoAnswered = MutableStateFlow<Map<Int, Boolean>>(emptyMap())
    private val muteWhenActive = HashSet<Int>()

    /** The INVITE asks to be answered automatically. Only when the account allows it for this caller, and never over another call (answering would put it on hold). */
    private fun maybeAutoAnswer(id: Int) {
        val c = _calls.value.firstOrNull { it.id == id && it.incoming } ?: return
        val acc = store.account(c.accountID) ?: return
        if (!acc.mayAutoAnswer(c.number)) { com.livenet.l1ne.core.SipLog.add("[auto-answer] call ${c.number} asks for it, not allowed on ${acc.title}: ringing as usual"); return }
        if (_calls.value.any { it.id != id }) { com.livenet.l1ne.core.SipLog.add("[auto-answer] not while another call is going on: ringing as usual"); return }
        com.livenet.l1ne.core.SipLog.add("[auto-answer] answering ${c.number} on ${acc.title}, microphone ${if (acc.autoAnswerMic) "on" else "off"}")
        main.postDelayed({
            if (_calls.value.none { it.id == id && !it.active && !it.ended }) return@postDelayed
            autoAnswered.value = autoAnswered.value + (id to acc.autoAnswerMic)
            if (!acc.autoAnswerMic) muteWhenActive.add(id)
            answer(id); CallNotifications.showAnswered(app, id, contactName(c))
            showNotice("Auto-answered a call from ${contactName(c)}. Your microphone is ${if (acc.autoAnswerMic) "ON: they can hear you" else "off: you can hear them, they cannot hear you"}.")
        }, 400)
    }

    /** The mute button on a headset or the system call UI: make the call match it. */
    fun setMuted(id: Int, on: Boolean) { if ((id in muted.value) != on) toggleMute(id) }
    fun toggleMute(id: Int) { val on = id !in muted.value; Native.nMute(id, on); muted.value = if (on) muted.value + id else muted.value - id }
    private val holdWanted = HashMap<Int, Boolean>()          // what the last tap on hold / resume asked for, until PJSIP has done it
    fun toggleHold(id: Int) = setHold(id, !(holdWanted[id] ?: (id in held.value)))

    /** PJSIP refuses a hold or resume while the previous one is still being negotiated (two quick taps), so this tries again shortly until it goes
     *  through, and [held] only changes once it has. Otherwise the button would say "resumed" with the call still on hold. */
    private fun setHold(id: Int, on: Boolean, attempt: Int = 0) {
        holdWanted[id] = on
        if (_calls.value.none { it.id == id }) { holdWanted.remove(id); return }
        if (Native.nHold(id, on)) {
            held.value = if (on) held.value + id else held.value - id; telecom?.held(id, on); holdWanted.remove(id)
        } else if (attempt < 20) {
            main.postDelayed({ if (holdWanted[id] == on) setHold(id, on, attempt + 1) }, 250)          // tapped again meanwhile: that tap decides
        } else holdWanted.remove(id)
    }

    /** Accounts whose server answered a text with "not supported" (405/501/415). Remembered across launches, and cleared as soon as a text goes through. */
    private val msgPrefs get() = app.getSharedPreferences("messaging", Context.MODE_PRIVATE)
    val messagingNote = MutableStateFlow<Map<String, String>>(runCatching { msgPrefs.all.mapValues { it.value.toString() } }.getOrDefault(emptyMap()))
    private fun setMessagingNote(id: String, note: String?) {
        messagingNote.value = if (note == null) messagingNote.value - id else messagingNote.value + (id to note)
        runCatching { msgPrefs.edit().apply { if (note == null) remove(id) else putString(id, note) }.apply() }
    }
    private fun unsupportedNote(code: Int) = "This server doesn't support text messages ($code)."
    private val probeTags = HashMap<Int, String>()                      // pjsua send tag -> account, for the test text

    private fun sendResult(tag: Int, code: Int, reason: String) {
        probeTags.remove(tag)?.let { account ->                          // the hidden test text
            when (code) {
                405, 501, 415 -> { setMessagingNote(account, unsupportedNote(code)); setCheck(account, MessagingCheck.UNKNOWN); probeTokens.remove(account) }
                in 200..299 -> {}                                        // accepted: now wait to see whether it comes back
                else -> { probeTokens.remove(account); setCheck(account, MessagingCheck.NOT_DELIVERED) }      // refused (404, 403, ...): not routed
            }
            return
        }
        val id = sendTags.remove(tag) ?: return
        val target = messages?.accountAndPeer(id)
        if (code in 200..299) { messages?.update(id, com.livenet.l1ne.data.MsgStatus.SENT, null); target?.let { setMessagingNote(it.first, null) }; return }
        val note = when (code) {
            405, 501, 415 -> unsupportedNote(code).also { n -> target?.let { setMessagingNote(it.first, n) } }
            404, 480, 408, 503, 604 -> "Not delivered: they aren't reachable right now ($code)."
            else -> "Not delivered ($code $reason)."
        }
        messages?.update(id, com.livenet.l1ne.data.MsgStatus.FAILED, note)
    }

    enum class MessagingCheck { UNKNOWN, CHECKING, WORKING, NOT_DELIVERED }
    val messagingCheck = MutableStateFlow<Map<String, MessagingCheck>>(emptyMap())
    private val probeTokens = HashMap<String, String>()                 // account id -> token
    private fun setCheck(id: String, c: MessagingCheck) { messagingCheck.value = messagingCheck.value + (id to c) }
    /** Sends one hidden test text to the line itself; if the server delivers it back the server routes texts. Manual only: some servers treat a text to an extension as a call. */
    fun checkMessaging(accountID: String) {
        val a = store.account(accountID) ?: return; val pj = pjAcc[accountID] ?: return
        val token = "L1NE-CHECK:" + java.util.UUID.randomUUID(); probeTokens[accountID] = token; setCheck(accountID, MessagingCheck.CHECKING)
        setMessagingNote(accountID, null)
        val tag = nextTag++; probeTags[tag] = accountID
        if (Native.nSendText(pj, "sip:${a.username}@${a.domain}", token, tag) != 0) { probeTags.remove(tag); probeTokens.remove(accountID); setCheck(accountID, MessagingCheck.UNKNOWN); return }
        main.postDelayed({ if (probeTokens[accountID] == token) { probeTokens.remove(accountID); setCheck(accountID, MessagingCheck.NOT_DELIVERED) } }, 8000)
    }
    data class QualityNumbers(val lossPercent: Double, val jitterMs: Double, val roundTripMs: Double)
    val quality = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val qualityNumbers = MutableStateFlow<Map<Int, QualityNumbers>>(emptyMap())
    enum class Security { UNKNOWN, NONE, SRTP, DTLS, ZRTP }

    /** ZRTP of a call: state 0 negotiating, 1 secure, 2 failed; the code to read out loud; whether it differs from earlier calls with this person. */
    data class ZrtpState(val state: Int, val code: String, val cacheMismatch: Boolean, val knownBefore: Boolean, val verified: Boolean)
    val zrtp = MutableStateFlow<Map<Int, ZrtpState>>(emptyMap())
    /** A one-off message to show over whatever screen is up (a call that ended, and why). Clears itself. */
    val notice = MutableStateFlow<String?>(null)
    fun showNotice(text: String) { notice.value = text; main.postDelayed({ if (notice.value == text) notice.value = null }, 9000) }
    private fun zrtpChanged(call: Int, packed: String) {
        val f = packed.split("|"); if (f.size < 6) return
        val z = ZrtpState(f[0].toIntOrNull() ?: 0, f[1], f[2] == "1", f[3] == "1", f[4] == "1")
        zrtp.value = zrtp.value + (call to z)
        val acc = store.account(_calls.value.firstOrNull { it.id == call }?.accountID)
        if (z.state == 2 && acc?.media == Media.ZRTP && acc.mediaMandatory) { showNotice("The call was ended: the other side doesn't support ZRTP, and this account requires it."); hangup(call) }          // required, and the other side has no ZRTP (or it was refused): nothing was sent in the clear
    }
    /** The user compared the code with the other person: it matched (true), or it did not (false: this person's saved secret is dropped). */
    fun zrtpVerified(call: Int, matched: Boolean) { Native.nZrtpVerified(call, matched); zrtp.value[call]?.let { zrtp.value = zrtp.value + (call to it.copy(verified = matched, cacheMismatch = false)) } }
    val encryption = MutableStateFlow<Map<Int, Security>>(emptyMap())
    private val statsLoop = object : Runnable { override fun run() { updateStats(); main.postDelayed(this, 2000) } }
    private fun updateStats() {
        for (c in _calls.value.filter { it.active }) {
            val f = Native.nStats(c.id).split("|"); if (f.size < 6) continue
            val lost = f[0].toDouble(); val pkts = f[1].toDouble(); val rtt = f[2].toDouble(); val jitter = f[3].toDouble()
            val loss = CallQuality.lossPercent(lost, pkts)
            quality.value = quality.value + (c.id to CallQuality.bars(loss, jitter, rtt)); qualityNumbers.value = qualityNumbers.value + (c.id to QualityNumbers(loss, jitter, rtt))
            val acc = store.account(c.accountID)
            encryption.value = encryption.value + (c.id to if (f.getOrNull(6) == "1") Security.ZRTP else if (f[4] == "1") (if (f[5] == "1") Security.DTLS else Security.SRTP) else if (acc?.media == Media.NONE || (acc?.media == Media.ZRTP && zrtp.value[c.id]?.state == 2)) Security.NONE else Security.UNKNOWN)
        }
    }
    fun switchTo(id: Int) { _calls.value.filter { it.id != id && it.active && it.id !in held.value }.forEach { toggleHold(it.id) }; if (id in held.value) toggleHold(id); currentId.value = id }
    val currentId = MutableStateFlow<Int?>(null)
    private val connectedAt = HashMap<Int, Long>()
    /** Seconds the call has been connected, counted from when it was first seen connected. */
    fun elapsed(id: Int): Long = connectedAt[id]?.let { (System.currentTimeMillis() - it) / 1000 } ?: 0
    val recording = MutableStateFlow(setOf<Int>())
    /** What the call screen says about a transfer in progress, or one that failed. */
    val transferNote = MutableStateFlow<Map<Int, String>>(emptyMap())
    private fun setNote(id: Int, text: String?) { transferNote.value = if (text == null) transferNote.value - id else transferNote.value + (id to text) }
    fun toggleRecord(id: Int) {
        if (id in recording.value) { Native.nRecord(id, "", false); recording.value -= id; return }
        val dir = File(app.filesDir, "recordings").apply { mkdirs() }
        val f = File(dir, "call-${System.currentTimeMillis()}.wav")
        if (Native.nRecord(id, f.absolutePath, true)) recording.value += id
    }
    fun transfer(id: Int, to: String, from: Account?): Boolean {
        val a = from ?: store.accounts.value.firstOrNull() ?: return false
        if (!Native.nXfer(id, a.dialUri(to))) return false
        setNote(id, "Transferring to ${(app.applicationContext as com.livenet.l1ne.L1neApplication).contacts.nameOrNumber(to.removePrefix("sip:"))}…")
        return true
    }

    /** Attended transfers: the call placed to ask the new person (key) and the call it was placed from, which is on hold (value). */
    val consults = MutableStateFlow<Map<Int, Int>>(emptyMap())

    /** Starts an attended transfer: puts [original] on hold and calls the new person. Once they answer and agree, [completeTransfer] connects the two. */
    fun startConsult(original: Int, to: String, from: Account?): Boolean {
        val orig = _calls.value.firstOrNull { it.id == original && it.active } ?: return false
        if (!call(to, from ?: store.account(orig.accountID) ?: return false)) return false
        val consult = currentId.value?.takeIf { it != original } ?: return false
        consults.value = consults.value + (consult to original)
        return true
    }

    /** Connects the person on hold to the one you have just asked, and drops out. Needs the consult call to be answered. */
    fun completeTransfer(consult: Int): Boolean {
        val original = consults.value[consult] ?: return false
        if (_calls.value.none { it.id == consult && it.active }) return false
        if (!Native.nXferReplaces(original, consult)) { setNote(consult, "Could not start the transfer"); return false }
        setNote(original, "Transferring…"); setNote(consult, "Transferring…")
        return true
    }

    /** Gives up on an attended transfer: ends the call to the new person and goes back to the one on hold. */
    fun cancelConsult(consult: Int) {
        val original = consults.value[consult] ?: return
        consults.value = consults.value - consult
        hangup(consult); setHold(original, false)
    }

    /** A consult call that ends by itself (nobody answered, busy) puts you back with the person who was on hold, unless the transfer went through. */
    private fun consultEnded(call: Int) {
        consults.value = consults.value.filterValues { it != call }                 // the person on hold hung up: nothing to go back to
        val original = consults.value[call] ?: return
        consults.value = consults.value - call
        if (transferNote.value[call] == "Transferred") return
        setNote(original, "That call ended: you are back with this caller"); setHold(original, false)
        main.postDelayed({ setNote(original, null) }, 6000)
    }

    /** The other side's progress reports for a transfer: 1xx while it works on it, a final 2xx when it has taken over, a final error if it could not. */
    private fun transferProgress(call: Int, code: Int, reason: String, final: Boolean) {
        if (_calls.value.none { it.id == call }) return
        when {
            code in 200..299 -> {
                val consult = consults.value.entries.firstOrNull { it.value == call }?.key
                setNote(call, "Transferred"); hangup(call)                                // the other party is connected to the new person: this leg is done (the PBX usually ends it too)
                if (consult != null) { setNote(consult, "Transferred"); hangup(consult) } // attended: the call to the new person too
            }
            final || code >= 300 -> {
                val consult = consults.value.entries.firstOrNull { it.value == call }?.key
                val failure = "Transfer failed: $code $reason"
                setNote(call, failure); if (consult != null) setNote(consult, failure)
                main.postDelayed({ setNote(call, null); if (consult != null) setNote(consult, null) }, 8000)
            }
            else -> setNote(call, if (reason.isEmpty()) "Transferring…" else "Transferring… $reason")
        }
    }

    /** Sends a text from [account] to user@domain; the result arrives as a "sent" event. */
    fun sendText(account: Account, peer: String, text: String): Boolean {
        val pj = pjAcc[account.id] ?: return false
        val mid = messages?.add(com.livenet.l1ne.data.Message(outgoing = true, text = text, status = com.livenet.l1ne.data.MsgStatus.SENDING), account.id, peer) ?: return false
        val tag = nextTag++; sendTags[tag] = mid
        val st = Native.nSendText(pj, "sip:$peer", text, tag)
        if (st != 0) { sendTags.remove(tag); messages?.update(mid, com.livenet.l1ne.data.MsgStatus.FAILED, "Could not send (error $st)"); return false }
        return true
    }
    private fun incomingText(pjAccId: Int, from: String, text: String) {
        val accId = accOfPJ[pjAccId] ?: return
        probeTokens.entries.firstOrNull { it.value == text }?.let { (id, _) -> probeTokens.remove(id); setCheck(id, MessagingCheck.WORKING); setMessagingNote(id, null); return }
        val peer = Regex("sip:([^>;]+)").find(from)?.groupValues?.get(1)?.lowercase() ?: return
        messages?.add(com.livenet.l1ne.data.Message(outgoing = false, text = text, read = false), accId, peer)
    }

    data class Codec(val id: String, val name: String, val detail: String)
    /** The codecs pjsua has, in the order you chose (new ones at the end). */
    fun availableCodecs(): List<Codec> {
        start()
        val all = Native.nCodecs().lines().filter { it.isNotBlank() }.map { it.substringBefore('|') }.filter { !it.startsWith("AMR") }   // phone-network AMR from Android MediaCodec; a PBX never uses it
        val order = settings.codecOrder
        val sorted = order.filter { it in all } + all.filter { it !in order }
        return sorted.map { id -> val n = id.substringBefore('/'); val rate = id.split('/').getOrNull(1)?.toIntOrNull() ?: 8000
            Codec(id, n, when { rate >= 16000 -> "Wideband · ${rate / 1000} kHz"; else -> "Narrowband · 8 kHz" }) }
    }
    fun applyCodecs() {
        Native.nCodecs().lines().map { it.substringBefore('|') }.filter { it.startsWith("AMR") }.forEach { Native.nSetCodec(it, 0) }
        val list = availableCodecs(); var prio = 250
        for (c in list) { if (c.id in settings.codecsOff) Native.nSetCodec(c.id, 0) else { Native.nSetCodec(c.id, maxOf(1, prio)); prio -= 5 } }
    }

    // The screen turns off (and touches are ignored) when the phone is at your ear, like the Phone app. Only on the earpiece:
    // on speaker, Bluetooth or a headset the screen stays on.
    private var proximity: android.os.PowerManager.WakeLock? = null
    fun updateProximity() {
        val pm = app.getSystemService(android.os.PowerManager::class.java)
        if (!pm.isWakeLockLevelSupported(android.os.PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
        val r = telecom?.routes?.value
        val onEar = _calls.value.any { it.active || (!it.incoming && !it.ended) } &&          /* answered, or a call you placed: not a call that is still ringing for you to answer */ (r == null || r.active == android.telecom.CallAudioState.ROUTE_EARPIECE) && audio.isSpeakerphoneOn.not()
        if (onEar) { if (proximity == null) proximity = pm.newWakeLock(android.os.PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "l1ne:proximity").also { it.setReferenceCounted(false) }; if (proximity?.isHeld != true) proximity?.acquire(4 * 3600 * 1000L) }
        else proximity?.let { if (it.isHeld) it.release() }
    }

    /** The tone you hear while the other phone rings: L1ne's own, unless you let the PBX's early media through instead. */
    private fun updateRingback() {
        if (!started) return
        val early = settings.acceptEarlyMedia
        val tone = _calls.value.any { com.livenet.l1ne.core.RingbackRule.wanted(!it.incoming, it.active, it.state == 1 || it.state == 3, early) }      // 1 = calling, 3 = early (ringing)
        if (tone) Ringback.start(settings.ringback) else Ringback.stop()
    }

    private var audioOn = false
    private fun updateAudio() {
        if (!started) return          // no engine running (tests): nothing to open or route
        updateProximity()
        val need = _calls.value.isNotEmpty()
        if (need == audioOn) return
        audioOn = need
        // When Telecom has the call it owns the audio mode, and only then does Android apply the speaker / earpiece / Bluetooth choice made through it:
        // setting the mode here too (as an app that has no Telecom must) makes this app the owner, and every route change is silently ignored.
        val telecomOwns = telecom?.connections?.isNotEmpty() == true || _calls.value.any { it.id in telecomKnown }
        if (need) { if (!telecomOwns) audio.mode = AudioManager.MODE_IN_COMMUNICATION; Native.nSound(true) } else { Native.nSound(false); if (!telecomOwns) { audio.mode = AudioManager.MODE_NORMAL; audio.isSpeakerphoneOn = false }; KeepAliveService.start(app) }
    }
    /** Audio output: through Telecom when it owns the call (so Bluetooth and headsets work), else the plain speaker switch. */
    fun setRoute(route: Int) { if (telecom?.connections?.isNotEmpty() == true) telecom!!.setRoute(route) else audio.isSpeakerphoneOn = route == android.telecom.CallAudioState.ROUTE_SPEAKER }
    /** Moves the call to one named Bluetooth device. */
    fun setBluetooth(name: String) { telecom?.takeIf { it.connections.isNotEmpty() }?.setRoute(android.telecom.CallAudioState.ROUTE_BLUETOOTH, name) }
    fun setSpeaker(on: Boolean) = setRoute(if (on) android.telecom.CallAudioState.ROUTE_SPEAKER else android.telecom.CallAudioState.ROUTE_EARPIECE)
    val routes get() = telecom!!.routes

    private fun watchNetwork() {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        var first = true
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) { lastNetworkEvent = System.currentTimeMillis() }
            override fun onAvailable(network: Network) { if (first) { first = false; return }; lastNetworkEvent = System.currentTimeMillis(); main.post { unansweredAtChange.addAll(_calls.value.filter { !it.incoming && !it.active && !it.ended }.map { it.id }); networkChanged() } }
        })
    }
}
