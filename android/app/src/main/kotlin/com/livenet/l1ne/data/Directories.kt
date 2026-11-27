package com.livenet.l1ne.data

import android.content.Context
import com.livenet.l1ne.core.VCard
import com.unboundid.ldap.sdk.*
import com.unboundid.util.ssl.SSLUtil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.w3c.dom.Element
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import javax.xml.parsers.DocumentBuilderFactory

enum class SyncInterval(val label: String, val seconds: Long?) {
    MANUAL("Manual only", null), ON_OPEN("Every time L1ne opens", null), MIN15("Every 15 minutes", 900), HOURLY("Every hour", 3600), HOURS6("Every 6 hours", 21600), DAILY("Once a day", 86400)
}
enum class DirKind { LDAP, CARDDAV, VCARD_LINK }
enum class LdapSecurity(val label: String) { LDAPS("LDAPS (TLS)"), STARTTLS("StartTLS"), NONE("None (plain)") }

data class DirectorySource(
    val id: String = UUID.randomUUID().toString(), val kind: DirKind, val name: String = "", val enabled: Boolean = true, val interval: SyncInterval = SyncInterval.DAILY,
    val accountID: String? = null, val lastSync: Long? = null, val lastAttempt: Long? = null, val lastResult: String? = null,
    val url: String = "", val username: String = "",
    val host: String = "", val port: Int = if (kind == DirKind.LDAP) 636 else 0, val security: LdapSecurity = LdapSecurity.LDAPS, val bindDN: String = "", val baseDN: String = "",
    val filter: String = "(objectClass=person)", val nameAttr: String = "displayName", val sipAttr: String = "sipAddress", val phoneAttr: String = "telephoneNumber", val phoneAsExtension: Boolean = false,
) {
    val isDirectory get() = kind != DirKind.VCARD_LINK
    val title get() = name.ifEmpty { if (kind == DirKind.LDAP) host else runCatching { URL(url).host }.getOrDefault(url) }
    val tag get() = "dir:$id"
}

class DirectoryStore(context: Context, private val secrets: AccountStore) {
    private val prefs = context.getSharedPreferences("directories", Context.MODE_PRIVATE)
    private val _sources = MutableStateFlow(load()); val sources: StateFlow<List<DirectorySource>> = _sources
    val directoryEnabled get() = _sources.value.any { it.enabled && it.isDirectory }
    fun password(id: String) = secrets.secret("dir.$id")
    fun save(s: DirectorySource, password: String?) { val l = _sources.value.toMutableList(); val i = l.indexOfFirst { it.id == s.id }; if (i >= 0) l[i] = s else l.add(s); _sources.value = l; persist(); if (password != null) secrets.putSecret("dir.${s.id}", password) }
    fun update(id: String, f: (DirectorySource) -> DirectorySource) { _sources.value = _sources.value.map { if (it.id == id) f(it) else it }; persist() }
    fun remove(id: String) { _sources.value = _sources.value.filter { it.id != id }; persist() }
    private fun persist() = prefs.edit().putString("list", JSONArray(_sources.value.map { s -> JSONObject().put("id", s.id).put("kind", s.kind.name).put("name", s.name).put("enabled", s.enabled).put("interval", s.interval.name)
        .put("accountID", s.accountID ?: "").put("lastSync", s.lastSync ?: 0).put("lastAttempt", s.lastAttempt ?: 0).put("lastResult", s.lastResult ?: "").put("url", s.url).put("username", s.username)
        .put("host", s.host).put("port", s.port).put("security", s.security.name).put("bindDN", s.bindDN).put("baseDN", s.baseDN).put("filter", s.filter).put("nameAttr", s.nameAttr).put("sipAttr", s.sipAttr)
        .put("phoneAttr", s.phoneAttr).put("phoneAsExtension", s.phoneAsExtension) }).toString()).apply()
    private fun load(): List<DirectorySource> = runCatching { val a = JSONArray(prefs.getString("list", "[]")); (0 until a.length()).map { a.getJSONObject(it).let { o ->
        DirectorySource(o.getString("id"), DirKind.valueOf(o.getString("kind")), o.optString("name"), o.optBoolean("enabled", true), SyncInterval.valueOf(o.optString("interval", "DAILY")),
            o.optString("accountID").ifEmpty { null }, o.optLong("lastSync").takeIf { it > 0 }, o.optLong("lastAttempt").takeIf { it > 0 }, o.optString("lastResult").ifEmpty { null }, o.optString("url"), o.optString("username"),
            o.optString("host"), o.optInt("port", 636), LdapSecurity.valueOf(o.optString("security", "LDAPS")), o.optString("bindDN"), o.optString("baseDN"), o.optString("filter", "(objectClass=person)"),
            o.optString("nameAttr", "displayName"), o.optString("sipAttr", "sipAddress"), o.optString("phoneAttr", "telephoneNumber"), o.optBoolean("phoneAsExtension")) } } }.getOrDefault(emptyList())
}

