package com.livenet.l1ne.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.livenet.l1ne.data.Contact
import java.text.Normalizer

/** Phone-keypad letters, so "5673" finds "Jordan". */
object T9 {
    private val map: Map<Char, Char> = buildMap { mapOf('2' to "abc", '3' to "def", '4' to "ghi", '5' to "jkl", '6' to "mno", '7' to "pqrs", '8' to "tuv", '9' to "wxyz").forEach { (d, ls) -> ls.forEach { put(it, d) } } }
    fun digits(text: String): String = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD).mapNotNull { c -> if (c.isDigit()) c else map[c] }.joinToString("")
    /** True when the typed digits start a word of the name, the whole name, or the extension. */
    fun matches(typed: String, name: String, address: String): Boolean {
        if (typed.isEmpty() || !typed.all { it.isDigit() }) return false
        if (name.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.any { digits(it).startsWith(typed) }) return true
        if (digits(name.filter { it.isLetterOrDigit() }).startsWith(typed)) return true
        return address.substringBefore('@').startsWith(typed)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun KeypadScreen(open: (Dest) -> Unit, wide: Boolean = false) {
    val app = LocalApp.current
    val accounts by app.store.accounts.collectAsState()
    val selectedId by app.store.selectedId.collectAsState()
    val contacts by app.contacts.contacts.collectAsState()
    val vmKeypad by app.settings.vmKeypadF.collectAsState()
    var number by remember { mutableStateOf("") }
    val pending by app.pendingDial.collectAsState()
    LaunchedEffect(pending) { pending?.let { number = it; app.pendingDial.value = null } }
    var lineMenu by remember { mutableStateOf(false) }
    val account = app.store.selected
    val matches = contacts.filter { T9.matches(number, it.name, it.address) }
    val suggestions = if (wide) emptyList() else matches.take(2)       // wide: the matches are listed beside the keys instead
    val records by app.callLog.records.collectAsState()
    val keys = listOf(listOf("1" to "", "2" to "ABC", "3" to "DEF"), listOf("4" to "GHI", "5" to "JKL", "6" to "MNO"), listOf("7" to "PQRS", "8" to "TUV", "9" to "WXYZ"), listOf("*" to "", "0" to "+", "#" to ""))

    fun dial(n: String, from: com.livenet.l1ne.core.Account? = account) { if (n.isNotEmpty()) { app.engine.call(n, from); number = "" } }

    val windowDp = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp
    val padDp = keypadPaneWidthDp(windowDp)
    Row(Modifier.fillMaxSize()) {
    Box(if (wide) Modifier.width(padDp.dp).fillMaxHeight() else Modifier.fillMaxSize()) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
    // everything scales from the room there is: short phones get smaller keys and a slimmer suggestion area (so the call button is never pushed off screen), tablets get bigger keys
    val compact = maxHeight < 560.dp
    val gap = if (compact) 8.dp else 14.dp
    val suggestionH = if (wide) 0.dp else if (compact) 56.dp else 112.dp
    val numberH = if (compact) 44.dp else 52.dp
    val fixedH = suggestionH.value + numberH.value + 8f + 5f * gap.value + 16f + (if (accounts.size > 1) 40f else 0f)
    val keySize = ((maxHeight.value - fixedH) / 5f).coerceIn(40f, if (maxHeight > 800.dp) 96f else 76f).dp
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (accounts.size > 1) Box(Modifier.padding(top = 4.dp)) {
            AssistChip({ lineMenu = true }, label = { Text(account?.title ?: "Line") }, trailingIcon = { Icon(Icons.Filled.ExpandMore, null) })
            DropdownMenu(lineMenu, { lineMenu = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) {
                accounts.forEach { a -> DropdownMenuItem({ Text(a.title) }, { app.store.select(a.id); lineMenu = false }, trailingIcon = { if (a.id == account?.id) Icon(Icons.Filled.Check, null) }) }
            }
        }
        Spacer(Modifier.weight(1f))
        Box(Modifier.height(suggestionH).fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {      // always reserved, so the keys never move
            Column(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.large).background(if (suggestions.isEmpty()) androidx.compose.ui.graphics.Color.Transparent else L1neColors.Surface)) {
                suggestions.forEachIndexed { i, c ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Row(Modifier.weight(1f).clickable { number = if (accounts.any { a -> c.address.endsWith("@" + a.domain, true) }) c.user else c.address }     // the name fills in the number
                            .padding(start = 16.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Avatar(36.dp, initialsOf(c.name)); Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) { Text(c.name); Text(c.user, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
                        }
                        IconButton({ dial(c.user, accounts.firstOrNull { it.id == c.accountID } ?: account) }) { Icon(Icons.Filled.Call, "Call", tint = L1neColors.Brand) }     // the phone glyph calls right away
                    }
                    if (i == 0 && suggestions.size > 1) RowDivider()
                }
            }
        }
        Text(number.ifEmpty { " " }, fontSize = if (compact) 32.sp else 40.sp, fontWeight = FontWeight.Light, maxLines = 1, modifier = Modifier.height(numberH))
        Spacer(Modifier.height(8.dp))
        keys.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.padding(bottom = gap)) {
                row.forEach { (k, sub) ->
                    Box(Modifier.size(keySize).clip(CircleShape).background(L1neColors.Surface).border(1.dp, L1neColors.Border, CircleShape)
                        .combinedClickable(onClick = { number += k }, onLongClick = { if (k == "0") number += "+" }), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(k, fontSize = (keySize.value * 0.4f).coerceIn(20f, 38f).sp, fontWeight = FontWeight.Light)
                            if (sub.isNotEmpty() && keySize >= 52.dp) Text(sub, fontSize = 9.sp, color = L1neColors.Muted, letterSpacing = 1.5.sp)
                        }
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp), verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 16.dp)) {
            Box(Modifier.size(keySize), contentAlignment = Alignment.Center) {
                if (vmKeypad && account?.voicemailTarget != null) IconButton({ account.voicemailTarget?.let { t -> app.engine.callUri(t, account) } }) {
                    Icon(Icons.Filled.Voicemail, "Voicemail", tint = L1neColors.Brand) }
            }
            Box(Modifier.size(keySize).clip(CircleShape).background(if (number.isEmpty()) L1neColors.BrandDim.copy(alpha = 0.5f) else L1neColors.Brand).clickable(enabled = number.isNotEmpty()) { dial(number) },
                contentAlignment = Alignment.Center) { Icon(Icons.Filled.Call, "Call", tint = L1neColors.OnBrand) }
            Box(Modifier.size(keySize), contentAlignment = Alignment.Center) {
                if (number.isNotEmpty()) Box(Modifier.size(56.dp).clip(CircleShape).combinedClickable(onClick = { number = number.dropLast(1) }, onLongClick = { number = "" }), contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.Backspace, "Delete") }
            }
        }
    }
    }
    }
    if (wide) {
        VerticalDivider(color = L1neColors.Border)
        // the right side: contacts matching what is typed, or recent calls while the number is empty
        fun fill(address: String) { number = if (accounts.any { a -> address.endsWith("@" + a.domain, true) }) address.substringBefore('@') else address }
        LazyColumn(Modifier.weight(1f).fillMaxHeight()) {
            item { Text(if (number.isEmpty()) "Recent calls" else "Matching contacts", Modifier.padding(horizontal = 20.dp, vertical = 12.dp), color = L1neColors.Muted, style = MaterialTheme.typography.titleSmall) }
            if (number.isEmpty()) {
                items(records.take(20), key = { it.id }) { r ->
                    val p = r.peer.split("@"); val name = app.contacts.name(p[0], p.getOrNull(1)) ?: com.livenet.l1ne.core.PhoneFormat.pretty(p[0])
                    Row(Modifier.fillMaxWidth().clickable { fill(r.peer) }.padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { Text(name, fontWeight = FontWeight.Medium, maxLines = 1); Text(r.peer, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted, maxLines = 1) }
                        CallCircleButton { callBack(app, r) }
                    }
                    HorizontalDivider(Modifier.padding(horizontal = 20.dp), color = L1neColors.Border)
                }
                if (records.isEmpty()) item { Text("No recent calls yet.", Modifier.padding(20.dp), color = L1neColors.Muted) }
            } else {
                items(matches, key = { it.id }) { c ->
                    Row(Modifier.fillMaxWidth().clickable { fill(c.address) }.padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { Text(c.name, fontWeight = FontWeight.Medium, maxLines = 1); Text(c.address, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted, maxLines = 1) }
                        CallCircleButton { dial(c.user, accounts.firstOrNull { it.id == c.accountID } ?: account) }
                    }
                    HorizontalDivider(Modifier.padding(horizontal = 20.dp), color = L1neColors.Border)
                }
                if (matches.isEmpty()) item { Text("No matches. Keep typing, or press call.", Modifier.padding(20.dp), color = L1neColors.Muted) }
            }
        }
    }
    }
}
