package com.livenet.l1ne.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private enum class Tab(val label: String, val icon: ImageVector) {
    Recents("Recents", Icons.Filled.History), Contacts("Contacts", Icons.Filled.People), Chats("Chats", Icons.AutoMirrored.Filled.Chat), Keypad("Keypad", Icons.Filled.Dialpad), Voicemail("Voicemail", Icons.Filled.Voicemail),
}

/** Until there is an account, the welcome screen is shown (it comes back if the last account is removed); after that, the tabs. */
@Composable
fun L1neApp() {
    val app = LocalApp.current
    val accounts by app.store.accounts.collectAsState()
    var signingIn by remember { mutableStateOf(false) }      // the welcome screen stays up while a first login is being checked
    var adding by remember { mutableStateOf(false) }         // "Add account" shows the same welcome screen on top of the tabs, so adding an account feels like the first one
    if (accounts.isEmpty()) adding = false
    if (accounts.isEmpty() || signingIn && !adding) WelcomeScreen(signingIn, { signingIn = it }) else Box {
        CompositionLocalProvider(LocalAddAccount provides { adding = true }) { MainTabs() }
        if (adding) Surface(Modifier.fillMaxSize().pointerInput(Unit) {}, color = L1neColors.Bg) { WelcomeScreen(signingIn, { signingIn = it }, onClose = { adding = false }) }
    }
}

/** Lets the Accounts screen open the welcome screen to add an account. */
val LocalAddAccount = staticCompositionLocalOf<() -> Unit> { {} }

