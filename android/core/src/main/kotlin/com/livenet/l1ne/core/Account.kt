package com.livenet.l1ne.core

import java.util.UUID

enum class Transport(val wire: String) { TLS("tls"), TCP("tcp"), UDP("udp");
    companion object { fun of(s: String) = entries.firstOrNull { it.wire == s.lowercase() } }
}
enum class Media(val wire: String) { SRTP_SDES("srtp-sdes"), NONE("none") }

/** One SIP identity on one PBX. Same fields as the iOS app; the secret is kept apart (Keystore). */
data class Account(
    val id: String = UUID.randomUUID().toString(),
    val label: String = "",
    val domain: String = "",
    val port: Int = 5061,
    val transport: Transport = Transport.TLS,
    val media: Media = Media.SRTP_SDES,
    val username: String = "",
    val authUser: String = "",
    val contactsUrl: String = "",
    val pushGateway: String = "",
    val dialStripPrefix: String = "",
    val dialAddPrefix: String = "",
) {
    val title: String get() = label.ifEmpty { domain }

    fun dial(number: String): String {
        val n = if (dialStripPrefix.isNotEmpty() && number.startsWith(dialStripPrefix)) number.removePrefix(dialStripPrefix) else number
        return dialAddPrefix + n
    }
}