/** Runs directory syncs: on demand, and on a timer while L1ne is open. A synced directory replaces the vCard-link import. */
class DirectorySync(private val dirs: DirectoryStore, private val contacts: ContactsStore, private val accounts: AccountStore) {
    val running = MutableStateFlow(setOf<String>())

    suspend fun fetch(s: DirectorySource, password: String): VCard.Result = withContext(Dispatchers.IO) {
        when (s.kind) {
            DirKind.VCARD_LINK -> { require(s.url.trim().startsWith("https://", true)) { "That isn't an https link." }; VCard.parse(String(URL(s.url.trim()).readBytes())) }
            DirKind.CARDDAV -> cardDav(s.url.trim(), s.username, password)
            DirKind.LDAP -> ldap(s, password)
        }
    }
    suspend fun test(s: DirectorySource, password: String): String = runCatching { fetch(s, password).let { "Works: found ${it.entries.size} with a SIP address, ${it.skipped} without." } }.getOrElse { "Failed: ${it.message}" }

    suspend fun sync(id: String): String {
        val s = dirs.sources.value.firstOrNull { it.id == id } ?: return ""
        if (id in running.value) return ""
        running.value += id; dirs.update(id) { it.copy(lastAttempt = System.currentTimeMillis()) }
        val result = try {
            val r = fetch(s, dirs.password(id)); val sum = contacts.replaceSource(s.tag, r, s.accountID ?: accounts.selected?.id)
            ("${sum.added} added, ${sum.updated} updated, ${sum.removed} removed" + (if (sum.skipped > 0) "; ${sum.skipped} had no SIP address" else "")).also { res -> dirs.update(id) { it.copy(lastSync = System.currentTimeMillis(), lastResult = res) } }
        } catch (e: Exception) { "Failed: ${e.message}".also { res -> dirs.update(id) { it.copy(lastResult = res) } } }
        running.value -= id; return result
    }

    private fun isDue(s: DirectorySource, onOpen: Boolean): Boolean {
        if (!s.enabled || s.id in running.value) return false
        return when (s.interval) { SyncInterval.MANUAL -> false; SyncInterval.ON_OPEN -> onOpen
            else -> System.currentTimeMillis() - (s.lastAttempt ?: 0) >= (s.interval.seconds ?: Long.MAX_VALUE) * 1000 }
    }
    suspend fun syncDue(onOpen: Boolean = false) { for (s in dirs.sources.value) if (isDue(s, onOpen)) sync(s.id) }

