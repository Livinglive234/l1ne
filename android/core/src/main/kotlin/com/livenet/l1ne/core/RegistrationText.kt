package com.livenet.l1ne.core

/** What a sign-in status looks like to the person using the app. */
object RegistrationText {
    private val statusCode = Regex("""\b(\d{3})\b""")

    /** The line shown for a registration result from the SIP engine (its status code and the server's reason text). */
    fun status(code: Int, text: String): String = when {
        code / 100 == 2 -> "Registered"
        code == 0 || code == 100 || code == 408 && text.isEmpty() -> "Registering…"
        else -> "Not registered: $code $text"
    }

    /** Plain words for the usual ways a first login goes wrong. */
    fun explain(status: String): String {
        val code = statusCode.find(status)?.value?.toIntOrNull() ?: 0
        return when (code) {
            401, 403 -> "The PBX refused that username or password. Check them and try again."
            404 -> "The PBX doesn't know that username or extension."
            408, 503, 504 -> "Couldn't reach the PBX. Check the server name and your connection."
            else -> "Couldn't sign in: ${status.removePrefix("Not registered: ")}"
        }
    }
}
