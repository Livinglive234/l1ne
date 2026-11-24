package com.livenet.l1ne.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.data.*
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

@Composable
fun ContactsSyncScreen(onBack: () -> Unit) {
    val app = LocalApp.current; val scope = rememberCoroutineScope()
    val sources by app.directories.sources.collectAsState(); val running by app.dirSync.running.collectAsState(); val accounts by app.store.accounts.collectAsState()
    var editing by remember { mutableStateOf<DirectorySource?>(null) }; var pending by remember { mutableStateOf<DirectorySource?>(null) }; var message by remember { mutableStateOf<String?>(null) }; var addMenu by remember { mutableStateOf(false) }
    BackHandler(onBack = onBack)

    fun pbxName(s: DirectorySource) = accounts.firstOrNull { it.id == s.accountID }?.title ?: if (s.kind == DirKind.LDAP) s.host else runCatching { java.net.URL(s.url).host }.getOrDefault(s.url)
    fun status(s: DirectorySource): String { if (!s.enabled) return "Off"; val every = s.interval.label
        return s.lastResult?.let { "$every · ${s.lastSync?.let { t -> "Last sync ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(t))}: " } ?: ""}$it" } ?: "$every · not synced yet" }
    fun startSync(s: DirectorySource) { scope.launch { message = app.dirSync.sync(s.id) } }
    fun activate(s: DirectorySource) {
        if (!s.isDirectory) { startSync(s); return }
        if (app.contacts.hasLinkImports || app.directories.sources.value.any { !it.isDirectory && it.enabled }) pending = s else startSync(s)
    }
    fun setEnabled(s: DirectorySource, on: Boolean) {
        if (on && !s.isDirectory && app.directories.directoryEnabled) { message = "A CardDAV or LDAP directory is on, and it replaces the vCard link. Turn the directory off first."; return }
        app.directories.update(s.id) { it.copy(enabled = on) }
        if (on) app.directories.sources.value.firstOrNull { it.id == s.id }?.let { activate(it) }
    }

    PageScaffold("Contacts sync", onBack) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            Card(Modifier.padding(top = 8.dp)) { Text("Keeps your contacts in step with a vCard link (like the one in a Linphone-style setup file), a CardDAV address book or an LDAP directory. While a CardDAV or LDAP directory is on it replaces the vCard link, and contacts that came from the link are removed. Contacts you typed in, or picked from your phone, are never touched.",
                Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
            SectionHeader("Directories")
            Card {
                sources.forEachIndexed { i, s ->
                    Column(Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f).clickable { editing = s }) { Text(s.title); Text("${when (s.kind) { DirKind.LDAP -> "LDAP"; DirKind.CARDDAV -> "CardDAV"; else -> "vCard link" }} · ${pbxName(s)}", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
                            Switch(s.enabled, { setEnabled(s, it) })
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(status(s), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = L1neColors.Muted, maxLines = 2)
                            if (s.id in running) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else TextButton({ scope.launch { message = app.dirSync.sync(s.id) } }, enabled = s.enabled) { Text("Sync now", color = L1neColors.Brand) }
                            IconButton({ app.contacts.deleteSource(s.tag); app.directories.remove(s.id) }) { Icon(Icons.Filled.Delete, "Delete", tint = L1neColors.Muted) }
                        }
                    }
                    if (i < sources.size - 1) RowDivider()
                }
            }
            Spacer(Modifier.height(16.dp))
            Card { Box { NavRow("Add directory", icon = Icons.Filled.AddCircle) { addMenu = true }
                DropdownMenu(addMenu, { addMenu = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) {
                    DropdownMenuItem({ Text("CardDAV address book…") }, { addMenu = false; editing = DirectorySource(kind = DirKind.CARDDAV) }, leadingIcon = { Icon(Icons.Filled.Book, null) })
                    DropdownMenuItem({ Text("LDAP server…") }, { addMenu = false; editing = DirectorySource(kind = DirKind.LDAP) }, leadingIcon = { Icon(Icons.Filled.Dns, null) })
                    DropdownMenuItem({ Text("vCard link…") }, { addMenu = false; editing = DirectorySource(kind = DirKind.VCARD_LINK, interval = SyncInterval.ON_OPEN) }, leadingIcon = { Icon(Icons.Filled.Link, null) }) } } }
        }
    }
    editing?.let { src -> DirectoryEditor(src, { editing = null }) { saved -> editing = null; if (saved.enabled) activate(saved) } }
    pending?.let { p -> AlertDialog({ app.directories.update(p.id) { it.copy(enabled = false) }; pending = null }, containerColor = L1neColors.SheetBg, title = { Text("Replace imported contacts?") },
        text = { Text("Turning on a directory replaces importing from a vCard link. The contacts you imported from a link are removed and the directory's contacts take their place.") },
        confirmButton = { TextButton({ app.contacts.removeLinkImports(); app.directories.sources.value.filter { !it.isDirectory }.forEach { l -> app.contacts.deleteSource(l.tag); app.directories.update(l.id) { it.copy(enabled = false) } }; startSync(p); pending = null }) { Text("Replace and sync", color = L1neColors.Danger) } },
        dismissButton = { TextButton({ app.directories.update(p.id) { it.copy(enabled = false) }; pending = null }) { Text("Cancel") } }) }
    message?.let { m -> AlertDialog({ message = null }, containerColor = L1neColors.SheetBg, title = { Text("Sync") }, text = { Text(m) }, confirmButton = { TextButton({ message = null }) { Text("OK") } }) }
}

