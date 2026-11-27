package com.livenet.l1ne.core

/** The parts of a SIP address as PJSIP reports the other side of a call: `"Name" <sip:7001@host>` or `sip:7001@host`. */
object SipAddress {
    private val address = Regex("sip:([^>;]+)")
    private val user = Regex("sip:([^@>;]+)")

    /** user@domain of the other side, for the call log (the whole text when it holds no sip: address). */
    fun address(remote: String): String = address.find(remote)?.groupValues?.get(1) ?: remote

    /** The user part: "7001" (the whole text when it holds no sip: address). */
    fun user(remote: String): String = user.find(remote)?.groupValues?.get(1) ?: remote

    /** The name the caller sent (caller ID) to keep in the call history: "" when there is none, or when it is only the number again. */
    fun callerIdName(remote: String): String {
        val n = displayName(remote) ?: return ""; val u = user(remote)
        val d = n.filter { it.isDigit() }
        return if (n.equals(u, true) || (d.isNotEmpty() && d == u.filter { it.isDigit() })) "" else n
    }

    /** The display name part: `"(612) 555-0142" <sip:...>` -> (612) 555-0142; null when there is none. */
    fun displayName(remote: String): String? {
        val lt = remote.indexOf('<').takeIf { it > 0 } ?: return null
        return remote.substring(0, lt).trim().trim('"').trim().takeIf { it.isNotEmpty() }
    }
}
