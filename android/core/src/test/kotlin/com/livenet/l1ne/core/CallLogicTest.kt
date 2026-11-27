package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CallLogicTest {
    @Test fun theOtherSideOfACallIsTakenApart() {
        val r = "\"(612) 555-0142\" <sip:6125550142@pbx.example.com;transport=tls>"
        assertEquals("6125550142@pbx.example.com", SipAddress.address(r))
        assertEquals("6125550142", SipAddress.user(r))
        assertEquals("(612) 555-0142", SipAddress.displayName(r))
        assertEquals("Max", SipAddress.displayName("Max <sip:7201@pbx.example.com>"))
        assertNull(SipAddress.displayName("<sip:7201@pbx.example.com>")); assertNull(SipAddress.displayName("sip:7201@pbx.example.com")); assertNull(SipAddress.displayName("\"\" <sip:7201@h>"))
        assertEquals("7201@pbx.example.com", SipAddress.address("sip:7201@pbx.example.com")); assertEquals("nothing", SipAddress.user("nothing"))
    }

    @Test fun registrationResultsReadAsPlainText() {
        assertEquals("Registered", RegistrationText.status(200, "OK")); assertEquals("Registering…", RegistrationText.status(0, "")); assertEquals("Registering…", RegistrationText.status(100, "Trying"))
        assertEquals("Registering…", RegistrationText.status(408, "")); assertEquals("Not registered: 408 Timeout", RegistrationText.status(408, "Timeout")); assertEquals("Not registered: 403 Forbidden", RegistrationText.status(403, "Forbidden"))
        assertEquals("The PBX refused that username or password. Check them and try again.", RegistrationText.explain("Not registered: 403 Forbidden"))
        assertEquals("The PBX doesn't know that username or extension.", RegistrationText.explain("Not registered: 404 Not Found"))
        assertEquals("Couldn't reach the PBX. Check the server name and your connection.", RegistrationText.explain("Not registered: 503 Service Unavailable"))
        assertEquals("Couldn't sign in: 486 Busy", RegistrationText.explain("Not registered: 486 Busy"))
    }

    @Test fun callQualityIsForgiving() {
        assertEquals(5, CallQuality.bars(0.0, 20.0, 80.0)); assertEquals(5, CallQuality.bars(3.0, 60.0, 350.0))
        assertEquals(4, CallQuality.bars(5.0, 20.0, 80.0)); assertEquals(1, CallQuality.bars(20.0, 200.0, 900.0))
        assertEquals(0.0, CallQuality.lossPercent(5.0, 10.0)); assertEquals(25.0, CallQuality.lossPercent(25.0, 75.0))      // too few packets to judge, then a real figure
    }

    @Test fun ringbackStartsAsSoonAsACallIsPlacedAndOnlyThen() {
        assertEquals(true, RingbackRule.wanted(outgoing = true, answered = false, waiting = true, acceptEarlyMedia = false))
        assertEquals(false, RingbackRule.wanted(true, true, true, false)); assertEquals(false, RingbackRule.wanted(false, false, true, false))
        assertEquals(false, RingbackRule.wanted(true, false, false, false)); assertEquals(false, RingbackRule.wanted(true, false, true, true))
    }
}
