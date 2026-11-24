package com.livenet.l1ne.data

import android.content.Context
import com.livenet.l1ne.core.VCard
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Reads and writes one JSON file in the app's private storage (nothing leaves the phone). */
private class JsonFile(context: Context, name: String) {
    private val f = File(context.filesDir, name)
    fun read(): JSONArray = runCatching { JSONArray(f.readText()) }.getOrDefault(JSONArray())
    fun write(a: JSONArray) { val tmp = File(f.path + ".tmp"); tmp.writeText(a.toString()); tmp.renameTo(f) }
}

// MARK: Call log

enum class Direction { OUTGOING, INCOMING, MISSED }
data class CallRecord(val id: String = UUID.randomUUID().toString(), val date: Long = System.currentTimeMillis(), val peer: String,
                      val accountID: String?, val direction: Direction, val duration: Int)

class CallLogStore(context: Context) {
    private val file = JsonFile(context, "calllog.json")
    private val _records = MutableStateFlow(file.read().let { a -> (0 until a.length()).map { i -> a.getJSONObject(i).let { o ->
        CallRecord(o.getString("id"), o.getLong("date"), o.getString("peer"), o.optString("accountID").ifEmpty { null },
            Direction.valueOf(o.getString("direction")), o.optInt("duration")) } } })
    val records: StateFlow<List<CallRecord>> = _records
    private fun save() = file.write(JSONArray(_records.value.map { r -> JSONObject().put("id", r.id).put("date", r.date).put("peer", r.peer)
        .put("accountID", r.accountID ?: "").put("direction", r.direction.name).put("duration", r.duration) }))
    fun add(r: CallRecord) { _records.value = (listOf(r) + _records.value).take(500); save() }
    fun delete(id: String) { _records.value = _records.value.filter { it.id != id }; save() }
    fun removeAll() { _records.value = emptyList(); save() }
    fun removeAccount(id: String) { _records.value = _records.value.filter { it.accountID != id }; save() }
}

// MARK: Contacts

data class Contact(val id: String = UUID.randomUUID().toString(), val name: String, val address: String, val accountID: String? = null,
                   val imported: Boolean = false, val source: String? = null) {
    val user: String get() = address.substringBefore('@')
}
data class ImportSummary(var added: Int = 0, var updated: Int = 0, var kept: Int = 0, var skipped: Int = 0, var removed: Int = 0)

/** L1ne's own address book: never reads the phone's contacts, never fetches by itself, only holds entries with a SIP address. */
class ContactsStore(context: Context) {
    private val file = JsonFile(context, "contacts.json")
    private val _contacts = MutableStateFlow(file.read().let { a -> (0 until a.length()).map { i -> a.getJSONObject(i).let { o ->
        Contact(o.getString("id"), o.getString("name"), o.getString("address"), o.optString("accountID").ifEmpty { null }, o.optBoolean("imported"), o.optString("source").ifEmpty { null }) } } })
    val contacts: StateFlow<List<Contact>> = _contacts
    private fun commit(l: List<Contact>) { _contacts.value = l.sortedBy { it.name.lowercase() }
        file.write(JSONArray(_contacts.value.map { c -> JSONObject().put("id", c.id).put("name", c.name).put("address", c.address)
            .put("accountID", c.accountID ?: "").put("imported", c.imported).put("source", c.source ?: "") })) }

    /** Entries you typed in win over imported ones with the same address; an import only renames earlier imports. */
    fun merge(result: VCard.Result, account: String?, source: String = "link"): ImportSummary {
        val s = ImportSummary(skipped = result.skipped); val list = _contacts.value.toMutableList()
        for (e in result.entries) {
            val i = list.indexOfFirst { it.address.equals(e.address, true) }
            if (i >= 0) { if (list[i].imported && list[i].name != e.name) { list[i] = list[i].copy(name = e.name); s.updated++ } else s.kept++ }
            else { list.add(Contact(name = e.name, address = e.address, accountID = account, imported = true, source = source)); s.added++ }
        }
        commit(list); return s
    }
    /** Makes one synced directory's contacts match it exactly (new added, renamed, gone removed); others' entries are never touched. */
    fun replaceSource(tag: String, result: VCard.Result, account: String?): ImportSummary {
        val s = ImportSummary(skipped = result.skipped); val wanted = result.entries.associateBy { it.address.lowercase() }
        val list = _contacts.value.toMutableList(); val before = list.size
        list.removeAll { it.source == tag && wanted[it.address.lowercase()] == null }; s.removed = before - list.size
        for ((addr, e) in wanted) {
            val i = list.indexOfFirst { it.address.lowercase() == addr }
            if (i >= 0) { if (list[i].source == tag && list[i].name != e.name) { list[i] = list[i].copy(name = e.name); s.updated++ } else s.kept++ }
            else { list.add(Contact(name = e.name, address = e.address, accountID = account, imported = true, source = tag)); s.added++ }
        }
        commit(list); return s
    }
    fun removeLinkImports(): Int { val n = _contacts.value.size; commit(_contacts.value.filterNot { it.imported && (it.source == null || it.source == "link") }); return n - _contacts.value.size }
    fun deleteSource(tag: String) = commit(_contacts.value.filter { it.source != tag })
    val hasLinkImports get() = _contacts.value.any { it.imported && (it.source == null || it.source == "link") }
    fun add(name: String, address: String, account: String?): Boolean {
        val a = VCard.sipAddress("sip:" + address.replace("sip:", "")) ?: return false
        commit(_contacts.value + Contact(name = name.ifEmpty { a }, address = a, accountID = account)); return true
    }
    fun update(c: Contact) = commit(_contacts.value.map { if (it.id == c.id) c else it })
    fun remove(id: String) = commit(_contacts.value.filter { it.id != id })
    fun removeAll() = commit(emptyList())

