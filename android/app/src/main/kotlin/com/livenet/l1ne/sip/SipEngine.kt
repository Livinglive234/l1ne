package com.livenet.l1ne.sip

import android.content.Context
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
    /** "sip:7001@host" or "\"Name\" <sip:7001@host>" -> the user part */
    /** user@domain of the other side, for the call log */
    val peerAddress: String get() = Regex("sip:([^>;]+)").find(remote)?.groupValues?.get(1) ?: remote
    val number: String get() = Regex("sip:([^@>;]+)").find(remote)?.groupValues?.get(1) ?: remote
}

/** pjsua behind the JNI bridge: accounts, registration state and calls. The Kotlin twin of SIPEngine.swift. */
class SipEngine(private val app: Context, private val store: AccountStore, val settings: com.livenet.l1ne.data.AppSettings) {
    private val main = Handler(Looper.getMainLooper())
    private val audio = app.getSystemService(AudioManager::class.java)
    private var started = false
    private val pjAcc = HashMap<String, Int>()           // account id -> pj acc id
    private val accOfPJ = HashMap<Int, String>()

    private val _registration = MutableStateFlow<Map<String, String>>(emptyMap())
    val registration: StateFlow<Map<String, String>> = _registration
    private val _calls = MutableStateFlow<List<CallInfo>>(emptyList())
    val calls: StateFlow<List<CallInfo>> = _calls
    private val _mwi = MutableStateFlow<Map<String, Int>>(emptyMap())
    val voicemail: StateFlow<Map<String, Int>> = _mwi
    val muted = MutableStateFlow(setOf<Int>())
    val held = MutableStateFlow(setOf<Int>())
    var onNewVoicemail: ((String, Int) -> Unit)? = null
    fun callVoicemail(accountID: String) { val a = store.accounts.value.firstOrNull { it.id == accountID } ?: return; a.voicemailTarget?.let { callUri(it, a) } }
    var onCallEnded: ((CallInfo) -> Unit)? = null
    var telecom: CallTelecom? = null
    private val telecomKnown = HashSet<Int>()
    fun displayName(id: Int): String { val c = _calls.value.firstOrNull { it.id == id } ?: return "Call"; return contactName(c) }
    var contactResolver: ((String, String) -> String?)? = null
    private fun contactName(c: CallInfo) = contactResolver?.invoke(c.number, c.peerAddress.substringAfter('@', "")) ?: c.number
    var callLog: com.livenet.l1ne.data.CallLogStore? = null
    var messages: com.livenet.l1ne.data.MessageStore? = null
    private val userEnded = HashSet<Int>()
    private val sendTags = HashMap<Int, String>()          // tag -> message id
    private var nextTag = 1
    val currentCall: CallInfo? get() = _calls.value.firstOrNull { it.id == currentId.value } ?: _calls.value.firstOrNull { it.active } ?: _calls.value.firstOrNull()

    fun start() {
        if (started) return
        val ca = File(app.filesDir, "cacert.pem").also { f -> app.assets.open("cacert.pem").use { i -> f.outputStream().use { o -> i.copyTo(o) } } }
        Native.listener = { t, a, b, s1, s2 -> main.post { event(t, a, b, s1, s2) } }
        started = Native.nInit(ca.absolutePath, settings.allowIPv6) == 0
        if (started) { applyCodecs(); Native.nEarlyMedia(settings.acceptEarlyMedia) }
        watchNetwork(); main.postDelayed(statsLoop, 2000)
    }

