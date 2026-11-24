package com.livenet.l1ne

import android.app.Application
import com.livenet.l1ne.data.AccountStore
import com.livenet.l1ne.sip.SipEngine

class L1neApplication : Application() {
    lateinit var store: AccountStore
    lateinit var engine: SipEngine
    override fun onCreate() {
        super.onCreate()
        store = AccountStore(this); engine = SipEngine(this, store)
    }
}
