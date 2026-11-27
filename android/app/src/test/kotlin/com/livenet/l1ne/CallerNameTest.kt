package com.livenet.l1ne

import com.livenet.l1ne.sip.CallInfo
import kotlin.test.Test
import kotlin.test.assertEquals

/** What a call shows for a caller who isn't in the contacts: the caller ID the PBX sent, else the number. */
class CallerNameTest {
    private fun call(remote: String) = CallInfo(1, remote, true, 1, 0, "", 0, null)

    @Test fun quotedCallerIdIsShownAsSent() {
        assertEquals("(612) 555-0142", call("\"(612) 555-0142\" <sip:6125550142@pbx.example.com>").sentName)
        assertEquals("Max Example", call("\"Max Example\" <sip:7201@pbx.example.com>").sentName)
    }
    @Test fun unquotedNameWorksToo() = assertEquals("Max", call("Max <sip:7201@pbx.example.com>").sentName)
    @Test fun noNameFallsBackToTheNumber() {
        assertEquals("7201", call("<sip:7201@pbx.example.com>").sentName)
        assertEquals("7201", call("sip:7201@pbx.example.com").sentName)
        assertEquals("7201", call("\"\" <sip:7201@pbx.example.com>").sentName)
    }
}
