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
    val sipAddress: String get() = "sip:$username@$domain"
    val initials: String get() {
        val words = label.split(' ', '-', '_').filter { it.firstOrNull()?.isLetterOrDigit() == true }
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
        if (formatWithPrefix && intlPrefix.isNotEmpty() && !n.startsWith("+") && !n.startsWith("00") &&
            n.firstOrNull()?.isDigit() == true && n.count { it.isDigit() } >= 7) {
            if (n.startsWith("0")) n = n.drop(1)
            n = "+$intlPrefix$n"
        }
        if (plusTo00 && n.startsWith("+")) n = "00" + n.drop(1)
        return dialAddPrefix + n
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
    /** Switching transport moves the port with it, unless you set a custom one. */
    fun withTransport(t: Transport) = copy(transport = t, port = if (port == 5060 || port == 5061 || port <= 0) defaultPort(t) else port)
}
