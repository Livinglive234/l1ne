package com.livenet.l1ne.sip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.telecom.*
import androidx.core.app.NotificationManagerCompat
import com.livenet.l1ne.L1neApplication
import com.livenet.l1ne.MainActivity
import com.livenet.l1ne.R
import kotlinx.coroutines.flow.MutableStateFlow

/** What the system tells us about audio routes: which one is active and which exist (speaker, earpiece, Bluetooth, wired headset). */
data class AudioRoutes(val active: Int = CallAudioState.ROUTE_EARPIECE, val supported: Int = CallAudioState.ROUTE_EARPIECE or CallAudioState.ROUTE_SPEAKER) {
    val bluetooth get() = supported and CallAudioState.ROUTE_BLUETOOTH != 0
    val headset get() = supported and CallAudioState.ROUTE_WIRED_HEADSET != 0
    val speaker get() = active == CallAudioState.ROUTE_SPEAKER
}

/**
 * Android's counterpart of CallKit for L1ne: a self-managed phone account. Telecom gives us audio routing (Bluetooth, headsets),
 * priority over other audio, and lets other apps (and the car) know a call is in progress. The incoming-call screen is ours.
 */
class CallTelecom(private val app: Context) {
    private val tm = app.getSystemService(TelecomManager::class.java)
    private val handle = PhoneAccountHandle(ComponentName(app, L1neConnectionService::class.java), "l1ne")
    val connections = HashMap<Int, L1neConnection>()
    val routes = MutableStateFlow(AudioRoutes())

    fun register() {
        runCatching {
            tm.registerPhoneAccount(PhoneAccount.builder(handle, "L1ne").setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .addSupportedUriScheme(PhoneAccount.SCHEME_SIP).addSupportedUriScheme(PhoneAccount.SCHEME_TEL).build())
        }
    }

    /** true when Telecom took the call. */
    fun reportIncoming(callId: Int, display: String, address: String): Boolean =
        runCatching {
            tm.addNewIncomingCall(handle, Bundle().apply {
                putInt(EXTRA_CALL, callId); putString(EXTRA_NAME, display)
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts("sip", address, null)) })
        }.onFailure { android.util.Log.e("L1neTelecom", "addNewIncomingCall failed", it); CallNotifications.showIncoming(app, callId, display) }.isSuccess       // no Telecom? still ring from our own notification

    fun reportOutgoing(callId: Int, display: String, address: String): Boolean =
        runCatching {
            tm.placeCall(Uri.fromParts("sip", address, null), Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, Bundle().apply { putInt(EXTRA_CALL, callId); putString(EXTRA_NAME, display) }) })
        }.isSuccess

    fun active(callId: Int) { connections[callId]?.setActive(); CallNotifications.cancelIncoming(app) }
    fun held(callId: Int, on: Boolean) { connections[callId]?.let { if (on) it.setOnHold() else it.setActive() } }
    fun ended(callId: Int, byRemote: Boolean) {
        connections.remove(callId)?.let { it.setDisconnected(DisconnectCause(if (byRemote) DisconnectCause.REMOTE else DisconnectCause.LOCAL)); it.destroy() }
        CallNotifications.cancelIncoming(app)
    }
    fun setRoute(route: Int) { connections.values.firstOrNull()?.requestRoute(route) ?: com.livenet.l1ne.core.SipLog.add("[audio] route $route requested but there is no Telecom connection") }

    companion object { const val EXTRA_CALL = "l1ne.call"; const val EXTRA_NAME = "l1ne.name" }
}

class L1neConnection(val callId: Int, private val app: L1neApplication) : Connection() {
    init { connectionProperties = PROPERTY_SELF_MANAGED; connectionCapabilities = CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD; audioModeIsVoip = true }
    private val engine get() = app.engine
    override fun onAnswer() { engine.answer(callId); CallNotifications.cancelIncoming(app) }
    override fun onAnswer(videoState: Int) = onAnswer()
    override fun onReject() { engine.hangup(callId); CallNotifications.cancelIncoming(app) }
    override fun onDisconnect() { engine.hangup(callId) }
    override fun onAbort() { engine.hangup(callId) }
    override fun onHold() { if (callId !in engine.held.value) engine.toggleHold(callId) }
    override fun onUnhold() { if (callId in engine.held.value) engine.toggleHold(callId) }
    override fun onPlayDtmfTone(c: Char) { engine.dtmf(callId, c.toString()) }
    override fun onShowIncomingCallUi() {
        CallNotifications.showIncoming(app, callId, app.engine.displayName(callId)) }
    @Deprecated("Telecom still calls this on older Android versions")
    override fun onCallAudioStateChanged(state: CallAudioState?) {
        state?.let { publish(it.route, it.supportedRouteMask, "CallAudioState") }
    }

