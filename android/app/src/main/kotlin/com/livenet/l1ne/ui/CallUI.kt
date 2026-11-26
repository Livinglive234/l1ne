package com.livenet.l1ne.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.automirrored.filled.PhoneForwarded
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import com.livenet.l1ne.sip.CallInfo
import com.livenet.l1ne.sip.SipEngine
import kotlinx.coroutines.delay

// Dark: black. Light: a gray, with translucent-white buttons on it.
private val CallBg get() = if (L1neColors.dark) Color(0xFF000000) else Color(0xFF5C6166)
private val CallSurface get() = if (L1neColors.dark) Color(0xFF121814) else Color(0x33FFFFFF)
private val CallBorder get() = if (L1neColors.dark) Color(0xFF223024) else Color(0x47FFFFFF)
private val CallSheet get() = if (L1neColors.dark) Color(0xFF0B0F0C) else Color(0xFF474C51)
private val CallBrand = Color(0xFF22C03C)
private val CallText = Color(0xFFE8EFE9)
private val CallMuted get() = if (L1neColors.dark) Color(0xFF94A398) else Color(0xFFDDE2DF)
private val CallDanger = Color(0xFFE04646)

/** Laid out like the iPhone call screen (always dark): a down arrow and the quality pill, name and time, six round buttons, one big end button. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CallScreen(call: CallInfo, engine: SipEngine, minimized: Boolean, setMinimized: (Boolean) -> Unit, open: (Dest) -> Unit) {
    val app = LocalApp.current
    val muted by engine.muted.collectAsState(); val held by engine.held.collectAsState(); val recording by engine.recording.collectAsState()
    val quality by engine.quality.collectAsState(); val numbers by engine.qualityNumbers.collectAsState(); val enc by engine.encryption.collectAsState()
    val contacts by app.contacts.contacts.collectAsState()
    val routes by engine.routes.collectAsState()
    var routeMenu by remember { mutableStateOf(false) }
    val speaker = routes.speaker
    var pad by remember { mutableStateOf(false) }; var more by remember { mutableStateOf(false) }; var transfer by remember { mutableStateOf(false) }; var list by remember { mutableStateOf(false) }
    var secs by remember(call.id) { mutableStateOf(engine.elapsed(call.id)) }
    LaunchedEffect(call.id, call.active) { while (call.active) { secs = engine.elapsed(call.id); delay(500) } }
    val name = app.contacts.name(call.number, call.peerAddress.substringAfter('@', "")) ?: call.number
    val status = when {
        call.active -> "%d:%02d".format(secs / 60, secs % 60)
        call.incoming -> "Incoming call"
        call.state == 3 && call.status == 180 -> "Ringing…"
        call.state == 3 -> "Connecting…"
        call.state == 4 -> "Connecting…"
        else -> "Calling…"
    }
    val live = call.active
    androidx.activity.compose.BackHandler(enabled = !minimized) { setMinimized(true) }

    if (minimized) return
    // On a tablet or an unfolded foldable the column keeps a phone's width instead of stretching across the screen.
    // Half open is treated exactly like open: the screen never changes layout with the fold.
    val header: @Composable ColumnScope.() -> Unit = {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton({ setMinimized(true) }) { Icon(Icons.Filled.KeyboardArrowDown, "Minimise call", tint = CallText, modifier = Modifier.size(30.dp)) }
            Spacer(Modifier.weight(1f))
            if (live) SignalBars(quality[call.id] ?: 0, numbers[call.id])
        }
        Spacer(Modifier.height(20.dp))
        Text(name, fontSize = 34.sp, fontWeight = FontWeight.SemiBold, color = CallText, maxLines = 2, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Text(status, color = CallMuted, fontSize = 20.sp, modifier = Modifier.padding(top = 6.dp))
        if (live) when (enc[call.id]) {
            SipEngine.Security.SRTP -> Label(Icons.Filled.Lock, "Encrypted by SRTP", CallBrand)
            SipEngine.Security.DTLS -> Label(Icons.Filled.Lock, "Encrypted by DTLS-SRTP", CallBrand)
            SipEngine.Security.NONE -> Label(Icons.Filled.LockOpen, "Not encrypted", CallDanger)
            else -> {} }
        if (call.id in held) Label(Icons.Filled.PauseCircle, "On hold", CallBrand)
        if (call.id in recording) Label(Icons.Filled.FiberManualRecord, "Recording", CallDanger)
    }
    val controls: @Composable ColumnScope.() -> Unit = {
        if (live || !call.incoming) {
            val rows = listOf(
                listOf(Btn(Icons.Filled.MicOff, "mute", call.id in muted, live) { engine.toggleMute(call.id) }, Btn(Icons.Filled.Dialpad, "keypad", false, live) { pad = true }, Btn(if (routes.active == android.telecom.CallAudioState.ROUTE_BLUETOOTH) Icons.Filled.Bluetooth else if (routes.active == android.telecom.CallAudioState.ROUTE_WIRED_HEADSET) Icons.Filled.Headset else Icons.AutoMirrored.Filled.VolumeUp,
                    when (routes.active) { android.telecom.CallAudioState.ROUTE_BLUETOOTH -> "bluetooth"; android.telecom.CallAudioState.ROUTE_WIRED_HEADSET -> "headset"; else -> "speaker" }, speaker, true) {
                    if (routes.bluetooth || routes.headset) routeMenu = true else engine.setSpeaker(!speaker) }),
                listOf(Btn(Icons.Filled.Add, "add call", false, live) { setMinimized(true) }, Btn(if (call.id in held) Icons.Filled.PlayArrow else Icons.Filled.Pause, if (call.id in held) "resume" else "hold", call.id in held, live) { engine.toggleHold(call.id) }, Btn(Icons.Filled.MoreHoriz, "more", false, true) { more = true }))
            rows.forEach { r -> Row(Modifier.fillMaxWidth().padding(bottom = 26.dp * cs()), horizontalArrangement = Arrangement.SpaceEvenly) { r.forEach { RoundBtn(it) } } }
        }
        Spacer(Modifier.weight(1f))
        if (call.incoming && !live) Row(Modifier.fillMaxWidth().padding(bottom = 34.dp * cs()), horizontalArrangement = Arrangement.SpaceEvenly) {
            Big(CallDanger, Icons.Filled.CallEnd, "decline") { engine.hangup(call.id) }; Big(CallBrand, Icons.Filled.Call, "accept") { engine.answer(call.id) } }
        else Box(Modifier.padding(bottom = 34.dp * cs())) { Big(CallDanger, Icons.Filled.CallEnd, null) { engine.hangup(call.id) } }
    }
    Surface(Modifier.fillMaxSize(), color = CallBg) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 520.dp).fillMaxSize().systemBarsPadding().padding(horizontal = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                header(); Spacer(Modifier.weight(1f)); controls()
            }
        }
    }

    if (routeMenu) ModalBottomSheet({ routeMenu = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = CallSheet) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val ra = android.telecom.CallAudioState.ROUTE_EARPIECE; val rs = android.telecom.CallAudioState.ROUTE_SPEAKER; val rb = android.telecom.CallAudioState.ROUTE_BLUETOOTH; val rh = android.telecom.CallAudioState.ROUTE_WIRED_HEADSET
            if (routes.supported and ra != 0) MoreRow(Icons.Filled.PhoneInTalk, if (routes.active == ra) "Phone  ✓" else "Phone", true) { routeMenu = false; engine.setRoute(ra) }
            MoreRow(Icons.AutoMirrored.Filled.VolumeUp, if (routes.active == rs) "Speaker  ✓" else "Speaker", true) { routeMenu = false; engine.setRoute(rs) }
            if (routes.bluetooth) MoreRow(Icons.Filled.Bluetooth, if (routes.active == rb) "Bluetooth  ✓" else "Bluetooth", true) { routeMenu = false; engine.setRoute(rb) }
            if (routes.headset) MoreRow(Icons.Filled.Headset, if (routes.active == rh) "Headset  ✓" else "Headset", true) { routeMenu = false; engine.setRoute(rh) }
        }
    }
    if (pad) DtmfScreen(call, engine) { pad = false }
    if (more) ModalBottomSheet({ more = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = CallSheet) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            MoreRow(Icons.AutoMirrored.Filled.PhoneForwarded, "Transfer…", live) { more = false; transfer = true }
            MoreRow(Icons.Filled.FiberManualRecord, if (call.id in recording) "Stop recording" else "Record call", live) { more = false; engine.toggleRecord(call.id) }
            MoreRow(Icons.AutoMirrored.Filled.Message, "Messages", call.peerAddress.isNotEmpty()) {
                more = false; val acc = call.accountID ?: app.store.selected?.id; if (acc != null) { setMinimized(true); open(Dest.Thread(acc, call.peerAddress.lowercase())) } }
            MoreRow(Icons.Filled.FormatListBulleted, "Calls list", true) { more = false; list = true }
        }
    }
    if (transfer) TransferDialog(call, engine) { transfer = false }
    if (list) CallsListDialog(engine) { list = false }
}

private class Btn(val icon: ImageVector, val label: String, val on: Boolean, val enabled: Boolean, val onClick: () -> Unit)

@Composable
private fun RoundBtn(b: Btn) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(88.dp * cs())) {
        Box(Modifier.size(78.dp * cs()).clip(CircleShape).background(if (b.on) CallBrand else CallSurface).then(if (b.on) Modifier else Modifier.border(1.dp, CallBorder, CircleShape)).clickable(enabled = b.enabled, onClick = b.onClick), contentAlignment = Alignment.Center) {
            Icon(b.icon, b.label, tint = if (b.on) Color(0xFF04120A) else CallText.copy(alpha = if (b.enabled) 1f else 0.4f), modifier = Modifier.size(28.dp)) }
        Text(b.label, color = CallText.copy(alpha = if (b.enabled) 1f else 0.4f), fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
    }
}

@Composable
private fun Big(color: Color, icon: ImageVector, label: String?, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(78.dp * cs()).clip(CircleShape).background(color).clickable(onClick = onClick), contentAlignment = Alignment.Center) { Icon(icon, label ?: "End", tint = if (color == CallBrand) Color(0xFF04120A) else Color.White, modifier = Modifier.size(32.dp)) }
        if (label != null) Text(label, color = CallText, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
    }
}

@Composable
private fun Label(icon: ImageVector, text: String, tint: Color) = Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) { Icon(icon, null, Modifier.size(14.dp), tint = tint); Spacer(Modifier.width(4.dp)); Text(text, color = tint, fontSize = 13.sp) }

@Composable
private fun MoreRow(icon: ImageVector, title: String, enabled: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(CallSurface).border(1.dp, CallBorder, RoundedCornerShape(14.dp)).clickable(enabled = enabled, onClick = onClick).padding(horizontal = 18.dp, vertical = 15.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = CallBrand.copy(alpha = if (enabled) 1f else 0.4f), modifier = Modifier.size(26.dp)); Spacer(Modifier.width(16.dp)); Text(title, color = CallText.copy(alpha = if (enabled) 1f else 0.4f), fontSize = 16.sp) }
}

/** Call quality as a small pill: five rounded bars (green, amber when fair, red when poor); tapping shows the figures behind the score. */
@Composable
private fun SignalBars(level: Int, n: SipEngine.QualityNumbers?) {
    var show by remember { mutableStateOf(false) }
    val tint = if (level >= 3) CallBrand else if (level == 2) Color(0xFFFF9500) else CallDanger
    val word = listOf("", "Poor", "Poor", "Fair", "Good", "Excellent")[level.coerceIn(0, 5)]
    Box {
        Row(Modifier.clip(CircleShape).background(CallSurface).border(1.dp, CallBorder, CircleShape).clickable { if (n != null) show = true }.padding(horizontal = 12.dp, vertical = 7.dp), horizontalArrangement = Arrangement.spacedBy(2.5.dp), verticalAlignment = Alignment.Bottom) {
            for (i in 1..5) Box(Modifier.width(3.5.dp).height((4 + i * 3).dp).clip(CircleShape).background(if (i <= level) tint else CallMuted.copy(alpha = 0.28f)))
        }
        if (show && n != null) Popup(alignment = Alignment.TopEnd, offset = androidx.compose.ui.unit.IntOffset(0, 120), onDismissRequest = { show = false }) {
            Column(Modifier.clip(RoundedCornerShape(16.dp)).background(CallSurface).border(1.dp, CallBorder, RoundedCornerShape(16.dp)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Call quality: ${word.lowercase()}", color = CallText, fontWeight = FontWeight.SemiBold)
                Text("Packet loss: %.1f %%".format(n.lossPercent), color = CallText); Text("Jitter: %.0f ms".format(n.jitterMs), color = CallText)
                Text(if (n.roundTripMs > 0) "Round trip: %.0f ms".format(n.roundTripMs) else "Round trip: not reported", color = CallText)
            }
        }
    }
}

/** The in-call keypad, full screen: a back button, the digits you have sent, the keys and the end button. */
@Composable
private fun DtmfScreen(call: CallInfo, engine: SipEngine, onBack: () -> Unit) {
    var typed by remember { mutableStateOf("") }
    androidx.compose.ui.window.Dialog(onBack, androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = CallBg) {
            Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth().padding(top = 8.dp)) { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = CallText) } }
                Text(typed.ifEmpty { " " }, color = CallText, fontSize = 34.sp, fontWeight = FontWeight.Light, maxLines = 1, modifier = Modifier.padding(top = 24.dp * cs()).height(48.dp))
                Spacer(Modifier.weight(1f))
                listOf("123" to "", "456" to "", "789" to "", "*0#" to "").forEach { (row, _) ->
                    Row(horizontalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.padding(bottom = 16.dp * cs())) {
                        row.forEach { k -> Box(Modifier.size(78.dp * cs()).clip(CircleShape).background(CallSurface).border(1.dp, CallBorder, CircleShape).clickable { typed += k; engine.dtmf(call.id, k.toString()) }, contentAlignment = Alignment.Center) { Text(k.toString(), fontSize = 30.sp, fontWeight = FontWeight.Light, color = CallText) } }
                    }
                }
                Spacer(Modifier.weight(1f)); Box(Modifier.padding(bottom = 34.dp * cs())) { Big(CallDanger, Icons.Filled.CallEnd, null) { engine.hangup(call.id) } }
            }
        }
    }
}

