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

/** Several calls in a row with the same person and of the same kind (outgoing, answered incoming or missed), each within an hour of the one before, are shown as one line.
 *  `items` newest first; a call of another kind or with someone else in between starts a new group. */
fun <T> groupCalls(items: List<T>, peer: (T) -> String, kind: (T) -> Int, time: (T) -> Long, withinMs: Long = 3_600_000): List<List<T>> {
    val out = ArrayList<MutableList<T>>()
    for (r in items) {
        val last = out.lastOrNull()?.last()
        if (last != null && kind(last) == kind(r) && CallHistory.sameParty(peer(last), peer(r)) && time(last) - time(r) <= withinMs) out.last().add(r) else out.add(mutableListOf(r))
    }
    return out
}