    // Android 14 and later report the audio routes as "call endpoints" (and the older callback above may not be used there).
    private var endpoints: List<android.telecom.CallEndpoint> = emptyList()
    private var endpoint: android.telecom.CallEndpoint? = null
    @androidx.annotation.RequiresApi(34)
    override fun onAvailableCallEndpointsChanged(available: List<android.telecom.CallEndpoint>) { endpoints = available; publishEndpoints() }
    @androidx.annotation.RequiresApi(34)
    override fun onCallEndpointChanged(e: android.telecom.CallEndpoint) { endpoint = e; publishEndpoints() }

    @androidx.annotation.RequiresApi(34)
    private fun publishEndpoints() {
        val active = endpoint?.let { routeOf(it.endpointType) } ?: return
        publish(active, endpoints.fold(active) { mask, e -> mask or routeOf(e.endpointType) }, "CallEndpoint")
    }
    @androidx.annotation.RequiresApi(34)
    private fun routeOf(type: Int) = when (type) {
        android.telecom.CallEndpoint.TYPE_EARPIECE -> CallAudioState.ROUTE_EARPIECE
        android.telecom.CallEndpoint.TYPE_BLUETOOTH -> CallAudioState.ROUTE_BLUETOOTH
        android.telecom.CallEndpoint.TYPE_WIRED_HEADSET -> CallAudioState.ROUTE_WIRED_HEADSET
        android.telecom.CallEndpoint.TYPE_SPEAKER -> CallAudioState.ROUTE_SPEAKER
        else -> 0
    }

    private fun publish(route: Int, supported: Int, from: String) {
        com.livenet.l1ne.core.SipLog.add("[audio] route is now $route, available $supported ($from)")
        app.telecom.routes.value = AudioRoutes(route, supported); app.engine.updateProximity()
    }

    /** Moves the call's audio (speaker, earpiece, Bluetooth, headset): through the call endpoints on Android 14 and later, the older way before that or when the phone offers no such endpoint. */
    fun requestRoute(route: Int) {
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            val target = endpoints.firstOrNull { routeOf(it.endpointType) == route }
            if (target != null) {
                com.livenet.l1ne.core.SipLog.add("[audio] asking for route $route (${target.endpointName})")
                requestCallEndpointChange(target, app.mainExecutor, object : android.os.OutcomeReceiver<Void, android.telecom.CallEndpointException> {
                    override fun onResult(r: Void?) { com.livenet.l1ne.core.SipLog.add("[audio] route $route accepted") }
                    override fun onError(e: android.telecom.CallEndpointException) { com.livenet.l1ne.core.SipLog.add("[audio] route $route refused: ${e.message} (code ${e.code})") }
                })
                return
            }
        }
        com.livenet.l1ne.core.SipLog.add("[audio] asking for route $route the older way")
        @Suppress("DEPRECATION") setAudioRoute(route)
    }
}

class L1neConnectionService : ConnectionService() {
    private val app get() = application as L1neApplication
    override fun onCreateIncomingConnection(account: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        val id = request?.extras?.getInt(CallTelecom.EXTRA_CALL, -1) ?: -1
        return L1neConnection(id, app).apply { setRinging(); app.telecom.connections[id] = this
            setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED); setCallerDisplayName(request?.extras?.getString(CallTelecom.EXTRA_NAME), TelecomManager.PRESENTATION_ALLOWED) }
    }
    override fun onCreateOutgoingConnection(account: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        val extras = request?.extras?.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS) ?: request?.extras
        val id = extras?.getInt(CallTelecom.EXTRA_CALL, -1) ?: -1
        return L1neConnection(id, app).apply { setDialing(); app.telecom.connections[id] = this; setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
            if (app.engine.calls.value.firstOrNull { it.id == id }?.active == true) setActive() }       // answered before Telecom finished creating this
    }
}