@Composable
private fun DirectoryEditor(initial: DirectorySource, onClose: () -> Unit, onSave: (DirectorySource) -> Unit) {
    val app = LocalApp.current; val scope = rememberCoroutineScope(); val accounts by app.store.accounts.collectAsState()
    val isNew = app.directories.sources.value.none { it.id == initial.id }
    var s by remember { mutableStateOf(initial) }; var password by remember { mutableStateOf("") }; var testing by remember { mutableStateOf(false) }; var testResult by remember { mutableStateOf<String?>(null) }
    @Composable fun F(t: String, v: String, ch: (String) -> Unit, kb: KeyboardType = KeyboardType.Text) = OutlinedTextField(v, ch, Modifier.fillMaxWidth(), singleLine = true, label = { Text(t) }, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = kb, autoCorrectEnabled = false))
    @Composable fun Pick(label: String, value: String, options: List<Pair<String, () -> Unit>>) { var m by remember { mutableStateOf(false) }
        Box { AssistChip({ m = true }, label = { Text("$label: $value") }, trailingIcon = { Icon(Icons.Filled.ExpandMore, null) }); DropdownMenu(m, { m = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) { options.forEach { (n, a) -> DropdownMenuItem({ Text(n) }, { a(); m = false }) } } } }
    AlertDialog(onClose, containerColor = L1neColors.SheetBg, title = { Text(when (s.kind) { DirKind.LDAP -> "LDAP server"; DirKind.CARDDAV -> "CardDAV address book"; else -> "vCard link" }) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            F(if (s.kind == DirKind.LDAP) "Name, e.g. Company directory" else "Name, e.g. Contacts", s.name, { s = s.copy(name = it) })
            when (s.kind) {
                DirKind.VCARD_LINK -> { F("https://…/contacts.vcf", s.url, { s = s.copy(url = it) }, KeyboardType.Uri); Text("A link to a .vcf file with your contacts, like the contact link a PBX setup file brings. L1ne keeps your contacts in step with it. Only entries with a SIP address are kept.", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
                DirKind.CARDDAV -> { F("Address book URL", s.url, { s = s.copy(url = it) }, KeyboardType.Uri); F("User name", s.username, { s = s.copy(username = it) }); OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), singleLine = true, label = { Text(if (isNew) "Password" else "Password (leave empty to keep)") }, visualTransformation = PasswordVisualTransformation()) }
                DirKind.LDAP -> { F("Host", s.host, { s = s.copy(host = it) }, KeyboardType.Uri); F("Port", s.port.toString(), { s = s.copy(port = it.filter(Char::isDigit).toIntOrNull() ?: 0) }, KeyboardType.Number)
                    Pick("Security", s.security.label, LdapSecurity.entries.map { it.label to { s = s.copy(security = it) } }); F("Bind DN (empty = anonymous)", s.bindDN, { s = s.copy(bindDN = it) })
                    OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation())
                    F("Base DN", s.baseDN, { s = s.copy(baseDN = it) }); F("Filter", s.filter, { s = s.copy(filter = it) }); F("Name attribute", s.nameAttr, { s = s.copy(nameAttr = it) }); F("SIP address attribute", s.sipAttr, { s = s.copy(sipAttr = it) })
                    SwitchRow("Use phone number as extension", s.phoneAsExtension) { s = s.copy(phoneAsExtension = it) }; if (s.phoneAsExtension) F("Phone attribute", s.phoneAttr, { s = s.copy(phoneAttr = it) }) }
            }
            Pick("Sync", s.interval.label, SyncInterval.entries.map { it.label to { s = s.copy(interval = it) } })
            if (accounts.size > 1) Pick("PBX", accounts.firstOrNull { it.id == s.accountID }?.title ?: "First account", accounts.map { it.title to { s = s.copy(accountID = it.id) } })
            testResult?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            TextButton({ testing = true; scope.launch { testResult = app.dirSync.test(s, password.ifEmpty { app.directories.password(s.id) }); testing = false } }, enabled = !testing) { Text(if (testing) "Testing…" else "Test connection") }
        } },
        confirmButton = { TextButton({ app.directories.save(s, password.ifEmpty { null }); onSave(s) }, enabled = (if (s.kind == DirKind.LDAP) s.host.isNotBlank() && s.baseDN.isNotBlank() else s.url.isNotBlank())) { Text("Save") } },
        dismissButton = { TextButton(onClose) { Text("Cancel") } })
}
