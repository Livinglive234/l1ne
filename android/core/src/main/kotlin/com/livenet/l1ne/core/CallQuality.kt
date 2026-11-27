package com.livenet.l1ne.core

/** How good a call sounds, as the number of bars (1 to 5), from what the media stream measured. */
object CallQuality {
    /** Packet loss counts once enough packets have gone by to mean something. */
    fun lossPercent(lost: Double, received: Double): Double { val total = received + lost; return if (total > 20) lost * 100 / total else 0.0 }

    /** Forgiving on purpose: ordinary internet jitter and a distant server shouldn't cost a call its bars. [jitterMs] and [rttMs] are milliseconds. */
    fun bars(lossPercent: Double, jitterMs: Double, rttMs: Double): Int {
        var score = 5
        if (lossPercent > 3) score--; if (lossPercent > 8) score--; if (lossPercent > 15) score--
        if (jitterMs > 60) score--; if (jitterMs > 150) score--
        if (rttMs > 350) score--; if (rttMs > 700) score--
        return maxOf(1, score)
    }
}
