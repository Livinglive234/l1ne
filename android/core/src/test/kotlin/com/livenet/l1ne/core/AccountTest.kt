package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AccountTest {
    private fun acc(block: Account.() -> Account = { this }) = Account(username = "7101", domain = "pbx.example.com").block()

    @Test fun extensionsAndCodesAreNeverChanged() {
        val a = acc { copy(intlPrefix = "1", formatWithPrefix = true) }
        assertEquals("7001", a.dial("7001")); assertEquals("*97", a.dial("*97")); assertEquals("555123", a.dial("555123"))      // too short for a phone number
    }
    @Test fun stripThenAddPrefix() {
        val a = acc { copy(dialStripPrefix = "9", dialAddPrefix = "00") }
        assertEquals("005551234567", a.dial("95551234567")); assertEquals("007001", a.dial("7001"))
    }
    @Test fun nationalNumbersGetTheCountryCode() {
        val a = acc { copy(intlPrefix = "1", formatWithPrefix = true) }
        assertEquals("+16125551234", a.dial("612-555-1234")); assertEquals("+16125551234", a.dial("(612) 555 1234"))
        assertEquals("+16125551234", a.dial("0" + "6125551234"))                                                   // a leading 0 is dropped
        assertEquals("+4420712345", a.dial("+4420712345"))                                                         // already international
    }
    @Test fun plusCanBecomeZeroZero() {
        val a = acc { copy(plusTo00 = true) }
        assertEquals("00442071234567", a.dial("+442071234567")); assertEquals("7001", a.dial("7001"))
    }
    @Test fun serverTextIsParsed() {
        assertEquals("pbx.example.com" to 5061, acc().withServer("pbx.example.com").let { it.domain to it.port })
        assertEquals("pbx.example.com" to 5080, acc().withServer("pbx.example.com:5080").let { it.domain to it.port })
        assertEquals("pbx.example.com" to 5061, acc().withServer("sip:pbx.example.com;transport=tls").let { it.domain to it.port })
        assertEquals("pbx.example.com" to 5061, acc().withServer("sips:pbx.example.com/path").let { it.domain to it.port })
        assertEquals("[2001:db8::1]", acc().withServer("[2001:db8::1]").domain)
    }
    @Test fun changingTransportMovesTheStandardPortOnly() {
        assertEquals(5060, acc().withTransport(Transport.UDP).port); assertEquals(5060, acc().withTransport(Transport.TCP).port)
        assertEquals(5061, acc { copy(transport = Transport.UDP, port = 5060) }.withTransport(Transport.TLS).port)
        assertEquals(5080, acc { copy(port = 5080) }.withTransport(Transport.UDP).port)                              // a custom port stays
    }
    @Test fun initialsComeFromTheDisplayNameThenTheLabelThenTheServer() {
        assertEquals("ME", acc { copy(displayName = "Max Example", label = "Work") }.initials)
        assertEquals("WP", acc { copy(label = "Work PBX") }.initials)
        assertEquals("PB", acc().initials)
        assertEquals("ME", acc { copy(displayName = "max-example") }.initials)
    }
    @Test fun voicemailTarget() {
        assertEquals("sip:*97@pbx.example.com", acc().voicemailTarget)
        assertEquals("sip:vm@other.org", acc { copy(voicemailURI = "sip:vm@other.org") }.voicemailTarget)
        assertNull(acc { copy(voicemailURI = "  ") }.voicemailTarget)
    }

    @Test fun aNewAccountIsNamedAfterItsServerNotItsDisplayName() {
        val a = Account(username = "7001", displayName = "frank").finishedNew("pbx.example.com")
        assertEquals("pbx.example.com", a.label); assertEquals("frank", a.displayName)
    }

    @Test fun autoAnswerIsOffUnlessSwitchedOnAndTheListLimitsWho() {
        assertFalse(Account().mayAutoAnswer("7001"))
        val on = Account(autoAnswer = true); assertTrue(on.mayAutoAnswer("7001"))
        val listed = on.copy(autoAnswerFrom = "7001, (651) 760-4266")
        assertTrue(listed.mayAutoAnswer("7001")); assertFalse(listed.mayAutoAnswer("7002")); assertTrue(listed.mayAutoAnswer("16517604266")); assertFalse(listed.mayAutoAnswer("6125550142"))
    }
}
