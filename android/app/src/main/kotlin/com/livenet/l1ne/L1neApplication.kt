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
    lateinit var settings: com.livenet.l1ne.data.AppSettings
    override fun onCreate() {
        super.onCreate()
        settings = com.livenet.l1ne.data.AppSettings(this); callLog = com.livenet.l1ne.data.CallLogStore(this); contacts = com.livenet.l1ne.data.ContactsStore(this); messages = com.livenet.l1ne.data.MessageStore(this)
        store = AccountStore(this); engine = SipEngine(this, store, settings)
        directories = com.livenet.l1ne.data.DirectoryStore(this, store); dirSync = com.livenet.l1ne.data.DirectorySync(directories, contacts, store)
        engine.callLog = callLog; engine.messages = messages
    }
}