@Composable
private fun TransferDialog(call: CallInfo, engine: SipEngine, onClose: () -> Unit) {
    val app = LocalApp.current; val contacts by app.contacts.contacts.collectAsState(); var typed by remember { mutableStateOf("") }
    fun go(to: String) { if (to.isNotBlank()) { engine.transfer(call.id, to.trim(), app.store.accounts.value.firstOrNull { it.id == call.accountID }); onClose() } }
    AlertDialog(onClose, containerColor = CallSheet, title = { Text("Transfer to…", color = CallText) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(typed, { typed = it }, singleLine = true, label = { Text("Extension or address") })
            contacts.filter { typed.isEmpty() || it.name.contains(typed, true) || it.address.contains(typed, true) }.take(5).forEach { c ->
                Row(Modifier.fillMaxWidth().clickable { go(c.user) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) { Avatar(32.dp, initialsOf(c.name), CallBrand.copy(alpha = 0.14f)); Spacer(Modifier.width(10.dp)); Column { Text(c.name, color = CallText); Text(c.address, fontSize = 12.sp, color = CallMuted) } } }
        } },
        confirmButton = { TextButton({ go(typed) }, enabled = typed.isNotBlank()) { Text("Transfer") } }, dismissButton = { TextButton(onClose) { Text("Cancel") } })
}

