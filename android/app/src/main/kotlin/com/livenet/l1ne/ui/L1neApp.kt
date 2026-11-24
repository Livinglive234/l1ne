package com.livenet.l1ne.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private enum class Tab(val label: String, val icon: ImageVector) {
    Recents("Recents", Icons.Filled.History),
    Contacts("Contacts", Icons.Filled.People),
    Conversations("Conversations", Icons.AutoMirrored.Filled.Chat),
    Keypad("Keypad", Icons.Filled.Dialpad),
}

/** Same three tabs as iOS; accounts live behind the avatar at the top left (like iMessage). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun L1neApp(store: com.livenet.l1ne.data.AccountStore, engine: com.livenet.l1ne.sip.SipEngine) {
    val calls by engine.calls.collectAsState()
    var tab by remember { mutableStateOf(Tab.Recents) }
    var menu by remember { mutableStateOf(false) }
    var showAccounts by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = L1neColors.Bg,
        topBar = {
            TopAppBar(
                title = { if (tab != Tab.Keypad) Text(tab.label) },
                navigationIcon = {
                    Box {
                        IconButton({ menu = true }) { Avatar(36.dp) }
                        AccountMenu(menu, { menu = false },
                            onAccounts = { menu = false; showAccounts = true },
                            onSettings = { menu = false; showSettings = true })
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = L1neColors.Bg),
            )
        },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach {
                    NavigationBarItem(selected = tab == it, onClick = { tab = it },
                        icon = { Icon(it.icon, it.label) }, label = { Text(it.label) })
                }
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (tab) {
                Tab.Conversations -> Placeholder("No conversations", Icons.AutoMirrored.Filled.Chat,
                    "Texts need a server that supports SIP messages.")
                Tab.Keypad -> KeypadScreen { engine.call(it) }
                Tab.Recents -> Placeholder("No recent calls", Icons.Filled.History)
                Tab.Contacts -> Placeholder("No contacts", Icons.Filled.People,
                    "Contacts live only in L1ne. It never reads your phone's contacts and never fetches a list by itself.")
            }
        }
    }

    if (showAccounts) AccountsSheet(store, engine, onDismiss = { showAccounts = false })
    calls.firstOrNull()?.let { CallScreen(it, engine) }
    if (showSettings) SettingsSheet(onDismiss = { showSettings = false })
}

/** Round profile picture: a person glyph in the brand green. */
@Composable
private fun Avatar(size: Dp) {
    Box(
        Modifier.size(size).clip(CircleShape).background(L1neColors.Brand.copy(alpha = 0.18f))
            .border(1.dp, L1neColors.Brand.copy(alpha = 0.6f), CircleShape),
        contentAlignment = Alignment.Center,
    ) { Icon(Icons.Filled.Person, "Accounts and settings", Modifier.size(size * 0.55f), tint = L1neColors.Brand) }
}

/** Popup under the avatar, like the profile menu in Messages: "Accounts" with the avatar, then "Settings". */
@Composable
private fun AccountMenu(expanded: Boolean, onDismiss: () -> Unit, onAccounts: () -> Unit, onSettings: () -> Unit) {
    DropdownMenu(expanded, onDismiss, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface,
        modifier = Modifier.width(260.dp)) {
        Row(Modifier.fillMaxWidth().clickable(onClick = onAccounts).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Avatar(44.dp)
            Text("Accounts", style = MaterialTheme.typography.titleMedium)
        }
        HorizontalDivider(color = L1neColors.Border)
        DropdownMenuItem(
            text = { Text("Settings", modifier = Modifier.padding(start = 6.dp)) },
            leadingIcon = { Icon(Icons.Filled.Settings, null, Modifier.width(44.dp)) },
            onClick = onSettings,
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSheet(onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = L1neColors.SheetBg) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            Text("Settings", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 8.dp, bottom = 12.dp))
            Column(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.large).background(L1neColors.Surface).padding(16.dp)) {
                Text("Privacy", style = MaterialTheme.typography.labelLarge, color = L1neColors.Muted)
                Text("L1ne has no access to your phone's contacts, and it never fetches a contact list by itself.",
                    color = L1neColors.Muted, modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

@Composable
private fun KeypadScreen(onCall: (String) -> Unit) {
    var number by remember { mutableStateOf("") }
    val keys = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("*", "0", "#"))
    Column(Modifier.fillMaxSize().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(number.ifEmpty { " " }, fontSize = 34.sp, fontWeight = FontWeight.Light, modifier = Modifier.height(48.dp))
        Spacer(Modifier.height(24.dp))
        keys.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                row.forEach { k ->
                    RoundButton(L1neColors.Surface, { number += k }, border = BorderStroke(1.dp, L1neColors.Border)) {
                        Text(k, fontSize = 28.sp, fontWeight = FontWeight.Light)
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.size(76.dp))
            RoundButton(L1neColors.Brand, { onCall(number); number = "" }, enabled = number.isNotEmpty()) {
                Icon(Icons.Filled.Call, "Call", tint = L1neColors.OnBrand)
            }
            Box(Modifier.size(76.dp), contentAlignment = Alignment.Center) {
                if (number.isNotEmpty()) IconButton({ number = number.dropLast(1) }) { Icon(Icons.AutoMirrored.Filled.Backspace, "Delete") }
            }
        }
    }
}

@Composable
private fun RoundButton(color: Color, onClick: () -> Unit, enabled: Boolean = true, border: BorderStroke? = null, content: @Composable () -> Unit) {
    var m = Modifier.size(76.dp).clip(CircleShape).background(if (enabled) color else L1neColors.BrandDim.copy(alpha = 0.5f))
    if (border != null) m = m.border(border, CircleShape)
    Box(m.clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) { content() }
}

@Composable
private fun Placeholder(title: String, icon: ImageVector, note: String? = null) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, Modifier.size(56.dp), tint = L1neColors.Muted)
        Spacer(Modifier.height(12.dp))
        Text(title, style = MaterialTheme.typography.titleLarge)
        if (note != null) Text(note, color = L1neColors.Muted, modifier = Modifier.padding(top = 8.dp))
    }
}
