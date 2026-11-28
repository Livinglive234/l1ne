package com.livenet.l1ne.core

/** Which calls in the history are with the same person: the same extension or number on the same server (a missing server matches any). */
object CallHistory {
    fun sameParty(a: String, b: String): Boolean {
        fun parts(x: String): Pair<String, String> { val t = x.trim().lowercase().removePrefix("sips:").removePrefix("sip:"); return t.substringBefore('@') to t.substringAfter('@', "") }
        val (u1, d1) = parts(a); val (u2, d2) = parts(b)
        val g1 = u1.filter { it.isDigit() }; val g2 = u2.filter { it.isDigit() }
        val sameUser = u1 == u2 || (g1.isNotEmpty() && g1 == g2) || (g1.length >= 10 && g2.length >= 10 && g1.takeLast(10) == g2.takeLast(10))
        return sameUser && (d1.isEmpty() || d2.isEmpty() || d1 == d2)
    }
}