@Composable
private fun CallsListDialog(engine: SipEngine, onClose: () -> Unit) {
    val calls by engine.calls.collectAsState(); val held by engine.held.collectAsState()
    AlertDialog(onClose, containerColor = CallSheet, title = { Text("Calls", color = CallText) }, text = {
        Column { calls.forEach { c -> Row(Modifier.fillMaxWidth().clickable { engine.switchTo(c.id); onClose() }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { Text(c.number, color = CallText); Text(if (!c.active) (if (c.incoming) "Incoming" else "Calling") else if (c.id in held) "On hold" else "Active", fontSize = 12.sp, color = CallMuted) }
            if (c.id == engine.currentCall?.id) Icon(Icons.Filled.CheckCircle, null, tint = CallBrand)
            IconButton({ engine.hangup(c.id) }) { Icon(Icons.Filled.CallEnd, "Hang up", tint = CallDanger) } } } } },
        confirmButton = { TextButton(onClose) { Text("Done") } })
}

/** The green bar shown at the top of the app while a call is minimised; tapping it returns to the call. */
@Composable
fun CallBar(call: CallInfo, onClick: () -> Unit) {
    val app = LocalApp.current
    var secs by remember(call.id) { mutableStateOf(app.engine.elapsed(call.id)) }
    LaunchedEffect(call.id, call.active) { while (call.active) { secs = app.engine.elapsed(call.id); delay(500) } }
    val name = app.contacts.name(call.number, call.peerAddress.substringAfter('@', "")) ?: call.number
    Box(Modifier.fillMaxWidth().background(CallBrand).statusBarsPadding().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp), contentAlignment = Alignment.CenterStart) {
        Text("$name · ${if (call.active) "%d:%02d".format(secs / 60, secs % 60) else "calling"} — tap to return", color = Color(0xFF04120A), fontWeight = FontWeight.Medium)
    }
}

/** Call-screen scale: 1.0 on a normal phone, smaller on a short one so the end-call button stays on screen, a little larger on a tablet. */
@Composable
private fun cs(): Float {
    val h = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.toFloat()
    val cap = if (h > 1000f) 1.3f else 1f
    return minOf((h - 360f) / 340f, (h - 260f) / 488f).coerceIn(0.6f, cap)
}
