package com.livenet.l1ne.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.data.Conversation
import com.livenet.l1ne.data.MsgStatus

/** Cases where a text probably won't arrive, so L1ne says so before it is sent. */
object MessagingWarnings {
    /** Another line in L1ne that is the recipient: two lines on one device and server share a connection, so the server can't route between them. */
    fun ownLine(app: com.livenet.l1ne.L1neApplication, peer: String, from: String): com.livenet.l1ne.core.Account? {
        val p = peer.lowercase().removePrefix("sip:")
        return app.store.accounts.value.firstOrNull { it.id != from && p == "${it.username}@${it.domain}".lowercase() }
    }
    /** Other SIP apps on this phone that could be signed in to the same line. */
    fun otherSIPApps(ctx: Context): List<String> = listOf("Linphone" to "org.linphone", "Zoiper" to "com.zoiper.android.app", "Groundwire" to "com.counterpath.groundwire")
        .filter { (_, pkg) -> runCatching { ctx.packageManager.getPackageInfo(pkg, 0) }.isSuccess }.map { it.first }
}

@Composable
fun WarningBanner(text: String, dismiss: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(L1neColors.Surface).border(1.dp, Color(0xFFFF9500).copy(alpha = 0.5f), RoundedCornerShape(12.dp)).padding(12.dp), verticalAlignment = Alignment.Top) {
        Icon(Icons.Filled.Warning, null, tint = Color(0xFFFF9500), modifier = Modifier.size(20.dp)); Spacer(Modifier.width(10.dp))
        Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
        if (dismiss != null) Icon(Icons.Filled.Close, "Dismiss", Modifier.size(18.dp).clickable(onClick = dismiss), tint = L1neColors.Muted)
    }
}

@Composable
fun ConversationsScreen(open: (Dest) -> Unit) {
    val app = LocalApp.current
    val convs by app.messages.conversations.collectAsState(); val accounts by app.store.accounts.collectAsState(); val unsupported by app.engine.messagingNote.collectAsState()
    Box(Modifier.fillMaxSize()) {
        if (convs.isEmpty()) Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Icons.AutoMirrored.Filled.Chat, null, Modifier.size(56.dp), tint = L1neColors.Muted); Spacer(Modifier.height(12.dp))
            Text("No chats", style = MaterialTheme.typography.titleLarge); Text("Texts need a server that supports SIP messages.", color = L1neColors.Muted, modifier = Modifier.padding(top = 8.dp))
        } else LazyColumn(Modifier.fillMaxSize()) {
            items(convs, key = { it.id }) { c ->
                SwipeToDelete({ app.messages.delete(listOf(c.id)) }) {
                val name = app.contacts.name(c.user, c.peer.substringAfter('@', "")) ?: com.livenet.l1ne.core.PhoneFormat.pretty(c.user)
                Row(Modifier.fillMaxWidth().clickable { open(Dest.Thread(c.accountID, c.peer)) }.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Avatar(48.dp, initialsOf(name), L1neColors.Brand.copy(alpha = 0.14f)); Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(name, fontWeight = if (c.unread > 0) FontWeight.Bold else FontWeight.Medium, maxLines = 1)
                        Text(c.last?.text ?: "", color = L1neColors.Muted, maxLines = 1, style = MaterialTheme.typography.bodyMedium)
                        accountTitle(accounts, c.accountID)?.let { Text("via $it", style = MaterialTheme.typography.labelSmall, color = L1neColors.Muted.copy(alpha = 0.8f)) }
                    }
                    if (c.unread > 0) Badge(containerColor = L1neColors.Brand) { Text("${c.unread}") }
                }
                RowDivider()
                }
            }
        }
        FloatingActionButton({ open(Dest.NewMessage) }, Modifier.align(Alignment.BottomEnd).padding(20.dp), containerColor = L1neColors.Brand, contentColor = L1neColors.OnBrand) { Icon(Icons.Filled.Edit, "New message") }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ThreadScreen(accountID: String, peer: String, open: (Dest) -> Unit, onBack: (() -> Unit)?) {
    val app = LocalApp.current; val ctx = LocalContext.current
    val convs by app.messages.conversations.collectAsState(); val accounts by app.store.accounts.collectAsState()
    val conv = convs.firstOrNull { it.id == Conversation.key(accountID, peer) }
    val account = accounts.firstOrNull { it.id == accountID }
    val user = peer.substringBefore('@'); val name = app.contacts.name(user, peer.substringAfter('@', "")) ?: com.livenet.l1ne.core.PhoneFormat.pretty(user)
    var text by remember { mutableStateOf("") }
    var dismissed by remember { mutableStateOf(false) }
    val own = MessagingWarnings.ownLine(app, peer, accountID)
    val others = remember { MessagingWarnings.otherSIPApps(ctx) }
    val state = rememberLazyListState()
    LaunchedEffect(conv?.messages?.size) { app.messages.markRead(accountID, peer); conv?.messages?.size?.let { if (it > 0) state.scrollToItem(it - 1) } }

    PageScaffold(name, onBack, actions = {
        IconButton({ open(Dest.Person(PersonTarget(name, peer, accountID))) }) { Icon(Icons.Filled.Info, "Contact info") }
        IconButton({ app.engine.call(user, account) }) { Icon(Icons.Filled.Call, "Call") }
    }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().imePadding()) {
            if (accountTitle(accounts, accountID) != null) Text("from ${account?.title ?: "—"}", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
            Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (own != null) WarningBanner("${own.title} is another line in L1ne on the same server. A text between two lines in one app usually doesn't arrive, because the server can't route it between them.")
                if (others.isNotEmpty() && !dismissed) WarningBanner("${others.joinToString(", ")} is also on this phone. If this line is signed in there too, the server may deliver texts to that app instead of L1ne.") { dismissed = true }
            }
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = state, contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(conv?.messages ?: emptyList(), key = { it.id }) { m ->
                    var menu by remember { mutableStateOf(false) }
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (m.outgoing) Alignment.End else Alignment.Start) {
                        Box {
                            Text(m.text, Modifier.clip(RoundedCornerShape(18.dp)).background(if (m.outgoing) L1neColors.Brand else L1neColors.Surface)
                                .combinedClickable(onClick = {}, onLongClick = { menu = true }).padding(horizontal = 14.dp, vertical = 9.dp),
                                color = if (m.outgoing) L1neColors.OnBrand else L1neColors.Text)
                            DropdownMenu(menu, { menu = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) {
                                DropdownMenuItem({ Text("Copy") }, { (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("message", m.text)); menu = false }, leadingIcon = { Icon(Icons.Filled.ContentCopy, null) })
                                DropdownMenuItem({ Text("Delete", color = L1neColors.Danger) }, { app.messages.remove(m.id); menu = false }, leadingIcon = { Icon(Icons.Filled.Delete, null, tint = L1neColors.Danger) })
                            }
                        }
                        if (m.status == MsgStatus.FAILED) Text(m.failure ?: "Not delivered", Modifier.clickable { account?.let { a -> app.messages.remove(m.id); app.engine.sendText(a, peer, m.text) } }, style = MaterialTheme.typography.labelSmall, color = L1neColors.Danger)
                        if (m.status == MsgStatus.FAILED) Text("Tap to try again", style = MaterialTheme.typography.labelSmall, color = L1neColors.Muted)
                        if (m.status == MsgStatus.SENDING) Text("Sending…", style = MaterialTheme.typography.labelSmall, color = L1neColors.Muted)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text("Message") }, shape = RoundedCornerShape(24.dp), maxLines = 4)
                IconButton({ val t = text.trim(); if (t.isNotEmpty() && account != null) { app.engine.sendText(account, peer, t); text = "" } }, enabled = text.isNotBlank()) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = L1neColors.Brand) }
            }
        }
    }
}

