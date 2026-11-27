package com.livenet.l1ne.core

/** Takes what must never be shown or shared out of SIP log text: passwords' digests, SRTP keys and anything that looks like a secret. */
object LogRedactor {
    private val authHeader = Regex("""(?im)^((?:Proxy-)?Authorization:).*$""")
    private val cryptoKey = Regex("""(?i)(inline:)\S+""")
    private val digestSecrets = Regex("""(?i)\b(response|cnonce)\s*=\s*"?[^",\s]*"?""")
    private val secrets = Regex("""(?i)\b(password|passwd|secret|pwd)\b(\s*[=:]\s*)\S+""")

    fun clean(text: String): String = text
        .replace(authHeader) { it.groupValues[1] + " [removed]" }                  // the whole header: the digest response, and the user name with it
        .replace(cryptoKey) { it.groupValues[1] + "[removed]" }                    // a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:KEY
        .replace(digestSecrets) { it.groupValues[1] + "=\"[removed]\"" }
        .replace(secrets) { it.groupValues[1] + it.groupValues[2] + "[removed]" }
}

/** The last stretch of what the SIP engine did, kept in memory only (gone when L1ne closes), with secrets taken out as each entry arrives. */
object SipLog {
    private const val MAX_ENTRIES = 2500
    private const val MAX_ENTRY_CHARS = 6000
    private val entries = ArrayDeque<String>()

    @Synchronized fun add(raw: String) {
        if (raw.isBlank()) return
        val clean = LogRedactor.clean(raw.trimEnd()).let { if (it.length > MAX_ENTRY_CHARS) it.take(MAX_ENTRY_CHARS) + " …" else it }
        entries.addLast(clean)
        while (entries.size > MAX_ENTRIES) entries.removeFirst()
    }
    @Synchronized fun text(lastEntries: Int = MAX_ENTRIES): String = entries.toList().takeLast(lastEntries).joinToString("\n")
    @Synchronized fun count(): Int = entries.size
    @Synchronized fun clear() = entries.clear()
}
