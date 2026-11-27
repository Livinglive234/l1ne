package com.livenet.l1ne.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.core.Provisioning
import com.livenet.l1ne.core.VCard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL

@Composable
fun ContactsScreen(open: (Dest) -> Unit) {
    val app = LocalApp.current; val ctx = LocalContext.current; val scope = rememberCoroutineScope()
    val contacts by app.contacts.contacts.collectAsState()
    val dirs by app.directories.sources.collectAsState()
    var search by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var dialog by remember { mutableStateOf<String?>(null) }       // "add" | "url" | "removeAll" | "message:<text>"
    var message by remember { mutableStateOf<String?>(null) }
    val directoryOn = dirs.any { it.enabled && it.isDirectory }

    fun summary(s: com.livenet.l1ne.data.ImportSummary) = "Added ${s.added}, updated ${s.updated}" + (if (s.skipped > 0) ", skipped ${s.skipped} without a SIP address" else "")
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            val text = withContext(Dispatchers.IO) { runCatching { ctx.contentResolver.openInputStream(uri)!!.use { String(it.readBytes()) } }.getOrNull() }
            message = if (text == null) "Could not read that file." else summary(app.contacts.merge(VCard.parse(text), app.store.selected?.id, "file"))
        }
    }
    // The system contact picker hands over only the contact the person picks, so L1ne never needs READ_CONTACTS.
    val phonePicker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val uri = r.data?.data
        if (r.resultCode == Activity.RESULT_OK && uri != null) {
            val entries = ArrayList<VCard.Entry>()
            ctx.contentResolver.query(uri, arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val id = c.getString(0); val name = c.getString(1) ?: ""
                    ctx.contentResolver.query(ContactsContract.Data.CONTENT_URI, arrayOf(ContactsContract.Data.DATA1), "${ContactsContract.Data.CONTACT_ID}=? AND ${ContactsContract.Data.MIMETYPE}=?",
                        arrayOf(id, ContactsContract.CommonDataKinds.SipAddress.CONTENT_ITEM_TYPE), null)?.use { d ->
                        while (d.moveToNext()) VCard.sipAddress(d.getString(0) ?: "")?.let { entries.add(VCard.Entry(name, it)) } }
                }
            }
            message = if (entries.isEmpty()) "That contact has no SIP address." else summary(app.contacts.merge(VCard.Result(entries, 0), app.store.selected?.id, "picker"))
        }
    }

    val grouped = remember(contacts, search) {
        contacts.filter { search.isEmpty() || it.name.contains(search, true) || it.address.contains(search, true) }
            .groupBy { it.name.firstOrNull()?.takeIf { c -> c.isLetter() }?.uppercase() ?: "#" }.toSortedMap()
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(search, { search = it }, Modifier.weight(1f), singleLine = true, placeholder = { Text("Search") }, leadingIcon = { Icon(Icons.Filled.Search, null) }, shape = MaterialTheme.shapes.extraLarge)
            Box {
                IconButton({ menu = true }) { Icon(Icons.Filled.Add, "Add") }
                DropdownMenu(menu, { menu = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) {
                    DropdownMenuItem({ Text("Import from Contacts…") }, { menu = false; phonePicker.launch(Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI)) }, leadingIcon = { Icon(Icons.Filled.PersonAdd, null) })
                    DropdownMenuItem({ Text("Import vCard file…") }, { menu = false; filePicker.launch(arrayOf("text/x-vcard", "text/vcard", "text/directory", "*/*")) }, leadingIcon = { Icon(Icons.Filled.Description, null) })
                    if (directoryOn) DropdownMenuItem({ Text("Import from a link is replaced by directory sync", color = L1neColors.Muted) }, {}, enabled = false)
                    else DropdownMenuItem({ Text("Import from a link…") }, { menu = false; dialog = "url" }, leadingIcon = { Icon(Icons.Filled.Link, null) })
                    DropdownMenuItem({ Text("Add contact…") }, { menu = false; dialog = "add" }, leadingIcon = { Icon(Icons.Filled.PersonAddAlt1, null) })
                    if (contacts.isNotEmpty()) { HorizontalDivider(color = L1neColors.Border)
                        DropdownMenuItem({ Text("Remove all", color = L1neColors.Danger) }, { menu = false; dialog = "removeAll" }, leadingIcon = { Icon(Icons.Filled.Delete, null, tint = L1neColors.Danger) }) }
                }
            }
        }
        if (contacts.isEmpty()) EmptyState(Icons.Filled.People, "No contacts", "Pick contacts that have a SIP address, import a vCard, or add one by hand. L1ne never reads your phone's contacts on its own.")
        else LazyColumn(Modifier.fillMaxSize()) {
            grouped.forEach { (letter, items) ->
                item(key = "h$letter") { Text(letter, Modifier.padding(horizontal = 16.dp, vertical = 6.dp), color = L1neColors.Brand, fontWeight = FontWeight.SemiBold) }
                items(items, key = { it.id }) { c ->
                    SwipeToDelete({ app.contacts.remove(c.id) }) {
                    Row(Modifier.fillMaxWidth().clickable { open(Dest.Person(PersonTarget(c.name, c.address, c.accountID))) }.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(48.dp, initialsOf(c.name), L1neColors.Brand.copy(alpha = 0.14f)); Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(c.name, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(c.address, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        CallCircleButton { app.engine.call(c.user, app.store.account(c.accountID) ?: app.store.selected) }
                    }
                    RowDivider()
                    }
                }
            }
        }
    }

    when (dialog) {
        "add" -> AddContactDialog { dialog = null }
        "url" -> LinkImportDialog({ dialog = null }) { message = it }
        "removeAll" -> AlertDialog({ dialog = null }, containerColor = L1neColors.SheetBg, title = { Text("Remove all contacts?") },
            text = { Text("This removes every contact from L1ne. Your phone's contacts are not touched.") },
            confirmButton = { TextButton({ app.contacts.removeAll(); dialog = null }) { Text("Remove all", color = L1neColors.Danger) } }, dismissButton = { TextButton({ dialog = null }) { Text("Cancel") } })
    }
    message?.let { m -> AlertDialog({ message = null }, containerColor = L1neColors.SheetBg, title = { Text("Contacts") }, text = { Text(m) }, confirmButton = { TextButton({ message = null }) { Text("OK") } }) }
}