    private fun event(type: String, a: Int, b: Int, s1: String, s2: String) {
        when (type) {
            "reg" -> accOfPJ[a]?.let { id -> _registration.value = _registration.value + (id to regText(b, s1)) }
            "message" -> incomingText(a, s1, s2)
            "sent" -> sendTags.remove(a)?.let { id -> messages?.update(id, if (b in 200..299) com.livenet.l1ne.data.MsgStatus.SENT else com.livenet.l1ne.data.MsgStatus.FAILED, if (b in 200..299) null else "$b $s1") }
            "mwi" -> accOfPJ[a]?.let { id -> val was = _mwi.value[id] ?: 0; _mwi.value = _mwi.value + (id to b); if (b > was) onNewVoicemail?.invoke(id, b) }
            "incoming", "call" -> {
                val f = s2.split("|")
                val ci = CallInfo(a, s1, f.getOrNull(0) == "1", b, f.getOrNull(1)?.toIntOrNull() ?: 0, f.getOrNull(2) ?: "", f.getOrNull(3)?.toLongOrNull() ?: 0,
                    f.getOrNull(5)?.toIntOrNull()?.let { accOfPJ[it] })
                val old = _calls.value.firstOrNull { it.id == a }
                if (telecom != null) {
                    if (a !in telecomKnown && !ci.ended && ci.incoming) { telecomKnown.add(a); telecom!!.reportIncoming(a, contactName(ci), ci.peerAddress) }
                    if (ci.active && old?.active != true) telecom!!.active(a)
                    if (ci.ended && a in telecomKnown) { telecomKnown.remove(a); telecom!!.ended(a, a !in userEnded) }
                }
                if (ci.active && a !in connectedAt) connectedAt[a] = System.currentTimeMillis() - ci.connectedSecs * 1000
                if (ci.ended) connectedAt.remove(a)
                if (type == "incoming") Native.nAnswer(a, if (settings.allowOutgoingEarlyMedia) 183 else 180)
                _calls.value = if (ci.ended) _calls.value.filter { it.id != a } else if (old == null) _calls.value + ci else _calls.value.map { if (it.id == a) ci.copy(accountID = old.accountID) else it }
                if (ci.active && old?.active != true && settings.autoRecord) toggleRecord(a)
                updateAudio()
                if (ci.ended) {
                    muted.value -= a; held.value -= a
                    val mine = old ?: ci; val byYou = a in userEnded; userEnded.remove(a)
                    val dir = when { !mine.incoming -> com.livenet.l1ne.data.Direction.OUTGOING
                        ci.connectedSecs > 0 -> com.livenet.l1ne.data.Direction.INCOMING
                        byYou -> com.livenet.l1ne.data.Direction.INCOMING
                        else -> com.livenet.l1ne.data.Direction.MISSED }
                    callLog?.add(com.livenet.l1ne.data.CallRecord(peer = mine.peerAddress, accountID = ci.accountID ?: mine.accountID, direction = dir, duration = ci.connectedSecs.toInt()))
                    recording.value -= a
                    onCallEnded?.invoke(ci)
                }
            }
        }
    }

    private fun regText(code: Int, text: String) = when {
        code / 100 == 2 -> "Registered"
        code == 0 || code == 100 || code == 408 && text.isEmpty() -> "Registering…"
        else -> "Not registered: $code $text"
    }

    fun register(a: Account) {
        start(); if (!started) return
        unregister(a.id)
        if (!a.enabled) { _registration.value = _registration.value + (a.id to "Off"); return }
        if (settings.wifiOnly && !onWifi()) { _registration.value = _registration.value + (a.id to "Waiting for Wi-Fi"); return }
        val hostPort = "sip:${a.domain}:${a.port};transport=${a.transport.wire}"
        val reg = a.registrarURI.ifEmpty { hostPort }
        var route = a.outboundProxy.ifEmpty { reg }
        if (!route.contains(";lr")) route += ";lr"
        val name = a.displayName.replace("\"", "")
        val id = Native.nAddAccount(if (name.isEmpty()) "sip:${a.username}@${a.domain}" else "\"$name\" <sip:${a.username}@${a.domain}>", reg, route,
            a.authUser.ifEmpty { a.username }, store.secret(a.id),
            when (a.media) { Media.NONE -> 0; Media.SRTP_SDES -> 1; Media.SRTP_DTLS -> 2 }, a.mediaMandatory, a.transport == Transport.TLS,
            maxOf(60, a.expires), a.mwiEnabled, settings.allowIPv6, a.stunServer, a.iceEnabled, a.turnEnabled, a.turnUser, store.turnSecret(a.id))
        if (id < 0) { _registration.value = _registration.value + (a.id to "Could not add account (error ${-id})"); return }
        pjAcc[a.id] = id; accOfPJ[id] = a.id
        _registration.value = _registration.value + (a.id to "Registering…")
    }