/** Tabs like iOS: Recents, Contacts, Chats, Keypad, and an optional Voicemail tab. The avatar at the top left opens the profile menu. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainTabs() {
    val app = LocalApp.current
    val calls by app.engine.calls.collectAsState()
    val vmTab by app.settings.vmTabF.collectAsState(); val voicemail by app.engine.voicemail.collectAsState(); val convs by app.messages.conversations.collectAsState()
    val accounts by app.store.accounts.collectAsState(); val selId by app.store.selectedId.collectAsState()
    var tab by remember { mutableStateOf(Tab.Recents) }
    var menu by remember { mutableStateOf(false) }
    val stack = remember { mutableStateListOf<Dest>() }
    val tabs = Tab.entries.filter { it != Tab.Voicemail || vmTab }
    if (tab !in tabs) tab = Tab.Recents
    // wide windows (a tablet, an unfolded foldable, a landscape split): the list on the left and the person or conversation on the right
    val windowDp = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp
    val wide = useTwoPanes(windowDp)       // 700 dp or more. A folded, half open or unfolded foldable is treated by its width alone: half open looks exactly like open
    val listDp = listPaneWidthDp(windowDp)
    var pane by remember { mutableStateOf<Dest?>(null) }
    fun open(d: Dest) { if (wide && (d is Dest.Person || d is Dest.Thread)) pane = d else stack.add(d) }
    LaunchedEffect(tab) { pane = null }
    LaunchedEffect(wide) {       // the window changed width: the open person or conversation moves between the right pane and a page on top of the list
        if (!wide) pane?.let { stack.add(it); pane = null }
        else stack.lastOrNull()?.takeIf { it is Dest.Person || it is Dest.Thread }?.let { stack.removeAt(stack.lastIndex); pane = it }
    }
    fun back() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    var minimized by remember { mutableStateOf(false) }
    // On the lock screen only the call itself is shown: it can't be minimized to the app behind it, and locking the phone closes the app behind it.
    val lockCtx = androidx.compose.ui.platform.LocalContext.current
    fun locked() = (lockCtx.getSystemService(android.content.Context.KEYGUARD_SERVICE) as android.app.KeyguardManager).isKeyguardLocked
    androidx.compose.runtime.DisposableEffect(lockCtx) {
        val r = object : android.content.BroadcastReceiver() { override fun onReceive(c: android.content.Context?, i: android.content.Intent?) { minimized = false } }
        lockCtx.registerReceiver(r, android.content.IntentFilter(android.content.Intent.ACTION_SCREEN_OFF))
        onDispose { runCatching { lockCtx.unregisterReceiver(r) } }
    }
    val pendingDial by app.pendingDial.collectAsState()
    LaunchedEffect(pendingDial) { if (pendingDial != null) { tab = Tab.Keypad; stack.clear(); if (app.engine.currentCall != null) minimized = true } }
    val currentId by app.engine.currentId.collectAsState()
    // read both flows here, so this screen recomposes (and the call screen goes away) the moment the last call ends
    val live = if (calls.isEmpty()) null else calls.firstOrNull { it.id == currentId } ?: calls.firstOrNull { it.active } ?: calls.firstOrNull()
    LaunchedEffect(live?.id) { minimized = false }
    val unread = convs.sumOf { it.unread }; val newVoicemail = voicemail.values.sum()

    Column(Modifier.fillMaxSize().background(L1neColors.Bg)) {
    if (live != null && minimized) CallBar(live) { minimized = false }
    Box(Modifier.weight(1f).then(if (live != null && minimized) Modifier.consumeWindowInsets(WindowInsets.statusBars) else Modifier)) {
    Scaffold(
        containerColor = L1neColors.Bg,
        topBar = {
            TopAppBar(
                title = { if (tab != Tab.Keypad) Text(tab.label) },
                navigationIcon = {
                    Box {
                        IconButton({ menu = true }) { ProfileAvatar(36.dp, app.store.selected?.initials ?: "") }
                        ProfileMenu(menu, { menu = false }, onAccounts = { menu = false; open(Dest.Accounts) }, onSettings = { menu = false; open(Dest.Settings) })
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = L1neColors.Bg),
            )
        },
        bottomBar = {
            NavigationBar {
                tabs.forEach {
                    NavigationBarItem(selected = tab == it, onClick = { tab = it },
                        icon = { BadgedBox({ val n = if (it == Tab.Chats) unread else if (it == Tab.Voicemail) newVoicemail else 0; if (n > 0) Badge(containerColor = L1neColors.Brand) { Text("$n") } }) { Icon(it.icon, it.label) } },
                        label = { Text(it.label, maxLines = 1, fontSize = 11.sp) })
                }
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            if (wide && tab == Tab.Keypad) KeypadScreen(::open, wide = true)
            else if (wide && tab != Tab.Voicemail) Row(Modifier.fillMaxSize()) {
                Box(Modifier.width(listDp.dp).fillMaxHeight()) {
                    when (tab) {
                        Tab.Recents -> RecentsScreen(::open)
                        Tab.Contacts -> ContactsScreen(::open)
                        else -> ConversationsScreen(::open)
                    }
                }
                VerticalDivider(color = L1neColors.Border)
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    when (val d = pane) {
                        is Dest.Person -> key(d) { PersonScreen(d.p, ::open, null) }
                        is Dest.Thread -> key(d) { ThreadScreen(d.accountID, d.peer, ::open, null) }
                        else -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                            Icon(if (tab == Tab.Chats) Icons.Filled.Forum else Icons.Filled.Person, null, Modifier.size(56.dp), tint = L1neColors.Muted)
                            Spacer(Modifier.height(12.dp))
                            Text(if (tab == Tab.Chats) "No chat selected" else "Nobody selected", style = MaterialTheme.typography.titleLarge)
                            Text(if (tab == Tab.Chats) "Pick one on the left, or start a new message." else "Pick someone on the left.", color = L1neColors.Muted)
                        }
                    }
                }
            }
            else Box(Modifier.widthIn(max = 720.dp).fillMaxSize()) {       // on a tablet the lists keep a readable width instead of stretching edge to edge
                when (tab) {
                    Tab.Recents -> RecentsScreen(::open)
                    Tab.Contacts -> ContactsScreen(::open)
                    Tab.Chats -> ConversationsScreen(::open)
                    Tab.Keypad -> KeypadScreen(::open)
                    Tab.Voicemail -> VoicemailScreen()
                }
            }
        }
    }

    // full-screen pages on top of the tabs
    stack.lastOrNull()?.let { d ->
        BackHandler { back() }
        Surface(Modifier.fillMaxSize(), color = L1neColors.Bg) {
          Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) { Box(Modifier.widthIn(max = 720.dp).fillMaxSize()) {
            when (d) {
                is Dest.Person -> PersonScreen(d.p, ::open, ::back)
                is Dest.Thread -> ThreadScreen(d.accountID, d.peer, ::open, ::back)
                Dest.NewMessage -> { NewMessageDialog({ d2 -> back(); open(d2) }, ::back) }
                Dest.Settings -> SettingsScreen(::open, ::back)
                Dest.Accounts -> AccountsScreen(::open, ::back)
                is Dest.Account -> AccountEditorScreen(d.id, onBack = ::back)
                Dest.AdvancedCalls -> AdvancedCallsScreen(::back)
                Dest.ContactsSync -> ContactsSyncScreen(::back)
                Dest.Voicemail -> VoicemailScreen()
            }
          } }
        }
    }
    }
    }
    live?.let { CallScreen(it, app.engine, minimized, { m -> minimized = m && !locked() }, { d -> if (!locked()) open(d) }) }
}

/** Round profile picture: the initials of the selected account, or a person glyph until an account exists. */
@Composable
fun ProfileAvatar(size: Dp, initials: String) {
    Box(Modifier.size(size).clip(CircleShape).background(L1neColors.Brand.copy(alpha = 0.18f)).border(1.dp, L1neColors.Brand.copy(alpha = 0.6f), CircleShape), contentAlignment = Alignment.Center) {
        if (initials.isNotEmpty()) Text(initials, fontSize = (size.value * 0.4f).sp, fontWeight = FontWeight.SemiBold, color = L1neColors.Brand)
        else Icon(Icons.Filled.Person, "Accounts and settings", Modifier.size(size * 0.55f), tint = L1neColors.Brand)
    }
}

/** Popup under the avatar, like the profile menu in Messages: "Accounts", then "Settings". */
@Composable
private fun ProfileMenu(expanded: Boolean, onDismiss: () -> Unit, onAccounts: () -> Unit, onSettings: () -> Unit) {
    DropdownMenu(expanded, onDismiss, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface, modifier = Modifier.width(260.dp)) {
        DropdownMenuItem(text = { Text("Accounts", modifier = Modifier.padding(start = 6.dp)) }, leadingIcon = { Icon(Icons.Filled.AccountCircle, null, Modifier.width(44.dp)) }, onClick = onAccounts, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp))
        HorizontalDivider(color = L1neColors.Border)
        DropdownMenuItem(text = { Text("Settings", modifier = Modifier.padding(start = 6.dp)) }, leadingIcon = { Icon(Icons.Filled.Settings, null, Modifier.width(44.dp)) }, onClick = onSettings, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp))
    }
}