@Composable
private fun AddContactDialog(onClose: () -> Unit) {
    val app = LocalApp.current
    var name by remember { mutableStateOf("") }; var address by remember { mutableStateOf("") }; var failed by remember { mutableStateOf(false) }
    AlertDialog(onClose, containerColor = L1neColors.SheetBg, title = { Text("Add contact") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
            OutlinedTextField(address, { address = it; failed = false }, label = { Text("SIP address, e.g. 7201@pbx.example.com") }, singleLine = true)
            if (failed) Text("Enter a SIP address like 7201@pbx.example.com.", color = MaterialTheme.colorScheme.error)
        } },
        confirmButton = { TextButton({ if (app.contacts.add(name.trim(), address.trim(), app.store.selected?.id)) onClose() else failed = true }, enabled = address.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClose) { Text("Cancel") } })
}

@Composable
private fun LinkImportDialog(onClose: () -> Unit, report: (String) -> Unit) {
    val app = LocalApp.current; val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }; var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(onClose, containerColor = L1neColors.SheetBg, title = { Text("Import from a link") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(text, { text = it }, label = { Text("https://…/contacts.vcf") }, singleLine = true)
            Text("L1ne fetches this once, now. It does not check again unless you do this again.", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        } },
        confirmButton = { TextButton(enabled = !busy && text.isNotBlank(), onClick = {
            val u = text.trim(); if (!u.startsWith("https://", true)) { error = "That isn't an https link."; return@TextButton }
            busy = true; error = null
            scope.launch {
                runCatching { withContext(Dispatchers.IO) { VCard.parse(String(URL(u).readBytes())) } }
                    .onSuccess { r -> val s = app.contacts.merge(r, app.store.selected?.id, "link"); report("Added ${s.added}, updated ${s.updated}" + (if (s.skipped > 0) ", skipped ${s.skipped} without a SIP address" else "")); onClose() }
                    .onFailure { error = it.message ?: "Could not fetch the link." }
                busy = false
            } }) { Text(if (busy) "Fetching…" else "Fetch") } },
        dismissButton = { TextButton(onClose) { Text("Cancel") } })
}

