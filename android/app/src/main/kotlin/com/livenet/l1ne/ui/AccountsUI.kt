package com.livenet.l1ne.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Media
import com.livenet.l1ne.core.Provisioning
import com.livenet.l1ne.core.Transport
import com.livenet.l1ne.data.AccountStore
import com.livenet.l1ne.sip.SipEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountsSheet(store: AccountStore, engine: SipEngine, onDismiss: () -> Unit) {
    val accounts by store.accounts.collectAsState()
    val reg by engine.registration.collectAsState()
    var editing by remember { mutableStateOf<Account?>(null) }
    var linking by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = L1neColors.SheetBg) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Accounts", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 8.dp, bottom = 4.dp))
            accounts.forEach { a ->
                Column(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.large).background(L1neColors.Surface).clickable { editing = a }.padding(16.dp)) {
                    Text(a.title, style = MaterialTheme.typography.titleMedium)
                    Text("${a.username}@${a.domain}", color = L1neColors.Muted)
                    val s = reg[a.id] ?: "Not connected"
                    Text(s, color = if (s == "Registered") L1neColors.Brand else L1neColors.Muted, style = MaterialTheme.typography.bodySmall)
                }
            }
            AddRow("Add account") { editing = Account(port = 5061) }
            AddRow("Set up from a link") { linking = true }
        }
    }
    editing?.let { a -> AccountEditor(a, store, engine) { editing = null } }
    if (linking) LinkDialog(store, engine) { linking = false }
}

@Composable
private fun AddRow(text: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.large).background(L1neColors.Surface).clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(Icons.Filled.AddCircle, null, tint = L1neColors.Brand); Text(text, color = L1neColors.Brand)
    }
}

@Composable
private fun AccountEditor(initial: Account, store: AccountStore, engine: SipEngine, onClose: () -> Unit) {
    val isNew = store.accounts.value.none { it.id == initial.id }
    var label by remember { mutableStateOf(initial.label) }
    var user by remember { mutableStateOf(initial.username) }
    var auth by remember { mutableStateOf(initial.authUser) }
    var pass by remember { mutableStateOf(if (isNew) "" else store.secret(initial.id)) }
    var domain by remember { mutableStateOf(initial.domain) }
    var port by remember { mutableStateOf(initial.port.toString()) }
    var tls by remember { mutableStateOf(initial.transport) }
    var media by remember { mutableStateOf(initial.media) }
    AlertDialog(onDismissRequest = onClose, containerColor = L1neColors.SheetBg,
        title = { Text(if (isNew) "New account" else "Account") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(label, { label = it }, label = { Text("Name (optional)") }, singleLine = true)
                OutlinedTextField(user, { user = it }, label = { Text("Username") }, singleLine = true)
                OutlinedTextField(pass, { pass = it }, label = { Text("Password") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(domain, { domain = it }, label = { Text("Server (e.g. pbx.example.com)") }, singleLine = true)
                OutlinedTextField(port, { port = it.filter(Char::isDigit) }, label = { Text("Port") }, singleLine = true)
                OutlinedTextField(auth, { auth = it }, label = { Text("Auth username (if different)") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Transport.entries.forEach { FilterChip(tls == it, { tls = it }, label = { Text(it.wire.uppercase()) }) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(media == Media.SRTP_SDES, { media = Media.SRTP_SDES }, label = { Text("SRTP") })
                    FilterChip(media == Media.NONE, { media = Media.NONE }, label = { Text("No encryption") })
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val a = initial.copy(label = label.ifEmpty { domain }, username = user.trim(), authUser = auth.trim(), domain = domain.trim(),
                    port = port.toIntOrNull() ?: 5061, transport = tls, media = media)
                store.save(a, pass); engine.register(a); onClose()
            }, enabled = user.isNotBlank() && domain.isNotBlank()) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (!isNew) TextButton({ engine.unregister(initial.id); store.remove(initial.id); onClose() }) { Text("Remove") }
                TextButton(onClose) { Text("Cancel") }
            }
        })
}

@Composable
private fun LinkDialog(store: AccountStore, engine: SipEngine, onClose: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onClose, containerColor = L1neColors.SheetBg, title = { Text("Set up from a link") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Paste the https link (or linphone-config: link) from your PBX setup file.", color = L1neColors.Muted)
                OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("https://…") })
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && text.isNotBlank(), onClick = {
                val url = Provisioning.configUrl(text) ?: run { error = "That isn't an https configuration link."; return@TextButton }
                busy = true; error = null
                scope.launch {
                    val r = runCatching { withContext(Dispatchers.IO) { Provisioning.parse(URL(url.toString()).readBytes()) } }
                    r.onSuccess { res ->
                        res.selectedByDefault.forEach { p -> store.save(p.account, p.secret); engine.register(p.account) }
                        onClose()
                    }.onFailure { error = it.message ?: "Could not fetch the file." }
                    busy = false
                }
            }) { Text(if (busy) "Fetching…" else "Add") }
        },
        dismissButton = { TextButton(onClose) { Text("Cancel") } })
}