    // CardDAV: one REPORT returns every card; servers that refuse get a PROPFIND list and one GET per card.
    private fun cardDav(url: String, user: String, pass: String): VCard.Result {
        require(url.startsWith("https://", true) || url.startsWith("http://", true)) { "That isn't a valid address book URL." }
        val auth = if (user.isNotEmpty()) "Basic " + android.util.Base64.encodeToString("$user:$pass".toByteArray(), android.util.Base64.NO_WRAP) else null
        fun req(u: String, method: String, body: String?): Pair<Int, ByteArray> {
            val c = (URL(u).openConnection() as HttpURLConnection); c.connectTimeout = 30000; c.readTimeout = 30000
            c.requestMethod = "POST"; c.setRequestProperty("X-HTTP-Method-Override", method)          // HttpURLConnection refuses REPORT/PROPFIND
            runCatching { val f = HttpURLConnection::class.java.getDeclaredField("method"); f.isAccessible = true; f.set(c, method) }
            auth?.let { c.setRequestProperty("Authorization", it) }; c.setRequestProperty("Depth", "1")
            if (body != null) { c.doOutput = true; c.setRequestProperty("Content-Type", "application/xml; charset=utf-8"); c.outputStream.use { it.write(body.toByteArray()) } }
            val code = c.responseCode; return code to (if (code < 400) c.inputStream.use { it.readBytes() } else ByteArray(0))
        }
        fun fail(code: Int): Nothing = throw IllegalStateException(when (code) { 401 -> "The server rejected the user name or password (401)."; 404 -> "The address book wasn't found (404). Check the URL."; else -> "The server answered $code." })
        val (code, data) = req(url, "REPORT", """<?xml version="1.0" encoding="utf-8"?><C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><D:prop><D:getetag/><C:address-data/></D:prop></C:addressbook-query>""")
        if (code == 207) return VCard.parse(texts(data, "address-data").joinToString("\n"))
        if (code != 405 && code != 501) fail(code)
        val (lc, ld) = req(url, "PROPFIND", """<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>"""); if (lc != 207) fail(lc)
        val cards = ArrayList<String>()
        for (href in texts(ld, "href").take(3000).filter { it.lowercase().endsWith(".vcf") }) runCatching {
            val c = (URL(URL(url), href).openConnection() as HttpURLConnection); auth?.let { c.setRequestProperty("Authorization", it) }
            if (c.responseCode == 200) cards.add(String(c.inputStream.readBytes())) }
        return VCard.parse(cards.joinToString("\n"))
    }
    private fun texts(data: ByteArray, name: String): List<String> {
        val f = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true; setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
        val doc = f.newDocumentBuilder().parse(data.inputStream()); val out = ArrayList<String>(); val all = doc.getElementsByTagName("*")
        for (i in 0 until all.length) (all.item(i) as Element).let { if ((it.localName ?: it.tagName.substringAfter(':')).lowercase() == name) out.add(it.textContent.trim()) }
        return out
    }

    private fun ldap(s: DirectorySource, password: String): VCard.Result {
        val domain = (accounts.account(s.accountID) ?: accounts.selected)?.domain?.lowercase() ?: ""
        val util = SSLUtil(); val conn = when (s.security) {
            LdapSecurity.LDAPS -> LDAPConnection(util.createSSLSocketFactory(), s.host, s.port)
            LdapSecurity.STARTTLS -> LDAPConnection(s.host, s.port).also { it.processExtendedOperation(com.unboundid.ldap.sdk.extensions.StartTLSExtendedRequest(util.createSSLContext())) }
            LdapSecurity.NONE -> LDAPConnection(s.host, s.port) }
        conn.use {
            if (s.bindDN.isNotEmpty()) it.bind(s.bindDN, password)
            val attrs = mutableSetOf("cn", "displayName", "givenName", "sn", s.nameAttr, s.sipAttr).apply { if (s.phoneAsExtension) add(s.phoneAttr) }
            val res = it.search(SearchRequest(s.baseDN, SearchScope.SUB, s.filter, *attrs.toTypedArray()).apply { sizeLimit = 5000 })
            val out = ArrayList<VCard.Entry>(); var skipped = 0
            for (e in res.searchEntries) {
                val addrs = ArrayList<String>()
                for (raw in e.getAttributeValues(s.sipAttr) ?: emptyArray()) { val v = raw.trim()
                    VCard.sipAddress(if (v.lowercase().startsWith("sip")) v else if (v.contains("@")) "sip:$v" else if (domain.isEmpty()) "" else "sip:$v@$domain")?.let { a -> if (a !in addrs) addrs.add(a) } }
                if (addrs.isEmpty() && s.phoneAsExtension && domain.isNotEmpty()) e.getAttributeValue(s.phoneAttr)?.filter { c -> c.isDigit() }?.takeIf { d -> d.isNotEmpty() }?.let { d -> addrs.add("$d@$domain") }
                if (addrs.isEmpty()) { skipped++; continue }
                val name = e.getAttributeValue(s.nameAttr) ?: e.getAttributeValue("displayName") ?: e.getAttributeValue("cn") ?: listOfNotNull(e.getAttributeValue("givenName"), e.getAttributeValue("sn")).joinToString(" ")
                for (a in addrs) out.add(VCard.Entry(name.ifEmpty { e.dn.substringBefore(',').substringAfter('=') }, a))
            }
            return VCard.Result(out, skipped)
        }
    }
}