/** A person: big avatar, name, round call / message buttons, the SIP address, and Add to contacts when they aren't saved. */
@Composable
fun PersonScreen(p: PersonTarget, open: (Dest) -> Unit, onBack: (() -> Unit)?) {
    val app = LocalApp.current
    val contacts by app.contacts.contacts.collectAsState(); val accounts by app.store.accounts.collectAsState()
    val saved = contacts.any { it.address.equals(p.address, true) }
    val account = accounts.firstOrNull { it.id == p.accountID } ?: app.store.selected
    var added by remember { mutableStateOf(false) }
    PageScaffold("", onBack) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Spacer(Modifier.height(8.dp))
            Avatar(120.dp, initialsOf(p.name), L1neColors.Brand.copy(alpha = 0.14f))
            Text(p.name, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                Action(Icons.Filled.Call, "call") { app.engine.call(p.address.substringBefore('@'), account) }
                if (p.address.contains("@")) Action(Icons.AutoMirrored.Filled.Message, "message") { account?.let { open(Dest.Thread(it.id, p.address)) } }
            }
            Card(Modifier.padding(top = 4.dp)) {
                Column(Modifier.padding(16.dp)) {
                    Text("SIP address", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
                    SelectionContainer { Text(p.address) }
                    if (accounts.size > 1 && account != null) Text("via ${account.titleWithUser}", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
                }
            }
            if (p.address.contains("@") && !saved) TextButton({ if (app.contacts.add(p.name, p.address, p.accountID)) added = true }, enabled = !added) { Text(if (added) "Added" else "Add to contacts", color = L1neColors.Brand) }
        }
    }
}

@Composable
private fun Action(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clickable(onClick = onClick)) {
        Surface(shape = androidx.compose.foundation.shape.CircleShape, color = L1neColors.Surface, modifier = Modifier.size(58.dp)) { Box(contentAlignment = Alignment.Center) { Icon(icon, label, tint = L1neColors.Brand) } }
        Text(label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 6.dp))
    }
}

/** The optional Voicemail tab: one row per account with a voicemail number, its new-message count, and a button that dials the mailbox. */
@Composable
fun VoicemailScreen() {
    val app = LocalApp.current; val accounts by app.store.accounts.collectAsState(); val counts by app.engine.voicemail.collectAsState()
    val list = accounts.filter { it.voicemailTarget != null }
    if (list.isEmpty()) EmptyState(Icons.Filled.Voicemail, "No voicemail", "Add an account to check its voicemail.")
    else LazyColumn(Modifier.fillMaxSize()) {
        items(list, key = { it.id }) { a ->
            val n = counts[a.id] ?: 0
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Surface(shape = androidx.compose.foundation.shape.CircleShape, color = L1neColors.Brand.copy(alpha = 0.14f), modifier = Modifier.size(48.dp)) { Box(contentAlignment = Alignment.Center) { Icon(Icons.Filled.Voicemail, null, tint = L1neColors.Brand) } }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(if (list.size > 1) a.titleWithUser else "Voicemail", fontWeight = FontWeight.Medium)
                    Text(if (n > 0) "$n new message${if (n == 1) "" else "s"}" else "No new messages", style = MaterialTheme.typography.bodySmall, color = if (n > 0) L1neColors.Brand else L1neColors.Muted)
                }
                CallCircleButton { app.engine.callVoicemail(a.id) }
            }
            RowDivider()
        }
    }
}
