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
        if (u.scheme.equals("sip", true) || u.scheme.equals("sips", true)) (application as L1neApplication).let { it.pendingDial.value = it.dialTarget(u) }
    }
    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handle(intent)
        val app = application as L1neApplication
        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO, android.Manifest.permission.POST_NOTIFICATIONS), 1)
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
