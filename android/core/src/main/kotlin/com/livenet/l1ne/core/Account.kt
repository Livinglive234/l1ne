package com.livenet.l1ne.core

import java.util.UUID

enum class Transport(val wire: String) { TLS("tls"), TCP("tcp"), UDP("udp");
    companion object { fun of(s: String) = entries.firstOrNull { it.wire == s.lowercase() } }
}
enum class Media(val wire: String) { SRTP_SDES("srtp-sdes"), SRTP_DTLS("srtp-dtls"), NONE("none") }

/** One SIP identity on one PBX. Same fields as the iOS app; the secret is kept apart (Keystore). */
data class Account(
    val id: String = UUID.randomUUID().toString(),
    val label: String = "",
    val displayName: String = "",
    val domain: String = "",
    val port: Int = 5061,
    val transport: Transport = Transport.TLS,
    val registrarURI: String = "",
    val outboundProxy: String = "",
    val expires: Int = 3600,
    val enabled: Boolean = true,
    val media: Media = Media.SRTP_SDES,
    val mediaMandatory: Boolean = true,
    val username: String = "",
    val authUser: String = "",
    val contactsUrl: String = "",
    val pushGateway: String = "",
    val dialStripPrefix: String = "",
    val dialAddPrefix: String = "",
    val outboundPrefix: String = "",          // put in front of numbers that look like outside numbers (10 digits, or 1 + 10), never extensions; e.g. 9
    val intlPrefix: String = "",
    val formatWithPrefix: Boolean = false,
    val plusTo00: Boolean = false,
    val voicemailURI: String = "*97",
    val mwiEnabled: Boolean = true,
    val iceEnabled: Boolean = false,
    val turnEnabled: Boolean = false,
    val stunServer: String = "",
    val turnUser: String = "",
) {
    val title: String get() = label.ifEmpty { domain }
    /** The name with the sign-in name after it, "pbx.example.com (7001)": tells two accounts on one server apart in menus and pickers. */
    val titleWithUser: String get() = if (username.isEmpty()) title else "$title ($username)"
    val sipAddress: String get() = "sip:$username@$domain"
    val initials: String get() {
        val source = displayName.ifBlank { label }          // the display name first, then the label
        val words = source.split(' ', '-', '_').filter { it.firstOrNull()?.isLetterOrDigit() == true }
        if (words.isNotEmpty()) return words.take(2).map { it.first() }.joinToString("").uppercase()
        return domain.filter { it.isLetterOrDigit() }.take(2).uppercase()
    }

    /** Where the voicemail button dials: a bare number or code becomes sip:<it>@<server>; a full sip: address is used as typed. */
    val voicemailTarget: String? get() {
        val v = voicemailURI.trim(); if (v.isEmpty()) return null
        val l = v.lowercase()
        return if (l.startsWith("sip:") || l.startsWith("sips:")) v else "sip:$v@$domain"
    }

    /** Applies the account's dial rules to what was typed. */
    fun dial(number: String): String {
        var n = number.filter { it !in " -()" }
        if (dialStripPrefix.isNotEmpty() && n.startsWith(dialStripPrefix)) n = n.removePrefix(dialStripPrefix)
        // an outside number (10 digits, or 1 + 10) gets the outside-line prefix, and is already complete, so no country code is added
        val outside = outboundPrefix.isNotEmpty() && PhoneFormat.isOutside(n)
        if (!outside && formatWithPrefix && intlPrefix.isNotEmpty() && !n.startsWith("+") && !n.startsWith("00") &&
            n.firstOrNull()?.isDigit() == true && n.count { it.isDigit() } >= 7) {
            if (n.startsWith("0")) n = n.drop(1)
            n = "+$intlPrefix$n"
        }
        if (outside) n = outboundPrefix + n.removePrefix("+") else if (plusTo00 && n.startsWith("+")) n = "00" + n.drop(1)
        return dialAddPrefix + n
    }

    /** An address as it was dialled -> as it should be kept in the call history: without the outside-line prefix, so redial and
     *  callbacks still work. "96125550142@pbx" with prefix 9 -> "6125550142@pbx". */
    fun withoutOutboundPrefix(address: String): String {
        if (outboundPrefix.isEmpty()) return address
        val user = address.substringBefore('@'); val host = address.substringAfter('@', "")
        if (!user.startsWith(outboundPrefix)) return address
        val rest = user.removePrefix(outboundPrefix)
        if (!PhoneFormat.isOutside(rest)) return address
        return if (host.isEmpty()) rest else "$rest@$host"
    }

    /** Reads what you typed in the Domain field: pbx.example.com, pbx.example.com:5080 or sip:pbx.example.com. */
    fun withServer(text: String): Account {
        var t = text.trim()
        for (s in listOf("sips:", "sip:")) if (t.lowercase().startsWith(s)) t = t.drop(s.length)
        t = t.substringBefore('/').substringBefore(';')
        var p = port
        val c = t.lastIndexOf(':')
        if (!t.startsWith("[") && c >= 0) t.substring(c + 1).toIntOrNull()?.takeIf { it in 1..65535 }?.let { p = it; t = t.substring(0, c) }
        return copy(domain = t, port = p)
    }

    companion object { fun defaultPort(t: Transport) = if (t == Transport.TLS) 5061 else 5060 }
    /** Final touches for an account made from the short form (same as iOS finishNewAccount): the server text is parsed, the account is named after its display name, and SRTP (which needs TLS for its keys) is only kept on TLS. */
    fun finishedNew(server: String): Account {
        var a = withServer(server)
        if (a.label.isEmpty()) a = a.copy(label = a.displayName)
        if (a.transport != Transport.TLS && a.media == Media.SRTP_SDES) a = a.copy(media = Media.NONE, mediaMandatory = false)
        return a
    }

    /** Switching transport moves the port with it, unless you set a custom one. */
    fun withTransport(t: Transport) = copy(transport = t, port = if (port == 5060 || port == 5061 || port <= 0) defaultPort(t) else port)
}
