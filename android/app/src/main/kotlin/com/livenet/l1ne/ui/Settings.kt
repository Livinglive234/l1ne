package com.livenet.l1ne.ui

import android.media.MediaPlayer
import android.net.Uri
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Media
import com.livenet.l1ne.core.Transport
import com.livenet.l1ne.data.Appearance
import com.livenet.l1ne.sip.Native
import com.livenet.l1ne.sip.SipEngine
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SettingsScreen(open: (Dest) -> Unit, onBack: () -> Unit) {
    val app = LocalApp.current; val s = app.settings
    val appearance by s.appearanceF.collectAsState(); val autoRec by s.autoRecordF.collectAsState(); val wifi by s.wifiOnlyF.collectAsState(); val v6 by s.allowIPv6F.collectAsState()
    val vmTab by s.vmTabF.collectAsState(); val vmKey by s.vmKeypadF.collectAsState(); val vmNotify by s.vmNotifyF.collectAsState(); val prov by s.provisioningF.collectAsState()
    val contacts by app.contacts.contacts.collectAsState()
    val keepAlive by s.keepAliveF.collectAsState()
    val ctxPm = LocalContext.current
    val batteryOk = ctxPm.getSystemService(android.os.PowerManager::class.java).isIgnoringBatteryOptimizations(ctxPm.packageName)
    var confirmRemove by remember { mutableStateOf(false) }; var applying by remember { mutableStateOf(false) }; var showRecordings by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    val recordings = remember(showRecordings) { File(ctx.filesDir, "recordings").listFiles { f -> f.extension == "wav" }?.size ?: 0 }
    if (showRecordings) { RecordingsScreen { showRecordings = false }; return }
    BackHandler(onBack = onBack)
    PageScaffold("Settings", onBack) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            SectionHeader("Look")
            Card { Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Appearance")
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) { Appearance.entries.forEachIndexed { i, a -> SegmentedButton(appearance == a, { s.appearance = a }, SegmentedButtonDefaults.itemShape(i, Appearance.entries.size)) { Text(a.label) } } }
            } }

            SectionHeader("Calls")
            Card {
                SwitchRow("Automatically start recording calls", autoRec) { s.autoRecord = it }; RowDivider()
                NavRow("Advanced calls settings") { open(Dest.AdvancedCalls) }; RowDivider()
                NavRow("Recordings", if (recordings == 0) "None" else "$recordings") { showRecordings = true }
            }

            SectionHeader("Incoming calls")
            Card {
                SwitchRow("Stay connected in the background", keepAlive, subtitle = "Shows a small notification so calls can ring when L1ne is closed") { s.keepAlive = it; if (it) com.livenet.l1ne.sip.KeepAliveService.start(ctx) else com.livenet.l1ne.sip.KeepAliveService.stop(ctx) }; RowDivider()
                if (android.os.Build.VERSION.SDK_INT >= 34) {
                    val nm = ctxPm.getSystemService(android.app.NotificationManager::class.java)
                    NavRow("Show calls on the lock screen", if (nm.canUseFullScreenIntent()) "On" else "Off") {
                        ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, android.net.Uri.parse("package:${ctx.packageName}"))) }
                    RowDivider()
                }
                NavRow("Allow background activity", if (batteryOk) "On" else "Off", icon = Icons.Filled.BatteryChargingFull) {
                    ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:${ctx.packageName}"))) }
            }
            FooterText("Android pauses background apps to save battery. Turn on background activity so a call can wake L1ne when the phone has been idle. On Android 14 and later, \"Show calls on the lock screen\" must be on for an incoming call to light the screen and show Answer and Decline while the phone is locked.")

            SectionHeader("Network")
            Card { SwitchRow("Use only Wi-Fi networks", wifi) { s.wifiOnly = it; app.engine.registerAll() }; RowDivider(); SwitchRow("Allow IPv6", v6) { s.allowIPv6 = it } }
            FooterText("IPv6 changes apply the next time L1ne starts.")

            SectionHeader("Advanced")
            Card {
                OutlinedTextField(prov, { s.provisioningURL = it }, Modifier.fillMaxWidth().padding(12.dp), singleLine = true, label = { Text("Remote provisioning URL") }, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Uri))
                NavRow("Download & apply", icon = Icons.Filled.CloudDownload) { if (com.livenet.l1ne.core.Provisioning.configUrl(prov) != null) applying = true }
            }
            FooterText("Fetches a Linphone-style configuration file once, shows you what it contains, and adds the accounts you confirm.")

            SectionHeader("Voicemail")
            Card { SwitchRow("Voicemail tab", vmTab) { s.showVoicemailTab = it }; RowDivider(); SwitchRow("Voicemail button on keypad", vmKey) { s.showKeypadVoicemail = it }; RowDivider()
                SwitchRow("Notify me of new voicemail", vmNotify, enabled = false) { s.voicemailNotify = it } }
            FooterText("Notifications for new voicemail are planned for later. They need push, which L1ne doesn't have yet.")

            SectionHeader("Contacts")
            Card {
                NavRow("Contacts sync") { open(Dest.ContactsSync) }; RowDivider()
                Row(Modifier.padding(16.dp)) { Text("In L1ne", Modifier.weight(1f)); Text("${contacts.size}", color = L1neColors.Muted) }; RowDivider()
                NavRow("Remove all contacts from L1ne", icon = Icons.Filled.Delete, danger = true) { if (contacts.isNotEmpty()) confirmRemove = true }
            }

            SectionHeader("Privacy")
            Card { Row(Modifier.padding(16.dp)) { Icon(Icons.Filled.Lock, null, tint = L1neColors.Muted); Spacer(Modifier.width(12.dp))
                Text("L1ne has no access to your phone's contacts. Contacts arrive only through the imports and syncs you set up.", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) } }

            SectionHeader("About")
            Card { Row(Modifier.padding(16.dp)) { Text("Version", Modifier.weight(1f)); Text("1.0", color = L1neColors.Muted) }; RowDivider()
                Row(Modifier.padding(16.dp)) { Text("SIP engine", Modifier.weight(1f)); Text("PJSIP ${Native.nVersion()}", color = L1neColors.Muted) } }
        }
    }
    if (confirmRemove) AlertDialog({ confirmRemove = false }, containerColor = L1neColors.SheetBg, title = { Text("Remove all contacts from L1ne?") }, text = { Text("This only affects L1ne's own list, not your phone's contacts.") },
        confirmButton = { TextButton({ app.contacts.removeAll(); confirmRemove = false }) { Text("Remove all", color = L1neColors.Danger) } }, dismissButton = { TextButton({ confirmRemove = false }) { Text("Cancel") } })
    if (applying) LinkDialog(prov) { applying = false }
}

