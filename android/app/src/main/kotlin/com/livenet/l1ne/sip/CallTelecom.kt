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

    fun reportIncoming(callId: Int, display: String, address: String) {
        runCatching {
            tm.addNewIncomingCall(handle, Bundle().apply {
                putInt(EXTRA_CALL, callId); putString(EXTRA_NAME, display)
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts("sip", address, null)) })
        }.onFailure { android.util.Log.e("L1neTelecom", "addNewIncomingCall failed", it); CallNotifications.showIncoming(app, callId, display) }       // no Telecom? still ring from our own notification
    }

    fun reportOutgoing(callId: Int, display: String, address: String) {
        runCatching {
            tm.placeCall(Uri.fromParts("sip", address, null), Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, Bundle().apply { putInt(EXTRA_CALL, callId); putString(EXTRA_NAME, display) }) })
        }
    }

    fun active(callId: Int) { connections[callId]?.setActive(); CallNotifications.cancelIncoming(app) }
    fun held(callId: Int, on: Boolean) { connections[callId]?.let { if (on) it.setOnHold() else it.setActive() } }
    fun ended(callId: Int, byRemote: Boolean) {
        connections.remove(callId)?.let { it.setDisconnected(DisconnectCause(if (byRemote) DisconnectCause.REMOTE else DisconnectCause.LOCAL)); it.destroy() }
        CallNotifications.cancelIncoming(app)
    }
    fun setRoute(route: Int) { connections.values.firstOrNull()?.setAudioRoute(route) }

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
        android.util.Log.i("L1neTelecom", "show incoming ui $callId"); CallNotifications.showIncoming(app, callId, app.engine.displayName(callId)) }
    @Deprecated("Telecom still calls this on older Android versions")
    override fun onCallAudioStateChanged(state: CallAudioState?) { state?.let { app.telecom.routes.value = AudioRoutes(it.route, it.supportedRouteMask); app.engine.updateProximity() } }
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
    private const val INCOMING = "l1ne_incoming"; const val SERVICE = "l1ne_service"; private const val ID_INCOMING = 4001

    fun channels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(INCOMING, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply { description = "Rings when someone calls you"; lockscreenVisibility = Notification.VISIBILITY_PUBLIC })
        nm.createNotificationChannel(NotificationChannel(SERVICE, "Connection", NotificationManager.IMPORTANCE_LOW).apply { description = "Keeps L1ne signed in so calls can reach you" })
    }

    private fun action(ctx: Context, what: String, id: Int) =
        PendingIntent.getBroadcast(ctx, id * 10 + what.hashCode().and(7), Intent(ctx, CallActionReceiver::class.java).setAction(what).putExtra("call", id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    fun showIncoming(ctx: Context, callId: Int, name: String) {
        channels(ctx)
        val open = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val person = androidx.core.app.Person.Builder().setName(name).setImportant(true).build()
        val n = androidx.core.app.NotificationCompat.Builder(ctx, INCOMING).setSmallIcon(R.drawable.ic_stat_l1ne).setCategory(Notification.CATEGORY_CALL).setOngoing(true)
            .setFullScreenIntent(open, true).setContentIntent(open)
            .setStyle(androidx.core.app.NotificationCompat.CallStyle.forIncomingCall(person, action(ctx, "decline", callId), action(ctx, "answer", callId))).build()
        runCatching { NotificationManagerCompat.from(ctx).notify(ID_INCOMING, n) }
    }
    fun cancelIncoming(ctx: Context) = NotificationManagerCompat.from(ctx).cancel(ID_INCOMING)

    /** (androidx's CallStyle, not the framework's: android.app.Notification.CallStyle only exists from Android 12 and crashed every call on older phones.)
     *  The persistent notification of the service: "Connected" while idle, the call and a Hang up button during one. */
    fun service(ctx: Context, callName: String?, callId: Int?): Notification {
        channels(ctx)
        val open = PendingIntent.getActivity(ctx, 1, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = androidx.core.app.NotificationCompat.Builder(ctx, SERVICE).setSmallIcon(R.drawable.ic_stat_l1ne).setContentIntent(open).setOngoing(true)
        return if (callName != null && callId != null)
            b.setStyle(androidx.core.app.NotificationCompat.CallStyle.forOngoingCall(androidx.core.app.Person.Builder().setName(callName).build(), action(ctx, "hangup", callId))).setCategory(Notification.CATEGORY_CALL).build()
        else b.setContentTitle("L1ne").setContentText("Connected — you can receive calls").build()
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
