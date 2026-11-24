package com.livenet.l1ne.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.livenet.l1ne.L1neApplication
import com.livenet.l1ne.core.Account as CoreAccount
import com.livenet.l1ne.core.Account

val LocalApp = compositionLocalOf<L1neApplication> { error("no app") }

/** A person to show: a name, a SIP address (user@domain) and the account that dials them. */
data class PersonTarget(val name: String, val address: String, val accountID: String?)

/** Where a full-screen page sits on top of the tabs. */
sealed interface Dest {
    data class Person(val p: PersonTarget) : Dest
    data class Thread(val accountID: String, val peer: String) : Dest
    data object NewMessage : Dest
    data object Settings : Dest
    data object Accounts : Dest
    data class Account(val id: String?) : Dest
    data object AdvancedCalls : Dest
    data object ContactsSync : Dest
    data object Voicemail : Dest
}

@Composable
fun Avatar(size: Dp, initials: String = "", bg: androidx.compose.ui.graphics.Color = L1neColors.Surface) {
    Box(Modifier.size(size).clip(CircleShape).background(bg), contentAlignment = Alignment.Center) {
        if (initials.isEmpty()) Icon(Icons.Filled.Person, null, Modifier.size(size * 0.5f), tint = L1neColors.Muted)
        else Text(initials, fontSize = (size.value * 0.36f).sp, fontWeight = FontWeight.SemiBold, color = L1neColors.Brand)
    }
}

fun initialsOf(name: String): String =
    if (name.firstOrNull()?.isLetter() == true) name.split(' ').filter { it.isNotEmpty() }.take(2).map { it.first() }.joinToString("").uppercase() else ""

/** The round green call button used in Recents, Contacts and Voicemail. */
@Composable
fun CallCircleButton(onClick: () -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).background(L1neColors.Brand.copy(alpha = 0.16f)).border(1.dp, L1neColors.Brand.copy(alpha = 0.5f), CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) { Icon(Icons.Filled.Call, "Call", Modifier.size(20.dp), tint = L1neColors.Brand) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PageScaffold(title: String, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}, content: @Composable (PaddingValues) -> Unit) {
    Scaffold(containerColor = L1neColors.Bg, topBar = {
        TopAppBar(title = { Text(title) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = actions, colors = TopAppBarDefaults.topAppBarColors(containerColor = L1neColors.Bg))
    }, content = content)
}

@Composable
fun SectionHeader(text: String) = Text(text, style = MaterialTheme.typography.labelLarge, color = L1neColors.Muted, modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 6.dp))

/** A rounded card holding rows, like a grouped list section on iOS. */
@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) =
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp).clip(MaterialTheme.shapes.large).background(L1neColors.Surface), content = content)

@Composable
fun FooterText(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted, modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 6.dp))

@Composable
fun SwitchRow(title: String, checked: Boolean, enabled: Boolean = true, subtitle: String? = null, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title); if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
        Switch(checked, onChange, enabled = enabled)
    }
}

@Composable
fun NavRow(title: String, value: String? = null, icon: ImageVector? = null, danger: Boolean = false, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, tint = if (danger) L1neColors.Danger else L1neColors.Brand); Spacer(Modifier.width(12.dp)) }
        Text(title, Modifier.weight(1f), color = if (danger) L1neColors.Danger else L1neColors.Text)
        if (value != null) Text(value, color = L1neColors.Muted)
        if (!danger && icon == null) Icon(Icons.Filled.ChevronRight, null, tint = L1neColors.Muted)
    }
}

@Composable fun RowDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = L1neColors.Border)

/** Names the account only when there is more than one, so a single-account phone never sees "which line" labels. */
fun accountTitle(accounts: List<CoreAccount>, id: String?) = if (accounts.size > 1) accounts.firstOrNull { it.id == id }?.title else null
