package com.livenet.l1ne.core

/** When L1ne plays its own ringback tone. */
object RingbackRule {
    /** From the moment an outgoing call is placed until it is answered, so the person hears something while it says "Calling…" and not only once the
     *  other phone is reported as ringing. Not when the setting lets the PBX's own early media through instead. */
    fun wanted(outgoing: Boolean, answered: Boolean, waiting: Boolean, acceptEarlyMedia: Boolean) = outgoing && !answered && waiting && !acceptEarlyMedia
}
