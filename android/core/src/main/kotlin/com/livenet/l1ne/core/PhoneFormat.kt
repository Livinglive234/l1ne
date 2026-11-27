package com.livenet.l1ne.core

/** How a phone number is shown. Only for display: what is dialled, stored and matched against contacts stays as it was. */
object PhoneFormat {
    private val us = Regex("""^\+?1?([2-9]\d{2})([2-9]\d{2})(\d{4})$""")

    /** A bare North American number ("6517604266", "16517604266", "+16517604266") as "(651) 760-4266".
     *  Anything else (an extension, a name, an international number, a number already formatted) comes back unchanged. */
    fun pretty(text: String): String {
        val m = us.matchEntire(text.trim()) ?: return text
        return "(${m.groupValues[1]}) ${m.groupValues[2]}-${m.groupValues[3]}"
    }
}