@Composable
fun AdvancedCallsScreen(onBack: () -> Unit) {
    val app = LocalApp.current; val s = app.settings
    val early by s.acceptEarlyMediaF.collectAsState(); val outEarly by s.outEarlyMediaF.collectAsState(); val order by s.codecOrderF.collectAsState(); val off by s.codecsOffF.collectAsState()
    val codecs = remember(order) { app.engine.availableCodecs() }
    BackHandler(onBack = onBack)
    PageScaffold("Advanced calls settings", onBack) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            SectionHeader("Early media")
            Card { SwitchRow("Accept early media", early) { s.acceptEarlyMedia = it }; RowDivider(); SwitchRow("Allow outgoing early media", outEarly) { s.allowOutgoingEarlyMedia = it } }
            FooterText("Early media is audio the other side sends before the call is answered, such as a ringback tone or an announcement.")
            SectionHeader("Ringback tone")
            Card {
                val tone by s.ringbackF.collectAsState()
                com.livenet.l1ne.sip.RingbackTone.entries.forEachIndexed { i, t ->
                    Row(Modifier.fillMaxWidth().clickable { s.ringback = t; com.livenet.l1ne.sip.Ringback.preview(t) }.padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(t.label, Modifier.weight(1f)); if (tone == t) Icon(Icons.Filled.Check, null, tint = L1neColors.Brand) }
                    if (i < com.livenet.l1ne.sip.RingbackTone.entries.size - 1) RowDivider()
                }
            }
            FooterText("What you hear while the other phone is ringing. Most PBXes send no sound for that, so L1ne plays its own. Tap one to hear it.")
            SectionHeader("Audio codecs")
            Card {
                codecs.forEachIndexed { i, c ->
                    Row(Modifier.padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { Text(c.name, style = MaterialTheme.typography.titleMedium); Text(c.detail, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
                        IconButton({ if (i > 0) { val l = codecs.map { it.id }.toMutableList(); l.add(i - 1, l.removeAt(i)); s.codecOrder = l; app.engine.applyCodecs() } }, enabled = i > 0) { Icon(Icons.Filled.ArrowUpward, "Move up") }
                        IconButton({ if (i < codecs.size - 1) { val l = codecs.map { it.id }.toMutableList(); l.add(i + 1, l.removeAt(i)); s.codecOrder = l; app.engine.applyCodecs() } }, enabled = i < codecs.size - 1) { Icon(Icons.Filled.ArrowDownward, "Move down") }
                        Switch(c.id !in off, { on -> s.codecsOff = if (on) off - c.id else off + c.id; app.engine.applyCodecs() }, Modifier.padding(end = 12.dp))
                    }
                    if (i < codecs.size - 1) RowDivider()
                }
            }
            FooterText("The codec at the top is offered first. Switch off any you don't want. Wideband G722 sounds best on most PBXes.")
        }
    }
}

