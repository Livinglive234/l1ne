package com.livenet.l1ne.core

/**
 * Minimal vCard 3.0/4.0 reader that keeps only entries with a SIP address.
 * Phone numbers and everything else in the card are ignored on purpose.
 */
object VCard {
    data class Entry(val name: String, val address: String)         // address = user@domain
    data class Result(val entries: List<Entry>, val skipped: Int)

    fun parse(text: String): Result {
        val lines = ArrayList<String>()
        for (raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
            if ((raw.startsWith(" ") || raw.startsWith("\t")) && lines.isNotEmpty()) {
                lines[lines.size - 1] = lines.last() + raw.drop(1)           // folded line
            } else lines.add(raw)
        }

        val entries = ArrayList<Entry>()
        var skipped = 0
        var fn = ""; var n = ""
        var sips = ArrayList<String>()
        var inCard = false

        for (line in lines) {
            val colon = line.indexOf(':')
            if (colon < 0) continue
            var prop = line.substring(0, colon).uppercase()
            val value = line.substring(colon + 1)
            prop.indexOf('.').let { if (it >= 0) prop = prop.substring(it + 1) }      // item1.IMPP
            val base = prop.substringBefore(';')

            when {
                base == "BEGIN" && value.uppercase() == "VCARD" -> { inCard = true; fn = ""; n = ""; sips = ArrayList() }
                base == "END" && value.uppercase() == "VCARD" -> {
                    if (!inCard) continue
                    inCard = false
                    if (sips.isEmpty()) { skipped++; continue }
                    val name = fn.ifEmpty { n }
                    for (s in sips) entries.add(Entry(name.ifEmpty { s }, s))
                }
                base == "FN" && inCard -> fn = unescape(value).trim()
                base == "N" && inCard -> {
                    val p = value.split(";").map { unescape(it).trim() }
                    n = listOf(p.getOrElse(1) { "" }, p.firstOrNull() ?: "").filter { it.isNotEmpty() }.joinToString(" ")
                }
                base in setOf("IMPP", "X-SIP", "SIP", "X-SIP-URI", "TEL", "URL") ->
                    if (inCard) sipAddress(value)?.let { if (it !in sips) sips.add(it) }
            }
        }
        return Result(entries, skipped)
    }

    /** `sip:7201@Pbx.Example.com;transport=tls` -> `7201@pbx.example.com`; null if it is not a SIP URI. */
    fun sipAddress(value: String): String? {
        var v = unescape(value).trim()
        val lower = v.lowercase()
        v = when {
            lower.startsWith("sips:") -> v.drop(5)
            lower.startsWith("sip:") -> v.drop(4)
            else -> return null
        }
        v = v.substringBefore(';').substringBefore('?')
        val i = v.indexOf('@')
        if (i <= 0 || i == v.length - 1) return null
        return v.substring(0, i) + "@" + v.substring(i + 1).lowercase()
    }

    private fun unescape(s: String) = s.replace("\\n", " ").replace("\\N", " ")
        .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")
}
