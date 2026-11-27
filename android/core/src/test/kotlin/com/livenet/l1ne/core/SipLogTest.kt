package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SipLogTest {
    @Test fun authorizationHeadersAreRemoved() {
        val msg = "REGISTER sip:pbx.example.com SIP/2.0\r\nAuthorization: Digest username=\"7001\", realm=\"asterisk\", response=\"0123456789abcdef\"\r\nCSeq: 2 REGISTER"
        val out = LogRedactor.clean(msg)
        assertFalse(out.contains("0123456789abcdef")); assertFalse(out.contains("realm"))
        assertTrue(out.contains("Authorization: [removed]")); assertTrue(out.contains("CSeq: 2 REGISTER"))
        assertTrue(LogRedactor.clean("Proxy-Authorization: Digest response=\"abc\"").contains("Proxy-Authorization: [removed]"))
    }
    @Test fun srtpKeysAreRemoved() {
        val out = LogRedactor.clean("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:WVNfX19zZWNyZXRrZXlfX19fX19fX19fX19fX19fX19fX19f\na=rtpmap:0 PCMU/8000")
        assertFalse(out.contains("WVNf")); assertTrue(out.contains("inline:[removed]")); assertTrue(out.contains("a=rtpmap:0 PCMU/8000"))
    }
    @Test fun anythingThatLooksLikeASecretIsRemoved() {
        assertEquals("password=[removed] next", LogRedactor.clean("password=hunter2 next"))
        assertEquals("secret: [removed]", LogRedactor.clean("secret: abc"))
        assertEquals("cnonce=\"[removed]\"", LogRedactor.clean("cnonce=\"zzz\""))
    }
    @Test fun ordinaryLinesAreUntouched() {
        val line = "From: \"(612) 354-0645\" <sip:6123540645@pbx.example.com>;tag=abc"
        assertEquals(line, LogRedactor.clean(line))
    }
    @Test fun theLogKeepsTheLastEntriesAndRedactsOnTheWay() {
        SipLog.clear()
        repeat(2600) { SipLog.add("line $it") }
        assertEquals(2500, SipLog.count()); assertTrue(SipLog.text().startsWith("line 100")); assertTrue(SipLog.text().endsWith("line 2599"))
        SipLog.clear(); SipLog.add("Authorization: Digest response=\"x\""); assertEquals("Authorization: [removed]", SipLog.text())
        SipLog.add("   "); assertEquals(1, SipLog.count()); SipLog.clear(); assertEquals(0, SipLog.count())
    }
}