@Composable
private fun RecordingsScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    var files by remember { mutableStateOf(File(ctx.filesDir, "recordings").listFiles { f -> f.extension == "wav" }?.sortedByDescending { it.name } ?: emptyList()) }
    var playing by remember { mutableStateOf<File?>(null) }; var player by remember { mutableStateOf<MediaPlayer?>(null) }
    DisposableEffect(Unit) { onDispose { player?.release() } }
    BackHandler(onBack = onBack)
    PageScaffold("Recordings", onBack) { pad ->
        if (files.isEmpty()) Column(Modifier.padding(pad).fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Icons.Filled.GraphicEq, null, Modifier.size(56.dp), tint = L1neColors.Muted); Spacer(Modifier.height(12.dp)); Text("No recordings", style = MaterialTheme.typography.titleLarge)
            Text("Record a call with the Record button while you're on it, or turn on automatic recording in Settings. Check your local laws about telling people you record.", color = L1neColors.Muted, modifier = Modifier.padding(top = 8.dp))
        } else Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState())) {
            files.forEach { f ->
                Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton({ if (playing == f) { player?.stop(); player?.release(); player = null; playing = null } else { player?.release(); player = MediaPlayer().apply { setDataSource(f.path); prepare(); start(); setOnCompletionListener { playing = null } }; playing = f } }) {
                        Icon(if (playing == f) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle, null, Modifier.size(32.dp), tint = L1neColors.Brand) }
                    Column(Modifier.weight(1f)) { Text(java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(f.lastModified()))); Text(android.text.format.Formatter.formatShortFileSize(ctx, f.length()), style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
                    IconButton({ val uri = androidx.core.content.FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
                        ctx.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("audio/wav").putExtra(android.content.Intent.EXTRA_STREAM, uri).addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share recording")) }) { Icon(Icons.Filled.Share, "Share", tint = L1neColors.Brand) }
                    IconButton({ f.delete(); if (playing == f) { player?.release(); player = null; playing = null }; files = files - f }) { Icon(Icons.Filled.Delete, "Delete", tint = L1neColors.Muted) }
                }
                RowDivider()
            }
        }
    }
}

// MARK: Accounts

