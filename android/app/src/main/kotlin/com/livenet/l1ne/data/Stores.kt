package com.livenet.l1ne.data

import android.content.Context
import com.livenet.l1ne.core.ContactBook
import com.livenet.l1ne.core.VCard
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** One background thread writes every store's file, so a change never makes the main thread wait for the disk. */
private val storeWriter = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "l1ne-store-writer") }

/** Waits until every change handed over so far is on disk. Used before a file is read back, and when L1ne goes to the background. */
fun flushStoreWrites() { runCatching { storeWriter.submit {}.get(5, java.util.concurrent.TimeUnit.SECONDS) } }

/** Reads and writes one JSON file in the app's private storage (nothing leaves the phone).
 *  Writes happen in the background and only the newest content is written (a burst of changes becomes one write), through a temp file so a crash never leaves half a file. */
private class JsonFile(context: Context, name: String) {
    private val f = File(context.filesDir, name)
    private val lock = Any()
    private var latest: String? = null          // the content waiting to be written
    private var scheduled = false               // a writer task is queued or running

    fun read(): JSONArray { flushStoreWrites(); return runCatching { JSONArray(f.readText()) }.getOrDefault(JSONArray()) }

    fun write(a: JSONArray) {
        val text = a.toString()
        synchronized(lock) { latest = text; if (scheduled) return; scheduled = true }
        storeWriter.execute(::drain)
    }

    private fun drain() {
        while (true) {
            val text = synchronized(lock) { latest.also { latest = null; if (it == null) scheduled = false } } ?: return
            val tmp = File(f.path + ".tmp"); tmp.writeText(text); tmp.renameTo(f)
        }
    }
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

typealias Contact = com.livenet.l1ne.core.Contact
typealias ImportSummary = com.livenet.l1ne.core.ImportSummary

/** L1ne's own address book: never reads the phone's contacts, never fetches by itself, only holds entries with a SIP address. */
class ContactsStore(context: Context) {
    private val file = JsonFile(context, "contacts.json")
    private val _contacts = MutableStateFlow(file.read().let { a -> (0 until a.length()).map { i -> a.getJSONObject(i).let { o ->
        Contact(o.getString("id"), o.getString("name"), o.getString("address"), o.optString("accountID").ifEmpty { null }, o.optBoolean("imported"), o.optString("source").ifEmpty { null }) } } })
    val contacts: StateFlow<List<Contact>> = _contacts
    private fun commit(l: List<Contact>) { _contacts.value = l.sortedBy { it.name.lowercase() }
        file.write(JSONArray(_contacts.value.map { c -> JSONObject().put("id", c.id).put("name", c.name).put("address", c.address)
            .put("accountID", c.accountID ?: "").put("imported", c.imported).put("source", c.source ?: "") })) }

    /** The rules are in core's ContactBook; this only keeps the list and saves it. */
    fun merge(result: VCard.Result, account: String?, source: String = "link"): ImportSummary {
        val (list, summary) = ContactBook.merge(_contacts.value, result, account, source); commit(list); return summary
    }
    fun replaceSource(tag: String, result: VCard.Result, account: String?): ImportSummary {
        val (list, summary) = ContactBook.replaceSource(_contacts.value, tag, result, account); commit(list); return summary
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

    fun nameOrNumber(address: String): String = ContactBook.nameOrNumber(_contacts.value, address)
    fun name(rawUser: String, rawDomain: String? = null): String? = ContactBook.name(_contacts.value, rawUser, rawDomain)
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
