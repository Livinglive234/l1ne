package com.livenet.l1ne.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMade
import androidx.compose.material.icons.automirrored.filled.CallReceived
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.data.CallRecord
import com.livenet.l1ne.data.Direction
import java.text.DateFormat
import java.util.*

/** Recents: the iPhone-style list. Name (red if missed), direction arrow with "Today | 12:37 PM", then "Missed" / length / line. */
@Composable
fun RecentsScreen(open: (Dest) -> Unit) {
    val app = LocalApp.current
    val records by app.callLog.records.collectAsState()
    val contacts by app.contacts.contacts.collectAsState()
    val accounts by app.store.accounts.collectAsState()
    var missedOnly by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }

    /** A contact's name, else the name the caller sent (caller ID), else the number. The number goes underneath whenever the title is a name. */
    fun userOf(r: CallRecord) = r.peer.substringBefore('@')
    fun nameOf(r: CallRecord): String = app.contacts.name(userOf(r), r.peer.substringAfter('@', "")) ?: r.callerName.takeIf { it.isNotBlank() }?.let { com.livenet.l1ne.core.PhoneFormat.pretty(it) } ?: app.contacts.nameOrNumber(r.peer)
    fun numberOf(r: CallRecord): String? = com.livenet.l1ne.core.PhoneFormat.pretty(userOf(r)).takeIf { it != nameOf(r) }
    // `contacts` (collected above) is what makes the names refresh; the list is only rebuilt when something it depends on changes
    val shown = remember(records, contacts, search, missedOnly) { records.filter { (!missedOnly || it.direction == Direction.MISSED) && (search.isEmpty() || nameOf(it).contains(search, true) || it.peer.contains(search, true) || it.callerName.contains(search, true)) } }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(search, { search = it }, Modifier.weight(1f), singleLine = true, placeholder = { Text("Search") },
                leadingIcon = { Icon(Icons.Filled.Search, null) }, shape = MaterialTheme.shapes.extraLarge)
            Box {
                IconButton({ menu = true }) { Icon(Icons.Filled.FilterList, "Filter") }
                DropdownMenu(menu, { menu = false }, shape = MaterialTheme.shapes.extraLarge, containerColor = L1neColors.Surface) {
                    DropdownMenuItem({ Text("All") }, { missedOnly = false; menu = false }, leadingIcon = { Icon(Icons.Filled.Phone, null) }, trailingIcon = { if (!missedOnly) Icon(Icons.Filled.Check, null) })
                    DropdownMenuItem({ Text("Missed") }, { missedOnly = true; menu = false }, leadingIcon = { Icon(Icons.Filled.PhoneMissed, null) }, trailingIcon = { if (missedOnly) Icon(Icons.Filled.Check, null) })
                    HorizontalDivider(color = L1neColors.Border)
                    DropdownMenuItem({ Text("Delete all calls", color = L1neColors.Danger) }, { menu = false; confirm = true }, enabled = records.isNotEmpty(), leadingIcon = { Icon(Icons.Filled.Delete, null, tint = L1neColors.Danger) })
                }
            }
        }
        if (shown.isEmpty()) {
            EmptyState(Icons.Filled.History, if (missedOnly) "No missed calls" else "No recent calls", modifier = Modifier.fillMaxSize())
        } else {
        // A call that is placed or received while you are at the top of the list moves you to the top again (the list otherwise keeps the old first row in view)
        val listState = androidx.compose.foundation.lazy.rememberLazyListState()
        LaunchedEffect(shown.firstOrNull()?.id) { if (listState.firstVisibleItemIndex == 1 && listState.firstVisibleItemScrollOffset == 0) listState.scrollToItem(0) }
        LazyColumn(Modifier.fillMaxSize(), state = listState) {
            items(shown, key = { it.id }) { r ->
                SwipeToDelete({ app.callLog.delete(r.id) }) {
                val name = nameOf(r); val missed = r.direction == Direction.MISSED
                Row(Modifier.fillMaxWidth().clickable { open(Dest.Person(PersonTarget(name, r.peer, r.accountID))) }.padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Avatar(48.dp, initialsOf(name)); Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(name, Modifier.weight(1f, fill = false), fontWeight = FontWeight.Medium, color = if (missed) L1neColors.Danger else L1neColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (r.security.isNotEmpty()) { Spacer(Modifier.width(6.dp)); Icon(if (r.security.endsWith("verified")) Icons.Filled.Verified else Icons.Filled.Lock, if (r.security.endsWith("verified")) "Encrypted, code verified" else "Encrypted", Modifier.size(14.dp), tint = L1neColors.Brand) }
                        }
                        numberOf(r)?.let { Text(it, color = L1neColors.Muted, style = MaterialTheme.typography.bodyMedium, maxLines = 1) }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (r.direction == Direction.OUTGOING) Icons.AutoMirrored.Filled.CallMade else Icons.AutoMirrored.Filled.CallReceived, null, Modifier.size(13.dp), tint = L1neColors.Muted)
                            Spacer(Modifier.width(4.dp)); Text(whenText(r.date), color = L1neColors.Muted, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                        }
                        Text(details(r, accounts), style = MaterialTheme.typography.bodySmall, color = if (missed) L1neColors.Danger.copy(alpha = 0.85f) else L1neColors.Muted)
                    }
                    CallCircleButton { callBack(app, r) }
                }
                RowDivider()
                }
            }
        }
        }
    }
    if (confirm) AlertDialog({ confirm = false }, title = { Text("Delete all recent calls?") }, containerColor = L1neColors.SheetBg,
        confirmButton = { TextButton({ app.callLog.removeAll(); confirm = false }) { Text("Delete all", color = L1neColors.Danger) } }, dismissButton = { TextButton({ confirm = false }) { Text("Cancel") } })
}

fun callBack(app: com.livenet.l1ne.L1neApplication, r: CallRecord) {
    val acc = app.store.account(r.accountID)
    app.engine.call(r.peer, acc)
}

/** "Today | 12:37 PM", "Yesterday | 9:10 PM", "11/13 | 10:41 AM" */
fun whenText(ms: Long): String {
    val d = Calendar.getInstance().apply { timeInMillis = ms }; val now = Calendar.getInstance()
    fun same(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
    val yest = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
    val day = when { same(d, now) -> "Today"; same(d, yest) -> "Yesterday"; else -> "${d.get(Calendar.MONTH) + 1}/${d.get(Calendar.DAY_OF_MONTH)}" }
    return "$day | ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))}"
}

private fun details(r: CallRecord, accounts: List<com.livenet.l1ne.core.Account>): String {
    val parts = ArrayList<String>()
    when { r.direction == Direction.MISSED -> parts.add("Missed"); r.duration > 0 -> parts.add("%d:%02d".format(r.duration / 60, r.duration % 60))
        else -> parts.add(if (r.direction == Direction.OUTGOING) "Not answered" else "Declined") }
    accountTitle(accounts, r.accountID)?.let { parts.add(it) }
    return parts.joinToString(" · ")
}
