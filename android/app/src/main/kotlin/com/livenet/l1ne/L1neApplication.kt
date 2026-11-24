package com.livenet.l1ne

import android.app.Application
import com.livenet.l1ne.data.AccountStore
import com.livenet.l1ne.sip.SipEngine

class L1neApplication : Application() {
    lateinit var store: AccountStore
    lateinit var engine: SipEngine
    lateinit var callLog: com.livenet.l1ne.data.CallLogStore
    lateinit var contacts: com.livenet.l1ne.data.ContactsStore
    lateinit var messages: com.livenet.l1ne.data.MessageStore
    lateinit var directories: com.livenet.l1ne.data.DirectoryStore
    lateinit var dirSync: com.livenet.l1ne.data.DirectorySync
    lateinit var telecom: com.livenet.l1ne.sip.CallTelecom
    /** A sip: link opened from another app: the Keypad tab shows it, ready to call. It never dials by itself. */
    val pendingDial = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    /** "sip:7001@pbx.example.com;transport=tls" -> "7001" when that is one of your servers, else "7001@pbx.example.com". */
    fun dialTarget(uri: android.net.Uri): String? {
        var t = uri.toString().replaceFirst(Regex("^sips?:", RegexOption.IGNORE_CASE), "")
        t = runCatching { java.net.URLDecoder.decode(t, "UTF-8") }.getOrDefault(t).substringBefore(';').substringBefore('?').trim()
        if (t.isEmpty()) return null
        val p = t.split('@', limit = 2)
        if (p.size == 2 && store.accounts.value.any { it.domain.equals(p[1].substringBefore(':'), true) }) return p[0]
        return t
    }
    lateinit var settings: com.livenet.l1ne.data.AppSettings
    override fun onCreate() {
        super.onCreate()
        settings = com.livenet.l1ne.data.AppSettings(this); callLog = com.livenet.l1ne.data.CallLogStore(this); contacts = com.livenet.l1ne.data.ContactsStore(this); messages = com.livenet.l1ne.data.MessageStore(this)
        store = AccountStore(this); engine = SipEngine(this, store, settings)
        directories = com.livenet.l1ne.data.DirectoryStore(this, store); dirSync = com.livenet.l1ne.data.DirectorySync(directories, contacts, store)
        telecom = com.livenet.l1ne.sip.CallTelecom(this); telecom.register(); com.livenet.l1ne.sip.CallNotifications.channels(this)
        engine.telecom = telecom; engine.contactResolver = { u, d -> contacts.name(u, d) }
        engine.callLog = callLog; engine.messages = messages
    }
}