    private fun onWifi(): Boolean {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        return cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    fun unregister(id: String) { pjAcc.remove(id)?.let { accOfPJ.remove(it); Native.nDelAccount(it) }; _registration.value = _registration.value - id }

    fun registerAll() = store.accounts.value.forEach { register(it) }

    fun call(number: String, from: Account? = null): Boolean {
        start()
        val a = from ?: store.accounts.value.firstOrNull { _registration.value[it.id] == "Registered" } ?: store.accounts.value.firstOrNull() ?: return false
        val pj = pjAcc[a.id] ?: return false
        val id = Native.nCall(pj, "sip:${a.dial(number)}@${a.domain}")
        if (id < 0) return false
        _calls.value = _calls.value + CallInfo(id, "sip:$number@${a.domain}", false, 1, 0, "Calling", 0, a.id)
        telecomKnown.add(id); telecom?.reportOutgoing(id, number, "$number@${a.domain}"); KeepAliveService.refresh(app)
        updateAudio(); return true
    }

    /** Dials a full sip: address (the voicemail target) */
    fun callUri(uri: String, from: Account): Boolean {
        start(); val pj = pjAcc[from.id] ?: return false
        val id = Native.nCall(pj, uri); if (id < 0) return false
        _calls.value = _calls.value + CallInfo(id, uri, false, 1, 0, "Calling", 0, from.id)
        telecomKnown.add(id); telecom?.reportOutgoing(id, uri.removePrefix("sip:").substringBefore('@'), uri.removePrefix("sip:")); KeepAliveService.refresh(app)
        updateAudio(); return true
    }
    fun answer(id: Int) = Native.nAnswer(id, 200)
    fun hangup(id: Int) { userEnded.add(id); Native.nHangup(id) }
    fun hangupAll() { _calls.value.forEach { userEnded.add(it.id) }; Native.nHangupAll() }
    fun dtmf(id: Int, d: String) = Native.nDtmf(id, d)
    fun toggleMute(id: Int) { val on = id !in muted.value; Native.nMute(id, on); muted.value = if (on) muted.value + id else muted.value - id }
    fun toggleHold(id: Int) { val on = id !in held.value; Native.nHold(id, on); held.value = if (on) held.value + id else held.value - id; telecom?.held(id, on) }

    enum class MessagingCheck { UNKNOWN, CHECKING, WORKING, NOT_DELIVERED }
    val messagingCheck = MutableStateFlow<Map<String, MessagingCheck>>(emptyMap())
    private val probeTokens = HashMap<String, String>()                 // account id -> token
    private fun setCheck(id: String, c: MessagingCheck) { messagingCheck.value = messagingCheck.value + (id to c) }
    /** Sends one hidden test text to the line itself; if the server delivers it back the server routes texts. Manual only: some servers treat a text to an extension as a call. */
    fun checkMessaging(accountID: String) {
        val a = store.accounts.value.firstOrNull { it.id == accountID } ?: return; val pj = pjAcc[accountID] ?: return
        val token = "L1NE-CHECK:" + java.util.UUID.randomUUID(); probeTokens[accountID] = token; setCheck(accountID, MessagingCheck.CHECKING)
        Native.nSendText(pj, "sip:${a.username}@${a.domain}", token, 0)
        main.postDelayed({ if (probeTokens[accountID] == token) { probeTokens.remove(accountID); setCheck(accountID, MessagingCheck.NOT_DELIVERED) } }, 8000)
    }
    data class QualityNumbers(val lossPercent: Double, val jitterMs: Double, val roundTripMs: Double)
    val quality = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val qualityNumbers = MutableStateFlow<Map<Int, QualityNumbers>>(emptyMap())
    enum class Security { UNKNOWN, NONE, SRTP, DTLS }
    val encryption = MutableStateFlow<Map<Int, Security>>(emptyMap())
    private val statsLoop = object : Runnable { override fun run() { updateStats(); main.postDelayed(this, 2000) } }
    private fun updateStats() {
        for (c in _calls.value.filter { it.active }) {
            val f = Native.nStats(c.id).split("|"); if (f.size < 6) continue
            val lost = f[0].toDouble(); val pkts = f[1].toDouble(); val rtt = f[2].toDouble(); val jitter = f[3].toDouble()
            val total = pkts + lost; val loss = if (total > 20) lost * 100 / total else 0.0
            var score = 5     // forgiving on purpose: ordinary internet jitter and a distant server shouldn't cost a call its bars
            if (loss > 3) score--; if (loss > 8) score--; if (loss > 15) score--; if (jitter > 60) score--; if (jitter > 150) score--; if (rtt > 350) score--; if (rtt > 700) score--
            quality.value = quality.value + (c.id to maxOf(1, score)); qualityNumbers.value = qualityNumbers.value + (c.id to QualityNumbers(loss, jitter, rtt))
            val acc = store.accounts.value.firstOrNull { it.id == c.accountID }
            encryption.value = encryption.value + (c.id to if (f[4] == "1") (if (f[5] == "1") Security.DTLS else Security.SRTP) else if (acc?.media == Media.NONE) Security.NONE else Security.UNKNOWN)
        }
    }
    fun switchTo(id: Int) { _calls.value.filter { it.id != id && it.active && it.id !in held.value }.forEach { toggleHold(it.id) }; if (id in held.value) toggleHold(id); currentId.value = id }
    val currentId = MutableStateFlow<Int?>(null)
    private val connectedAt = HashMap<Int, Long>()
    /** Seconds the call has been connected, counted from when it was first seen connected. */
    fun elapsed(id: Int): Long = connectedAt[id]?.let { (System.currentTimeMillis() - it) / 1000 } ?: 0
    val messagingNote = MutableStateFlow<Map<String, String>>(emptyMap())
    val recording = MutableStateFlow(setOf<Int>())
    fun toggleRecord(id: Int) {
        if (id in recording.value) { Native.nRecord(id, "", false); recording.value -= id; return }
        val dir = File(app.filesDir, "recordings").apply { mkdirs() }
        val f = File(dir, "call-${System.currentTimeMillis()}.wav")
        if (Native.nRecord(id, f.absolutePath, true)) recording.value += id
    }
    fun transfer(id: Int, to: String, from: Account?): Boolean {
        val a = from ?: store.accounts.value.firstOrNull() ?: return false
        return Native.nXfer(id, if (to.startsWith("sip:")) to else "sip:${a.dial(to)}@${a.domain}")
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
        probeTokens.entries.firstOrNull { it.value == text }?.let { (id, _) -> probeTokens.remove(id); setCheck(id, MessagingCheck.WORKING); return }
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

    private var audioOn = false
    private fun updateAudio() {
        val need = _calls.value.isNotEmpty()
        if (need == audioOn) return
        audioOn = need
        if (need) { if (telecom?.connections?.isEmpty() != false) audio.mode = AudioManager.MODE_IN_COMMUNICATION; Native.nSound(true) } else { Native.nSound(false); if (telecom?.connections?.isEmpty() != false) { audio.mode = AudioManager.MODE_NORMAL; audio.isSpeakerphoneOn = false }; KeepAliveService.refresh(app) }
    }
    /** Audio output: through Telecom when it owns the call (so Bluetooth and headsets work), else the plain speaker switch. */
    fun setRoute(route: Int) { if (telecom?.connections?.isNotEmpty() == true) telecom!!.setRoute(route) else audio.isSpeakerphoneOn = route == android.telecom.CallAudioState.ROUTE_SPEAKER }
    fun setSpeaker(on: Boolean) = setRoute(if (on) android.telecom.CallAudioState.ROUTE_SPEAKER else android.telecom.CallAudioState.ROUTE_EARPIECE)
    val routes get() = telecom!!.routes
    val speaker get() = telecom?.routes?.value?.speaker ?: audio.isSpeakerphoneOn

    private fun watchNetwork() {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        var first = true
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { if (first) { first = false; return }; main.post { Native.nIpChange() } }
        })
    }
}
