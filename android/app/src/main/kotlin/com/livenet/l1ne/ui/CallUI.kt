package com.livenet.l1ne.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
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
import com.livenet.l1ne.sip.CallInfo
import com.livenet.l1ne.sip.SipEngine
import kotlinx.coroutines.delay

/** Full-screen call: name/number, status or timer, mute/speaker/hold/keypad, hang up. Incoming shows Answer/Decline. */
@Composable
fun CallScreen(call: CallInfo, engine: SipEngine) {
    val muted by engine.muted.collectAsState()
    val held by engine.held.collectAsState()
    var speaker by remember { mutableStateOf(engine.speaker) }
    var pad by remember { mutableStateOf(false) }
    var secs by remember(call.id) { mutableStateOf(call.connectedSecs) }
    LaunchedEffect(call.id, call.active) { while (call.active) { delay(1000); secs++ } }
    val status = when {
        call.active -> "%d:%02d".format(secs / 60, secs % 60)
        call.incoming -> "Incoming call"
        call.state == 3 && call.status == 180 -> "Ringing…"
        call.state == 3 -> "Connecting…"
        call.state == 4 -> "Connecting…"
        else -> "Calling…"
    }
    Surface(Modifier.fillMaxSize(), color = Color(0xFF0B0F0C)) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(48.dp))
            Box(Modifier.size(96.dp).clip(CircleShape).background(L1neColors.Brand.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Person, null, Modifier.size(52.dp), tint = L1neColors.Brand)
            }
            Spacer(Modifier.height(16.dp))
            Text(call.number, fontSize = 30.sp, fontWeight = FontWeight.Light, color = Color.White)
            Text(status, color = Color.White.copy(alpha = 0.7f), modifier = Modifier.padding(top = 4.dp))
            Spacer(Modifier.weight(1f))
            if (call.incoming && !call.active) {
                Row(Modifier.fillMaxWidth().padding(bottom = 48.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                    Big(Color(0xFFD9363E), Icons.Filled.CallEnd, "Decline") { engine.hangup(call.id) }
                    Big(L1neColors.Brand, Icons.Filled.Call, "Answer") { engine.answer(call.id) }
                }
            } else {
                if (pad) DtmfPad(call, engine) { pad = false } else {
                    Row(Modifier.fillMaxWidth().padding(bottom = 24.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                        Toggle(Icons.Filled.MicOff, "Mute", call.id in muted) { engine.toggleMute(call.id) }
                        Toggle(Icons.AutoMirrored.Filled.VolumeUp, "Speaker", speaker) { speaker = !speaker; engine.setSpeaker(speaker) }
                        Toggle(Icons.Filled.Pause, "Hold", call.id in held) { engine.toggleHold(call.id) }
                        Toggle(Icons.Filled.Dialpad, "Keypad", false) { pad = true }
                    }
                    Big(Color(0xFFD9363E), Icons.Filled.CallEnd, "End") { engine.hangup(call.id) }
                    Spacer(Modifier.height(32.dp))
                }
            }
        }
    }
}

@Composable
private fun Big(color: Color, icon: ImageVector, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(color).clickable(onClick = onClick), contentAlignment = Alignment.Center) { Icon(icon, label, tint = Color.White) }
        Text(label, color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun Toggle(icon: ImageVector, label: String, on: Boolean, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(60.dp).clip(CircleShape).background(if (on) Color.White else Color.White.copy(alpha = 0.14f)).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = if (on) Color.Black else Color.White)
        }
        Text(label, color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun DtmfPad(call: CallInfo, engine: SipEngine, onBack: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        listOf("123", "456", "789", "*0#").forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.padding(bottom = 14.dp)) {
                row.forEach { k -> Box(Modifier.size(68.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.14f)).clickable { engine.dtmf(call.id, k.toString()) }, contentAlignment = Alignment.Center) { Text(k.toString(), fontSize = 26.sp, color = Color.White) } }
            }
        }
        TextButton(onBack) { Text("Back", color = Color.White) }
    }
}
