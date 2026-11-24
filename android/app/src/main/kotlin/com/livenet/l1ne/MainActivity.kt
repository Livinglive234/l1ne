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
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val app = application as L1neApplication
        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO, android.Manifest.permission.POST_NOTIFICATIONS), 1)
        app.engine.start(); app.engine.registerAll()
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.RESUMED) {           // directory syncs run while L1ne is open
            app.dirSync.syncDue(onOpen = true); while (true) { delay(60_000); app.dirSync.syncDue() } } }
        setContent {
            val look by app.settings.appearanceF.collectAsState()
            L1neTheme(look) { androidx.compose.runtime.CompositionLocalProvider(com.livenet.l1ne.ui.LocalApp provides app) { L1neApp() } }
        }
    }
}
