package com.livenet.l1ne.sip

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationManagerCompat
import com.livenet.l1ne.L1neApplication

/** Keeps L1ne's process and registrations alive in the background, with a small notification, so calls reach you while the app is closed. */
class KeepAliveService : Service() {
    override fun onBind(i: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as L1neApplication
        app.engine.start(); app.engine.registerMissing()
        val call = app.engine.currentCall
        val n = CallNotifications.service(this, call?.let { app.engine.displayName(it.id) }, call?.id)
        // ServiceCompat, not Service.startForeground(id, n, type): that three-argument form does not exist before Android 10, so on
        // Android 8 and 9 the call threw (and was swallowed), the service never went foreground, and Android killed the app for it.
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or (if (call != null) ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL else 0)
        runCatching { androidx.core.app.ServiceCompat.startForeground(this, NOTE, n, type) }
            .onFailure { runCatching { androidx.core.app.ServiceCompat.startForeground(this, NOTE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) } }
            .onFailure { runCatching { startForeground(NOTE, n) } }
        return START_STICKY
    }
    companion object {
        private const val NOTE = 4002
        fun start(ctx: Context) { runCatching { ctx.startForegroundService(Intent(ctx, KeepAliveService::class.java)) } }
        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, KeepAliveService::class.java)) }
        /** Refresh the notification (a call began or ended). */
        fun refresh(ctx: Context) { start(ctx) }
    }
}