object CallNotifications {
    // The channel itself is silent: L1ne rings and vibrates by itself (see Ringer), the way a phone call does. A channel's settings can't be
    // changed once it exists, so each change of mind gets a new id and the old ones are deleted.
    private const val INCOMING = "l1ne_incoming_v3"; const val SERVICE = "l1ne_service"; private const val ID_INCOMING = 4001

    /** Created once, when the app starts (L1neApplication), before any call or service notification can be shown. */
    fun channels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.deleteNotificationChannel("l1ne_incoming"); nm.deleteNotificationChannel("l1ne_incoming_v2")
        nm.createNotificationChannel(NotificationChannel(INCOMING, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Shows the incoming call (the ringing itself is L1ne's own)"; lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, null); enableVibration(false)
        })
        nm.createNotificationChannel(NotificationChannel(SERVICE, "Connection", NotificationManager.IMPORTANCE_LOW).apply { description = "Keeps L1ne signed in so calls can reach you" })
    }

    private fun action(ctx: Context, what: String, id: Int) =
        PendingIntent.getBroadcast(ctx, id * 10 + what.hashCode().and(7), Intent(ctx, CallActionReceiver::class.java).setAction(what).putExtra("call", id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    fun showIncoming(ctx: Context, callId: Int, name: String) {
        val open = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val person = androidx.core.app.Person.Builder().setName(name).setImportant(true).apply { runCatching { setIcon(callerAvatar(name)) } }.build()
        val n = androidx.core.app.NotificationCompat.Builder(ctx, INCOMING).setSmallIcon(R.drawable.ic_stat_l1ne).setCategory(Notification.CATEGORY_CALL).setOngoing(true)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_MAX).setVisibility(androidx.core.app.NotificationCompat.VISIBILITY_PUBLIC)
            .setTimeoutAfter(60_000).setOnlyAlertOnce(true)
            .setFullScreenIntent(open, true).setContentIntent(open)
            .setStyle(androidx.core.app.NotificationCompat.CallStyle.forIncomingCall(person, action(ctx, "decline", callId), action(ctx, "answer", callId))).build()
        runCatching { NotificationManagerCompat.from(ctx).notify(ID_INCOMING, n) }
        Ringer.start(ctx)
    }
    /** The round picture on the incoming-call banner: the caller's initials, or a plain person for a number, in L1ne's dark green.
     *  Without one, Samsung draws its own default avatar (a purple-blue circle) behind the app badge. */
    private fun callerAvatar(name: String): androidx.core.graphics.drawable.IconCompat {
        val size = 192
        val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(bmp)
        val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        p.color = 0xFF14301F.toInt(); c.drawCircle(size / 2f, size / 2f, size / 2f, p)
        p.color = 0xFFB5DEC0.toInt()
        val letters = name.split(' ').filter { it.isNotEmpty() && it.first().isLetter() }.take(2).map { it.first().uppercaseChar() }.joinToString("")
        if (letters.isNotEmpty()) {
            p.textAlign = android.graphics.Paint.Align.CENTER; p.textSize = size * 0.42f; p.typeface = android.graphics.Typeface.DEFAULT_BOLD
            c.drawText(letters, size / 2f, size / 2f - (p.descent() + p.ascent()) / 2f, p)
        } else {
            c.drawCircle(size / 2f, size * 0.38f, size * 0.16f, p)                                   // head
            c.drawOval(android.graphics.RectF(size * 0.24f, size * 0.60f, size * 0.76f, size * 1.04f), p)   // shoulders, cut off by the circle
        }
        return androidx.core.graphics.drawable.IconCompat.createWithBitmap(bmp)
    }
    fun cancelIncoming(ctx: Context) { Ringer.stop(); NotificationManagerCompat.from(ctx).cancel(ID_INCOMING) }

    /** (androidx's CallStyle, not the framework's: android.app.Notification.CallStyle only exists from Android 12 and crashed every call on older phones.)
     *  The persistent notification of the service: "Connected" while idle, the call and a Hang up button during one. */
    fun service(ctx: Context, callName: String?, callId: Int?): Notification {
        val open = PendingIntent.getActivity(ctx, 1, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = androidx.core.app.NotificationCompat.Builder(ctx, SERVICE).setSmallIcon(R.drawable.ic_stat_l1ne).setContentIntent(open).setOngoing(true)
        return if (callName != null && callId != null)
            b.setStyle(androidx.core.app.NotificationCompat.CallStyle.forOngoingCall(androidx.core.app.Person.Builder().setName(callName).build(), action(ctx, "hangup", callId))).setCategory(Notification.CATEGORY_CALL).build()
        else b.setContentTitle("L1ne").setContentText("Connected — you can receive calls")
            // From Android 14 the user can swipe this notification away (the service keeps running); this puts it straight back, so it stays visible while L1ne is connected.
            .setDeleteIntent(PendingIntent.getForegroundService(ctx, 2, Intent(ctx, KeepAliveService::class.java), PendingIntent.FLAG_IMMUTABLE)).build()
    }
}

/** Answer / decline / hang up from a notification. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, i: Intent) {
        val app = ctx.applicationContext as L1neApplication; val id = i.getIntExtra("call", -1)
        when (i.action) {
            "answer" -> { app.engine.answer(id); ctx.startActivity(Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            "decline", "hangup" -> app.engine.hangup(id)
        }
        CallNotifications.cancelIncoming(ctx)
    }
}

/**
 * Rings and vibrates for an incoming call until it is answered, declined, ends, or a minute has passed. Android doesn't ring a call that an app
 * manages itself, and a notification's own sound was not reliable on every phone, so L1ne plays the phone's ringtone and vibrates itself.
 * It follows the phone's settings: silent mode is silent, vibrate mode only vibrates, the ringer volume applies, and Do Not Disturb
 * that blocks everything (None, Alarms only) keeps it quiet.
 */
object Ringer {
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var player: android.media.MediaPlayer? = null
    private var vibrator: android.os.Vibrator? = null
    private var ringing = false
    val isRinging: Boolean get() = ringing
    private val timeout = Runnable { stop() }

    fun start(ctx: Context) {
        if (ringing) return
        val app = ctx.applicationContext
        val am = app.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val filter = nm.currentInterruptionFilter
        if (filter == NotificationManager.INTERRUPTION_FILTER_NONE || filter == NotificationManager.INTERRUPTION_FILTER_ALARMS) return
        val mode = am.ringerMode
        if (mode == android.media.AudioManager.RINGER_MODE_SILENT) return
        val sound = mode == android.media.AudioManager.RINGER_MODE_NORMAL && am.getStreamVolume(android.media.AudioManager.STREAM_RING) > 0
        // in normal mode the phone's own "vibrate while ringing" switch decides (on when it can't be read); in vibrate mode it always vibrates
        val vibrate = mode == android.media.AudioManager.RINGER_MODE_VIBRATE ||
            runCatching { android.provider.Settings.System.getInt(app.contentResolver, "vibrate_when_ringing", 1) == 1 }.getOrDefault(true)
        ringing = true
        val attrs = android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
        if (sound) runCatching {
            val uri = android.media.RingtoneManager.getActualDefaultRingtoneUri(app, android.media.RingtoneManager.TYPE_RINGTONE)
                ?: android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)
            player = android.media.MediaPlayer().apply { setAudioAttributes(attrs); setDataSource(app, uri); isLooping = true; prepare(); start() }
        }.onFailure { android.util.Log.e("L1neRinger", "ringtone failed", it) }
        if (vibrate) runCatching {
            val v = if (android.os.Build.VERSION.SDK_INT >= 31) (app.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager).defaultVibrator
                    else @Suppress("DEPRECATION") (app.getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator)
            vibrator = v
            @Suppress("DEPRECATION") v.vibrate(android.os.VibrationEffect.createWaveform(longArrayOf(0, 1000, 1000), 0), attrs)      // buzz, pause, repeat
        }.onFailure { android.util.Log.e("L1neRinger", "vibration failed", it) }
        main.postDelayed(timeout, 60_000)
    }

    fun stop() {
        if (!ringing) return
        ringing = false; main.removeCallbacks(timeout)
        runCatching { player?.run { if (isPlaying) stop(); release() } }; player = null
        runCatching { vibrator?.cancel() }; vibrator = null
    }
}
