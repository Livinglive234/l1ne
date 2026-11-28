package com.livenet.l1ne

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.runtime.getValue
import com.livenet.l1ne.ui.L1neApp
import com.livenet.l1ne.ui.L1neTheme

class MainActivity : ComponentActivity() {
    private fun handle(intent: android.content.Intent?) {
        val u = intent?.data ?: return
        val app = application as L1neApplication
        if (u.scheme.equals("sip", true) || u.scheme.equals("sips", true)) app.pendingDial.value = app.dialTarget(u)
        else app.pendingSetup.value = u.toString()
    }
    override fun onStop() { super.onStop(); com.livenet.l1ne.data.flushStoreWrites() }          // whatever was changed is on disk before L1ne can be closed in the background
    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)          // not again after a rotation
        val app = application as L1neApplication
        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO, android.Manifest.permission.POST_NOTIFICATIONS), 1)
        // tests/mock/run-ui-goclear.sh, debuggable builds only: one live account on the mock PBX (this computer, as the emulator sees it), ZRTP with the switch to unencrypted allowed, and a call to 1001
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0 && intent.getStringExtra("l1ne_seed") == "mock-zrtp") {
            val m = com.livenet.l1ne.core.Account(label = "Mock PBX", domain = "10.0.2.2", username = "7100", media = com.livenet.l1ne.core.Media.ZRTP, mediaMandatory = false, zrtpAllowClear = true)
                .withTransport(com.livenet.l1ne.core.Transport.TCP)
            app.store.accounts.value.filter { it.label == "Mock PBX" }.forEach { app.store.remove(it.id) }
            app.store.save(m, "secret")
            app.engine.start(); app.engine.registerMissing()
            window.decorView.postDelayed({ app.engine.call("1001", m) }, 3000)
        }
        app.engine.start(); app.engine.registerMissing()
        if (app.settings.keepAlive && app.store.accounts.value.isNotEmpty()) com.livenet.l1ne.sip.KeepAliveService.start(this)
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.RESUMED) {           // directory syncs run while L1ne is open
            app.dirSync.syncDue(onOpen = true); while (true) { delay(60_000); app.dirSync.syncDue() } } }
        // L1ne may be shown over the lock screen (and wake it) only while a call is live. Otherwise a call that was declined, or one that
        // ended, would leave the whole app open on the lock screen for anyone.
        fun overLockScreen(on: Boolean) {
            if (android.os.Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(on); setTurnScreenOn(on) }
            else @Suppress("DEPRECATION") window.run { val f = android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON; if (on) addFlags(f) else clearFlags(f) }
        }
        overLockScreen(app.engine.calls.value.isNotEmpty())
        lifecycleScope.launch { app.engine.calls.collect { overLockScreen(it.isNotEmpty()) } }
        // The call screen is the last thing drawn when a call ends; ask for a fresh frame so it can't linger on screen.
        lifecycleScope.launch { app.engine.calls.collect { if (it.isEmpty()) { window.decorView.invalidate(); window.decorView.postInvalidateOnAnimation(); delay(150); window.decorView.invalidate() } } }
        setContent {
            val look by app.settings.appearanceF.collectAsState()
            L1neTheme(look) { androidx.compose.runtime.CompositionLocalProvider(com.livenet.l1ne.ui.LocalApp provides app, com.livenet.l1ne.ui.LocalTabletopHinge provides com.livenet.l1ne.ui.rememberTabletopHinge(this@MainActivity)) { L1neApp() } }
        }
    }
}