    /** Who a call was with: same extension on the same server; the same extension anywhere (if only one contact has it); a number by its last ten digits. */
    fun name(rawUser: String, rawDomain: String? = null): String? {
        val user = rawUser.lowercase().removePrefix("sip:"); val domain = rawDomain?.lowercase()?.substringBefore(':')
        val all = _contacts.value
        fun dom(c: Contact) = c.address.substringAfter('@', "").lowercase()
        all.firstOrNull { it.user.lowercase() == user && (domain == null || dom(it) == domain) }?.let { return it.name }
        all.filter { it.user.lowercase() == user }.takeIf { it.size == 1 }?.let { return it[0].name }
        val digits = user.filter { it.isDigit() }
        if (digits.length >= 7) {
            val tail = digits.takeLast(10)
            all.filter { c -> c.user.filter { it.isDigit() }.let { it.length >= 7 && it.takeLast(10) == tail } }.takeIf { it.size == 1 }?.let { return it[0].name }
        }
        return null
    }
}

// MARK: Messages

enum class MsgStatus { SENDING, SENT, FAILED }
data class Message(val id: String = UUID.randomUUID().toString(), val date: Long = System.currentTimeMillis(), val outgoing: Boolean, val text: String,
                   val status: MsgStatus = MsgStatus.SENT, val failure: String? = null, val read: Boolean = true)
data class Conversation(val accountID: String, val peer: String, val messages: List<Message> = emptyList()) {
    val id get() = key(accountID, peer)
    val last get() = messages.lastOrNull()
    val unread get() = messages.count { !it.read }
    val user get() = peer.substringBefore('@')
    companion object { fun key(account: String, peer: String) = "$account|${peer.lowercase()}" }
}

class MessageStore(context: Context) {
    private val file = JsonFile(context, "messages.json")
    private fun load(): List<Conversation> {
        val a = file.read()
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i); val ms = o.getJSONArray("messages")
            Conversation(o.getString("accountID"), o.getString("peer"), (0 until ms.length()).map { j ->
                val m = ms.getJSONObject(j)
                Message(m.getString("id"), m.getLong("date"), m.getBoolean("outgoing"), m.getString("text"), MsgStatus.valueOf(m.getString("status")),
                    m.optString("failure").ifEmpty { null }, m.optBoolean("read", true))
            })
        }
    }
    private val _conversations = MutableStateFlow(load())
    val conversations: StateFlow<List<Conversation>> = _conversations
    val unread get() = _conversations.value.sumOf { it.unread }
    fun conversation(account: String, peer: String) = _conversations.value.firstOrNull { it.id == Conversation.key(account, peer) }
    private fun commit(l: List<Conversation>) { _conversations.value = l.sortedByDescending { it.last?.date ?: 0 }
        file.write(JSONArray(_conversations.value.map { c -> JSONObject().put("accountID", c.accountID).put("peer", c.peer).put("messages", JSONArray(c.messages.map { m ->
            JSONObject().put("id", m.id).put("date", m.date).put("outgoing", m.outgoing).put("text", m.text).put("status", m.status.name).put("failure", m.failure ?: "").put("read", m.read) })) })) }
    fun add(m: Message, account: String, peer: String): String {
        val key = Conversation.key(account, peer); val l = _conversations.value.toMutableList(); val i = l.indexOfFirst { it.id == key }
        if (i >= 0) l[i] = l[i].copy(messages = l[i].messages + m) else l.add(Conversation(account, peer.lowercase(), listOf(m)))
        commit(l); return m.id
    }
    fun update(id: String, status: MsgStatus, failure: String? = null) =
        commit(_conversations.value.map { c -> c.copy(messages = c.messages.map { if (it.id == id) it.copy(status = status, failure = failure) else it }) })
    fun remove(messageID: String) = commit(_conversations.value.map { c -> c.copy(messages = c.messages.filter { it.id != messageID }) }.filter { it.messages.isNotEmpty() })
    fun markRead(account: String, peer: String) { val k = Conversation.key(account, peer)
        if (_conversations.value.any { it.id == k && it.unread > 0 }) commit(_conversations.value.map { if (it.id == k) it.copy(messages = it.messages.map { m -> m.copy(read = true) }) else it }) }
    fun delete(ids: List<String>) = commit(_conversations.value.filter { it.id !in ids })
    fun removeAll() = commit(emptyList())
    fun removeAccount(id: String) = commit(_conversations.value.filter { it.accountID != id })
}