@Composable
fun AccountsScreen(open: (Dest) -> Unit, onBack: () -> Unit) {
    val app = LocalApp.current; val accounts by app.store.accounts.collectAsState(); val reg by app.engine.registration.collectAsState(); val sel by app.store.selectedId.collectAsState()
    val addAccount = LocalAddAccount.current
    BackHandler(onBack = onBack)
    PageScaffold("Accounts", onBack) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 8.dp)) {
            Card {
                accounts.forEach { a ->
                    val status = reg[a.id]; val ok = status == "Registered"; val chosen = (app.store.selected?.id == a.id)
                    Row(Modifier.fillMaxWidth().clickable { app.store.select(a.id) }.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (chosen) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, tint = if (chosen) L1neColors.Brand else L1neColors.Muted); Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(a.title); Text("${a.username}@${a.domain}", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Surface(shape = androidx.compose.foundation.shape.CircleShape, color = if (ok) L1neColors.Brand else if (status == null) L1neColors.Muted else L1neColors.Danger, modifier = Modifier.size(8.dp)) {}
                                Spacer(Modifier.width(6.dp)); Text(status ?: "Not registered", style = MaterialTheme.typography.labelSmall, color = L1neColors.Muted, maxLines = 1)
                            }
                        }
                        IconButton({ open(Dest.Account(a.id)) }) { Icon(Icons.Filled.Info, "Details", tint = L1neColors.Brand) }
                    }
                    RowDivider()
                }
                NavRow("Add account", icon = Icons.Filled.AddCircle) { addAccount() }
            }
        }
    }
}

private val countries = listOf("United States / Canada" to "1", "United Kingdom" to "44", "Australia" to "61", "New Zealand" to "64", "Ireland" to "353", "Germany" to "49", "France" to "33", "Spain" to "34", "Italy" to "39", "Netherlands" to "31",
    "Belgium" to "32", "Switzerland" to "41", "Austria" to "43", "Sweden" to "46", "Norway" to "47", "Denmark" to "45", "Finland" to "358", "Poland" to "48", "Portugal" to "351", "Czechia" to "420", "Greece" to "30", "Turkey" to "90",
    "Israel" to "972", "India" to "91", "Japan" to "81", "South Korea" to "82", "China" to "86", "Singapore" to "65", "Hong Kong" to "852", "Philippines" to "63", "Mexico" to "52", "Brazil" to "55", "Argentina" to "54",
    "Chile" to "56", "Colombia" to "57", "South Africa" to "27", "Nigeria" to "234", "Egypt" to "20", "UAE" to "971")

