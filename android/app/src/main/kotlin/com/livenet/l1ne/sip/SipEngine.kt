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
    val number: String get() = Regex("sip:([^@>;]+)").find(remote)?.groupValues?.get(1) ?: remote
}

/** pjsua behind the JNI bridge: accounts, registration state and calls. The Kotlin twin of SIPEngine.swift. */
class SipEngine(private val app: Context, private val store: AccountStore) {
    private val main = Handler(Looper.getMainLooper())
    private val audio = app.getSystemService(AudioManager::class.java)
    private var started = false
    private val pjAcc = HashMap<String, Int>()           // account id -> pj acc id
    private val accOfPJ = HashMap<Int, String>()

    private val _registration = MutableStateFlow<Map<String, String>>(emptyMap())
    val registration: StateFlow<Map<String, String>> = _registration
    private val _calls = MutableStateFlow<List<CallInfo>>(emptyList())
    val calls: StateFlow<List<CallInfo>> = _calls
    private val _mwi = MutableStateFlow(0)
    val voicemailCount: StateFlow<Int> = _mwi
    val muted = MutableStateFlow(setOf<Int>())
    val held = MutableStateFlow(setOf<Int>())
    var onCallEnded: ((CallInfo) -> Unit)? = null

    fun start() {
        if (started) return
        val ca = File(app.filesDir, "cacert.pem").also { f -> app.assets.open("cacert.pem").use { i -> f.outputStream().use { o -> i.copyTo(o) } } }
        Native.listener = { t, a, b, s1, s2 -> main.post { event(t, a, b, s1, s2) } }
        started = Native.nInit(ca.absolutePath, false) == 0
        watchNetwork()
    }

    private fun event(type: String, a: Int, b: Int, s1: String, s2: String) {
        when (type) {
            "reg" -> accOfPJ[a]?.let { id -> _registration.value = _registration.value + (id to regText(b, s1)) }
            "mwi" -> _mwi.value = b
            "incoming", "call" -> {
                val f = s2.split("|")
                val ci = CallInfo(a, s1, f.getOrNull(0) == "1", b, f.getOrNull(1)?.toIntOrNull() ?: 0, f.getOrNull(2) ?: "", f.getOrNull(3)?.toLongOrNull() ?: 0, null)
                val old = _calls.value.firstOrNull { it.id == a }
                _calls.value = if (ci.ended) _calls.value.filter { it.id != a } else if (old == null) _calls.value + ci else _calls.value.map { if (it.id == a) ci.copy(accountID = old.accountID) else it }
                updateAudio()
                if (ci.ended) { muted.value -= a; held.value -= a; onCallEnded?.invoke(ci) }
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
        val secret = store.secret(a.id)
        val scheme = if (a.transport == Transport.TLS) "sip" else "sip"
        val route = "sip:${a.domain}:${a.port};transport=${a.transport.wire};lr"
        val id = Native.nAddAccount("sip:${a.username}@${a.domain}", "sip:${a.domain}:${a.port};transport=${a.transport.wire}", route,
            a.authUser.ifEmpty { a.username }, secret, if (a.media == Media.NONE) 0 else 1, false, a.transport == Transport.TLS, 300, true, false)
        if (id < 0) { _registration.value = _registration.value + (a.id to "Could not add account (error ${-id})"); return }
        pjAcc[a.id] = id; accOfPJ[id] = a.id
        _registration.value = _registration.value + (a.id to "Registering…")
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
        updateAudio(); return true
    }

    fun answer(id: Int) = Native.nAnswer(id, 200)
    fun hangup(id: Int) = Native.nHangup(id)
    fun dtmf(id: Int, d: String) = Native.nDtmf(id, d)
    fun toggleMute(id: Int) { val on = id !in muted.value; Native.nMute(id, on); muted.value = if (on) muted.value + id else muted.value - id }
    fun toggleHold(id: Int) { val on = id !in held.value; Native.nHold(id, on); held.value = if (on) held.value + id else held.value - id }

    private var audioOn = false
    private fun updateAudio() {
        val need = _calls.value.isNotEmpty()
        if (need == audioOn) return
        audioOn = need
        if (need) { audio.mode = AudioManager.MODE_IN_COMMUNICATION; Native.nSound(true) } else { Native.nSound(false); audio.mode = AudioManager.MODE_NORMAL; audio.isSpeakerphoneOn = false }
    }
    fun setSpeaker(on: Boolean) { audio.isSpeakerphoneOn = on }
    val speaker get() = audio.isSpeakerphoneOn

    private fun watchNetwork() {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        var first = true
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { if (first) { first = false; return }; main.post { Native.nIpChange() } }
        })
    }
}
