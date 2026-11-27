package com.livenet.l1ne.data

import com.livenet.l1ne.core.VCard
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.w3c.dom.Element
import java.util.concurrent.TimeUnit
import javax.xml.parsers.DocumentBuilderFactory

/** CardDAV address books. One REPORT returns every card; servers that refuse get a PROPFIND list and one GET per card.
 *  OkHttp sends the real REPORT and PROPFIND methods (the platform's HttpURLConnection refuses them). */
object CardDav {
    private val client = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()

    fun fetch(url: String, user: String, pass: String, http: OkHttpClient = client): VCard.Result {
        require(url.startsWith("https://", true) || url.startsWith("http://", true)) { "That isn't a valid address book URL." }
        val auth = if (user.isNotEmpty()) "Basic " + java.util.Base64.getEncoder().encodeToString("$user:$pass".toByteArray()) else null
        fun req(u: String, method: String, body: String?): Pair<Int, ByteArray> {
            val b = Request.Builder().url(u).header("Depth", "1")
            auth?.let { b.header("Authorization", it) }
            b.method(method, body?.toRequestBody("application/xml; charset=utf-8".toMediaType()))
            http.newCall(b.build()).execute().use { r -> return r.code to (if (r.code < 400) r.body?.bytes() ?: ByteArray(0) else ByteArray(0)) }
        }
        fun fail(code: Int): Nothing = throw IllegalStateException(when (code) { 401 -> "The server rejected the user name or password (401)."; 404 -> "The address book wasn't found (404). Check the URL."; else -> "The server answered $code." })
        val (code, data) = req(url, "REPORT", """<?xml version="1.0" encoding="utf-8"?><C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><D:prop><D:getetag/><C:address-data/></D:prop></C:addressbook-query>""")
        if (code == 207) return VCard.parse(texts(data, "address-data").joinToString("\n"))
        if (code != 405 && code != 501) fail(code)
        val (lc, ld) = req(url, "PROPFIND", """<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>"""); if (lc != 207) fail(lc)
        val cards = ArrayList<String>()
        for (href in texts(ld, "href").take(3000).filter { it.lowercase().endsWith(".vcf") }) runCatching {
            val b = Request.Builder().url(java.net.URL(java.net.URL(url), href)); auth?.let { b.header("Authorization", it) }
            http.newCall(b.build()).execute().use { r -> if (r.code == 200) cards.add(r.body?.string() ?: "") } }
        return VCard.parse(cards.joinToString("\n"))
    }

    internal fun texts(data: ByteArray, name: String): List<String> {
        val f = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true; setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
        val doc = f.newDocumentBuilder().parse(data.inputStream()); val out = ArrayList<String>(); val all = doc.getElementsByTagName("*")
        for (i in 0 until all.length) (all.item(i) as Element).let { if ((it.localName ?: it.tagName.substringAfter(':')).lowercase() == name) out.add(it.textContent.trim()) }
        return out
    }
}
