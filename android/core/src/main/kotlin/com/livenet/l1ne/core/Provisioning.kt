package com.livenet.l1ne.core

import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.net.URI
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Reads Linphone-style remote configuration (`<config><section name="proxy_0"><entry name="...">`),
 * the same XML Linphone fetches after scanning a QR code. Fetching is the app's job and happens once, on demand.
 */
object Provisioning {
    data class Parsed(val account: Account, val secret: String)
    data class Result(val accounts: List<Parsed>, val contactsUrl: String?, val notes: List<String>)
    class Failure(message: String) : Exception(message)

    /** Accepts `https://…`, `linphone-config:https://…`, `l1ne-config:https://…`. */
    fun configUrl(text: String): URI? {
        var s = text.trim()
        for (scheme in listOf("linphone-config:", "l1ne-config:")) if (s.lowercase().startsWith(scheme)) s = s.drop(scheme.length)
        val u = runCatching { URI(s) }.getOrNull() ?: return null
        return if (u.scheme?.lowercase() == "https" && u.host != null) u else null
    }

    fun parse(xml: ByteArray): Result {
        val sections = readSections(xml)
        if (sections.isEmpty()) throw Failure("That isn't a Linphone-style configuration file.")

        val notes = ArrayList<String>()
        val accounts = ArrayList<Parsed>()
        // L1ne's own settings, which Linphone ignores: a default for every account in the file in <section name="l1ne"><entry name="outbound_prefix">9</entry></section>,
        // and one account's own value (an empty one means none) as <entry name="l1ne_outbound_prefix">9</entry> inside its proxy_N section.
        val defaultPrefix = cleanPrefix(sections["l1ne"]?.get("outbound_prefix") ?: "")
        val proxies = sections.keys.filter { it.startsWith("proxy_") }.sortedBy { idx(it) }
        val auths = sections.filterKeys { it.startsWith("auth_info_") }.values.toList()

        for (name in proxies) {
            val e = sections.getValue(name)
            val ident = parseIdentity(e["reg_identity"] ?: "") ?: continue
            if (e["reg_sendregister"] == "0") continue
            var a = Account(username = ident.user, domain = ident.domain, label = ident.domain, displayName = ident.display,
                outboundPrefix = e["l1ne_outbound_prefix"]?.let { cleanPrefix(it) } ?: defaultPrefix)       // this account's own entry, else the file's default
            val proxy = parseProxy(e["reg_proxy"] ?: e["reg_route"] ?: "")
            if (proxy != null) {
                a = a.copy(
                    domain = proxy.host.ifEmpty { ident.domain },
                    port = proxy.port ?: if (proxy.transport == Transport.TLS) 5061 else 5060,
                    transport = proxy.transport,
                )
            }
            if (a.domain != ident.domain && a.label.isEmpty()) a = a.copy(label = ident.domain)

            val match = auths.firstOrNull { it["username"] == ident.user && (it["domain"] ?: ident.domain) == ident.domain }
                ?: auths.firstOrNull { it["username"] == ident.user }
            var secret = ""
            if (match != null) {
                match["userid"]?.takeIf { it.isNotEmpty() && it != ident.user }?.let { a = a.copy(authUser = it) }
                secret = match["passwd"] ?: ""
                if (secret.isEmpty() && match["ha1"] != null)
                    notes.add("${ident.user}@${ident.domain} only has a password hash (ha1); enter the secret by hand.")
            } else notes.add("No credentials for ${ident.user}@${ident.domain}; enter the secret by hand.")

            val enc = (sections["sip"]?.get("media_encryption") ?: sections["rtp"]?.get("media_encryption") ?: e["media_encryption"] ?: "").lowercase()
            a = a.copy(media = if (enc == "none") Media.NONE else Media.SRTP_SDES)
            accounts.add(Parsed(a, secret))
        }

        val contacts = sections["misc"]?.get("contacts-vcard-list")?.takeIf { it.isNotEmpty() }
        if (accounts.isEmpty()) throw Failure("The file has no usable SIP account.")
        return Result(accounts, contacts, notes)
    }

    /** An outside-line prefix as it may appear in a setup file: up to 4 of 0-9 * #. Anything else means none. */
    fun cleanPrefix(p: String): String = if (p.length <= 4 && p.all { it in "0123456789*#" }) p else ""

    private fun idx(s: String) = s.substringAfterLast('_').toIntOrNull() ?: 0

    data class Identity(val display: String, val user: String, val domain: String)

    /** `"Max B" <sip:7201@pbx.example.com>` / `sip:7201@host` / `<sip:…>` */
    fun parseIdentity(raw: String): Identity? {
        var display = ""
        var uri = raw.trim()
        val lt = uri.indexOf('<'); val gt = uri.lastIndexOf('>')
        if (lt >= 0 && gt > lt) {
            display = uri.substring(0, lt).trim { it == ' ' || it == '"' }
            uri = uri.substring(lt + 1, gt)
        }
        val addr = VCard.sipAddress(uri) ?: return null
        val (user, domain) = addr.split("@", limit = 2)
        return Identity(display, user, domain)
    }

    data class Proxy(val host: String, val port: Int?, val transport: Transport)

    fun parseProxy(raw: String): Proxy? {
        var v = raw.trim { it == ' ' || it == '<' || it == '>' || it == '"' }
        if (v.isEmpty()) return null
        var transport = Transport.UDP
        val lower = v.lowercase()
        if (lower.startsWith("sips:")) { v = v.drop(5); transport = Transport.TLS } else if (lower.startsWith("sip:")) v = v.drop(4)
        val parts = v.split(";")
        v = parts[0]
        for (p in parts.drop(1)) if (p.lowercase().startsWith("transport=")) transport = Transport.of(p.drop(10)) ?: transport
        var port: Int? = null
        val c = v.lastIndexOf(':')
        if (c >= 0) v.substring(c + 1).toIntOrNull()?.let { port = it; v = v.substring(0, c) }
        return Proxy(v.lowercase(), port, transport)
    }

    private fun readSections(xml: ByteArray): Map<String, Map<String, String>> {
        val f = DocumentBuilderFactory.newInstance()
        runCatching { f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }   // no XXE
        val doc = runCatching { f.newDocumentBuilder().parse(ByteArrayInputStream(xml)) }.getOrNull() ?: return emptyMap()
        val out = LinkedHashMap<String, MutableMap<String, String>>()
        val secs = doc.getElementsByTagName("section")
        for (i in 0 until secs.length) {
            val sec = secs.item(i) as Element
            val sname = sec.getAttribute("name").ifEmpty { continue }
            val entries = sec.getElementsByTagName("entry")
            for (j in 0 until entries.length) {
                val en = entries.item(j) as Element
                out.getOrPut(sname) { LinkedHashMap() }[en.getAttribute("name")] = en.textContent.trim()
            }
        }
        return out
    }
}