/** New account: the short form. Existing account: "Manage account" with everything. */
@Composable
fun AccountEditorScreen(id: String?, onSubmit: ((Account, String) -> Unit)? = null, onBack: () -> Unit) {
    val app = LocalApp.current; val ctx = LocalContext.current
    val existing = id?.let { i -> app.store.accounts.value.firstOrNull { it.id == i } }
    val isNew = existing == null
    var a by remember { mutableStateOf(existing ?: Account()) }
    var secret by remember { mutableStateOf("") }; var turnSecret by remember { mutableStateOf("") }
    var server by remember { mutableStateOf(if (isNew) "" else a.domain) }
    var confirmRemove by remember { mutableStateOf(false) }
    val reg by app.engine.registration.collectAsState(); val checks by app.engine.messagingCheck.collectAsState()
    BackHandler(onBack = onBack)

    fun field(title: String, v: String, ch: (String) -> Unit, kb: KeyboardType = KeyboardType.Text, modifier: Modifier = Modifier.fillMaxWidth()) =
        @Composable { OutlinedTextField(v, ch, modifier.padding(horizontal = 12.dp, vertical = 4.dp), singleLine = true, label = { Text(title) }, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = kb, autoCorrectEnabled = false)) }
    @Composable fun Field(title: String, v: String, ch: (String) -> Unit, kb: KeyboardType = KeyboardType.Text) = field(title, v, ch, kb)()
    @Composable fun Secret(title: String, v: String, ch: (String) -> Unit) = OutlinedTextField(v, ch, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), singleLine = true, label = { Text(title) }, visualTransformation = PasswordVisualTransformation())
    @Composable fun Transports() = Row(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { Transport.entries.forEach { t -> FilterChip(a.transport == t, { a = a.withTransport(t) }, label = { Text(t.wire.uppercase()) }) } }

    fun save() {
        val acc = if (isNew) a.finishedNew(server) else a.withServer(a.domain)
        if (isNew && onSubmit != null) { onSubmit(acc, secret); onBack(); return }     // a new account is only kept once the PBX accepts the login (the welcome screen checks)
        app.store.save(acc, secret.ifEmpty { null }); if (turnSecret.isNotEmpty()) app.store.saveTurnSecret(acc.id, turnSecret)
        app.engine.register(acc); onBack()
    }

    PageScaffold(if (isNew) "Use a SIP account" else a.title.ifEmpty { "Account" }, onBack, actions = {
        if (!isNew) TextButton(::save, enabled = a.domain.isNotEmpty() && a.username.isNotEmpty()) { Text("Save") } }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(bottom = 32.dp)) {
            if (isNew) {
                Card { Field("Username / extension", a.username, { a = a.copy(username = it) }); Secret("Password", secret) { secret = it }
                    Field("Domain (e.g. pbx.example.com)", server, { server = it }, KeyboardType.Uri); Field("Display name", a.displayName, { a = a.copy(displayName = it) }); Transports() }
                FooterText("Add a port after the domain if your server doesn't use the standard one (5061 for TLS, 5060 for UDP and TCP), like pbx.example.com:5080.")
                Spacer(Modifier.height(12.dp))
                SectionHeader("Advanced options")
                Card { Field("Authentication ID (if different)", a.authUser, { a = a.copy(authUser = it) }); Field("Registrar URI", a.registrarURI, { a = a.copy(registrarURI = it) }, KeyboardType.Uri); Field("Outbound SIP proxy URI", a.outboundProxy, { a = a.copy(outboundProxy = it) }, KeyboardType.Uri) }
                Spacer(Modifier.height(16.dp))
                Button(::save, Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(52.dp), enabled = a.username.isNotEmpty() && secret.isNotEmpty() && server.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(containerColor = L1neColors.Brand, contentColor = L1neColors.OnBrand)) { Text("Login", fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold) }
            } else {
                SectionHeader("Details")
                Card {
                    if (a.username.isNotEmpty() && a.domain.isNotEmpty()) { Row(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) { Column(Modifier.weight(1f)) { Text("SIP address", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted); Text(a.sipAddress, maxLines = 2, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) }
                        IconButton({ (ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(android.content.ClipData.newPlainText("sip", a.sipAddress)) }) { Icon(Icons.Filled.ContentCopy, "Copy", tint = L1neColors.Brand) } }; RowDivider() }
                    Field("Label", a.label, { a = a.copy(label = it) }); Field("Display name (shown to people you call)", a.displayName, { a = a.copy(displayName = it) })
                    var cm by remember { mutableStateOf(false) }
                    Box { NavRow("International prefix", if (a.intlPrefix.isEmpty()) "No country code" else (countries.firstOrNull { it.second == a.intlPrefix }?.let { "${it.first} (+${it.second})" } ?: "+${a.intlPrefix}")) { cm = true }
                        DropdownMenu(cm, { cm = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) {
                            DropdownMenuItem({ Text("No country code") }, { a = a.copy(intlPrefix = ""); cm = false }); countries.forEach { (n, c) -> DropdownMenuItem({ Text("$n (+$c)") }, { a = a.copy(intlPrefix = c); cm = false }) } } }
                }
                Spacer(Modifier.height(12.dp)); Card { SwitchRow("Connected", a.enabled) { a = a.copy(enabled = it) } }
                FooterText(if (a.enabled) "This account is online, everybody can call you." else "This account is off. Calls to it won't ring here.")
                SectionHeader("Server")
                Card { Field("Server (e.g. pbx.example.com)", a.domain, { a = a.copy(domain = it) }, KeyboardType.Uri); Transports()
                    Field("Port", a.port.toString(), { a = a.copy(port = it.filter(Char::isDigit).toIntOrNull() ?: 0) }, KeyboardType.Number)
                    Field("Registrar URI (optional)", a.registrarURI, { a = a.copy(registrarURI = it) }, KeyboardType.Uri); Field("Outbound SIP proxy URI (optional)", a.outboundProxy, { a = a.copy(outboundProxy = it) }, KeyboardType.Uri)
                    Field("Expire (seconds)", a.expires.toString(), { a = a.copy(expires = it.filter(Char::isDigit).toIntOrNull() ?: 3600) }, KeyboardType.Number) }
                SectionHeader("Login")
                Card { Field("Username / extension", a.username, { a = a.copy(username = it) }); Secret("Secret (leave empty to keep)", secret) { secret = it }; Field("Authentication ID (if different)", a.authUser, { a = a.copy(authUser = it) }) }
                SectionHeader("Dialling")
                Card { Field("Strip prefix", a.dialStripPrefix, { a = a.copy(dialStripPrefix = it) }); Field("Add prefix", a.dialAddPrefix, { a = a.copy(dialAddPrefix = it) })
                    SwitchRow("Format phone numbers using international prefix", a.formatWithPrefix) { a = a.copy(formatWithPrefix = it) }; RowDivider()
                    SwitchRow("Replace + by 00 when formatting phone numbers", a.plusTo00) { a = a.copy(plusTo00 = it) } }
                FooterText("Extensions and codes like *97 are never changed; only long phone numbers get the country code.")
                SectionHeader("Messaging")
                Card { val c = checks[a.id] ?: SipEngine.MessagingCheck.UNKNOWN
                    Row(Modifier.padding(16.dp)) { Text("Server", Modifier.weight(1f)); when (c) {
                        SipEngine.MessagingCheck.WORKING -> Text("Delivers texts", color = L1neColors.Brand)
                        SipEngine.MessagingCheck.NOT_DELIVERED -> Text("Doesn't deliver", color = androidx.compose.ui.graphics.Color(0xFFFF9500))
                        SipEngine.MessagingCheck.CHECKING -> Text("Checking…", color = L1neColors.Muted); else -> Text("Not checked", color = L1neColors.Muted) } }; RowDivider()
                    NavRow("Check messaging", icon = Icons.Filled.Sms) { if (reg[a.id] == "Registered" && c != SipEngine.MessagingCheck.CHECKING) app.engine.checkMessaging(a.id) } }
                FooterText("Sends one hidden test text to this line itself and sees whether the server delivers it back. Nothing goes to anyone else and it isn't shown as a message. Some servers treat a text to an extension as a call to it, so you may hear a phone ring.")
                SectionHeader("Voicemail")
                Card { Field("Voicemail number or address", a.voicemailURI, { a = a.copy(voicemailURI = it) }); SwitchRow("Message waiting indicator (MWI)", a.mwiEnabled) { a = a.copy(mwiEnabled = it) } }
                FooterText("What to dial to reach your voicemail. PBXes differ: *97 on FreePBX, 8500 or *86 on others, or a full address like sip:voicemail@example.com. Leave it empty to hide the voicemail button.")
                SectionHeader("Media")
                Card { Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(a.media == Media.NONE, { a = a.copy(media = Media.NONE) }, label = { Text("None") }); FilterChip(a.media == Media.SRTP_SDES, { a = a.copy(media = Media.SRTP_SDES) }, label = { Text("SRTP") }); FilterChip(a.media == Media.SRTP_DTLS, { a = a.copy(media = Media.SRTP_DTLS) }, label = { Text("DTLS-SRTP") }) }
                    SwitchRow("Media encryption mandatory", a.mediaMandatory, enabled = a.media != Media.NONE) { a = a.copy(mediaMandatory = it) } }
                val bad = a.media == Media.SRTP_SDES && a.transport != Transport.TLS
                Text(if (bad) "SRTP sends its keys inside the call setup, so it only works over TLS. With UDP or TCP choose DTLS-SRTP or None." else "SRTP sends its keys inside the call setup, so it needs TLS. DTLS-SRTP negotiates keys in the media path.",
                    Modifier.padding(start = 32.dp, end = 32.dp, top = 6.dp), style = MaterialTheme.typography.bodySmall, color = if (bad) L1neColors.Danger else L1neColors.Muted)
                SectionHeader("NAT policy")
                Card { Field("STUN / TURN server (host:port)", a.stunServer, { a = a.copy(stunServer = it) }); SwitchRow("Enable ICE", a.iceEnabled) { a = a.copy(iceEnabled = it) }; RowDivider(); SwitchRow("Enable TURN", a.turnEnabled) { a = a.copy(turnEnabled = it) }
                    if (a.turnEnabled) { Field("TURN username", a.turnUser, { a = a.copy(turnUser = it) }); Secret("TURN password", turnSecret) { turnSecret = it } } }
                FooterText("L1ne uses one STUN server for all accounts: the first account that sets one.")
                Spacer(Modifier.height(16.dp)); Card { NavRow("Remove account", icon = Icons.Filled.Delete, danger = true) { confirmRemove = true } }
            }
        }
    }
    if (confirmRemove) AlertDialog({ confirmRemove = false }, containerColor = L1neColors.SheetBg, title = { Text("Remove ${a.title}?") }, text = { Text("Its chats and call history on this phone are deleted too.") },
        confirmButton = { TextButton({ app.engine.unregister(a.id); app.messages.removeAccount(a.id); app.callLog.removeAccount(a.id); app.store.remove(a.id); confirmRemove = false; onBack() }) { Text("Remove account", color = L1neColors.Danger) } }, dismissButton = { TextButton({ confirmRemove = false }) { Text("Cancel") } })
}