@Composable
fun NewMessageDialog(open: (Dest) -> Unit, onClose: () -> Unit) {
    val app = LocalApp.current; val accounts by app.store.accounts.collectAsState(); val contacts by app.contacts.contacts.collectAsState()
    var typed by remember { mutableStateOf("") }; var from by remember { mutableStateOf(app.store.selected) }; var lineMenu by remember { mutableStateOf(false) }
    fun start(address: String, acc: com.livenet.l1ne.core.Account?) {
        val a = acc ?: return; val peer = (if (address.contains("@")) address else "$address@${a.domain}").removePrefix("sip:").lowercase()
        onClose(); open(Dest.Thread(a.id, peer))
    }
    AlertDialog(onClose, containerColor = L1neColors.SheetBg, title = { Text("New message") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (accounts.size > 1) Box {
                AssistChip({ lineMenu = true }, label = { Text("from ${from?.title ?: "—"}") }, trailingIcon = { Icon(Icons.Filled.ExpandMore, null) })
                DropdownMenu(lineMenu, { lineMenu = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) { accounts.forEach { a -> DropdownMenuItem({ Text(a.title) }, { from = a; lineMenu = false }) } }
            }
            OutlinedTextField(typed, { typed = it }, label = { Text("Extension or user@server") }, singleLine = true)
            contacts.filter { typed.isEmpty() || it.name.contains(typed, true) || it.address.contains(typed, true) }.take(5).forEach { c ->
                Row(Modifier.fillMaxWidth().clickable { start(c.address, accounts.firstOrNull { it.id == c.accountID } ?: from) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Avatar(32.dp, initialsOf(c.name), L1neColors.Brand.copy(alpha = 0.14f)); Spacer(Modifier.width(10.dp)); Column { Text(c.name); Text(c.address, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) } }
            }
        } },
        confirmButton = { TextButton({ start(typed.trim(), from) }, enabled = typed.isNotBlank()) { Text("Start") } }, dismissButton = { TextButton(onClose) { Text("Cancel") } })
}