// MARK: Setup from a link or QR code

@Composable
fun LinkDialog(initial: String?, autoScan: Boolean = false, onClose: () -> Unit) {
    val app = LocalApp.current; val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf(initial ?: "") }; var busy by remember { mutableStateOf(false) }; var scanning by remember { mutableStateOf(autoScan) }; var error by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<com.livenet.l1ne.core.Provisioning.Result?>(null) }
    var picked by remember { mutableStateOf(setOf<String>()) }; var importContacts by remember { mutableStateOf(true) }; var secrets by remember { mutableStateOf(mapOf<String, String>()) }
    var interval by remember { mutableStateOf(com.livenet.l1ne.data.SyncInterval.ON_OPEN) }
    var checking by remember { mutableStateOf(false) }; var failures by remember { mutableStateOf(mapOf<String, String>()) }       // the PBX is being asked; why an account couldn't sign in
    fun fetch(raw: String) {
        val url = com.livenet.l1ne.core.Provisioning.configUrl(raw) ?: run { error = "That isn't an https configuration link."; return }
        busy = true; error = null
        scope.launch {
            runCatching { withContext(Dispatchers.IO) { com.livenet.l1ne.core.Provisioning.parse(java.net.URL(url.toString()).readBytes()) } }
                .onSuccess { r -> picked = r.selectedByDefault.map { it.account.id }.toSet(); importContacts = r.contactsUrl != null && !app.directories.directoryEnabled; result = r }
                .onFailure { error = it.message ?: "Could not fetch the file." }
            busy = false
        }
    }
    if (scanning) androidx.compose.ui.window.Dialog({ scanning = false; if (autoScan) onClose() }, androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) { QRScanner(onCode = { scanning = false; text = it; fetch(it) }, onCancel = { scanning = false; if (autoScan) onClose() }) }
    val r = result
    if (scanning) { /* the scanner is full screen: the link dialog would be drawn on top of it, so leave it out until scanning ends */ }
    else if (r == null) AlertDialog(onClose, containerColor = L1neColors.SheetBg, title = { Text("Set up from a link or QR code") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton({ scanning = true }, Modifier.fillMaxWidth()) { Icon(Icons.Filled.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan QR code") }
            Text("or paste the https link (or linphone-config: link) from your PBX setup file.", color = L1neColors.Muted)
            OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("https://…") }); error?.let { Text(it, color = MaterialTheme.colorScheme.error) } } },
        confirmButton = { TextButton(enabled = !busy && text.isNotBlank(), onClick = { fetch(text) }) { Text(if (busy) "Fetching…" else "Next") } }, dismissButton = { TextButton(onClose) { Text("Cancel") } })
    else AlertDialog(onClose, containerColor = L1neColors.SheetBg, title = { Text("Found in this file") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            r.accounts.forEach { p -> Row(Modifier.clickable { picked = if (p.account.id in picked) picked - p.account.id else picked + p.account.id }, verticalAlignment = Alignment.CenterVertically) {
                Checkbox(p.account.id in picked, { picked = if (it) picked + p.account.id else picked - p.account.id })
                Column { Text(p.account.title); Text("${p.account.username}@${p.account.domain}" + if (p.pushOnly) " · incoming only" else "", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
                    failures[p.account.id]?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = L1neColors.Danger) } } }
                if (p.secret.isEmpty() && p.account.id in picked) OutlinedTextField(secrets[p.account.id] ?: "", { secrets = secrets + (p.account.id to it) }, singleLine = true, label = { Text("Password for ${p.account.username}") }, visualTransformation = PasswordVisualTransformation()) }
            if (r.contactsUrl != null) { SwitchRow("Import contacts from ${java.net.URI(r.contactsUrl).host ?: "the link"}", importContacts, enabled = !app.directories.directoryEnabled) { importContacts = it }
                if (importContacts) Text("L1ne keeps your contacts in step with it. You can change this any time in Settings → Contacts sync.", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
            r.notes.forEach { Text(it, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) } } },
        confirmButton = { TextButton(enabled = picked.isNotEmpty() && !checking, onClick = {
            // Registers every chosen account first and keeps them only if all sign in, like the Welcome screen's own form.
            // If one doesn't, nothing is added and the dialog says why under that account.
            val chosen = r.accounts.filter { it.account.id in picked }
            fun secretOf(p: com.livenet.l1ne.core.Provisioning.Parsed) = p.secret.ifEmpty { secrets[p.account.id] ?: "" }
            checking = true; failures = emptyMap()
            scope.launch {
                val failed = chosen.map { p -> scope.async { p.account.id to verifyLogin(app.engine, p.account, secretOf(p)) } }.awaitAll().mapNotNull { (id, why) -> why?.let { id to it } }.toMap()
                checking = false
                if (failed.isNotEmpty()) { chosen.forEach { app.engine.unregister(it.account.id) }; failures = failed; return@launch }
                var first: Account? = null
                for (p in chosen) { var acc = p.account; if (r.contactsUrl != null && importContacts && (!p.pushOnly || !r.hasOtherThanPushOnly)) acc = acc.copy(contactsUrl = r.contactsUrl!!)
                    app.store.save(acc, secretOf(p)); if (first == null && (!p.pushOnly || !r.hasOtherThanPushOnly)) first = acc }       // already registered by the check above
                if (importContacts && !app.directories.directoryEnabled && r.contactsUrl != null) (first ?: app.store.selected)?.let { acc ->
                    val link = com.livenet.l1ne.data.DirectorySource(kind = com.livenet.l1ne.data.DirKind.VCARD_LINK, name = "PBX contacts", url = r.contactsUrl!!, interval = interval, accountID = acc.id)
                    app.directories.save(link, null); scope.launch { app.dirSync.sync(link.id) } }
                onClose()
            }
        }) { Text(if (checking) "Checking with the PBX…" else "Add") } }, dismissButton = { TextButton(onClose) { Text("Cancel") } })
}
