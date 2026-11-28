package com.livenet.l1ne.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith

/** Mirrors tests/parsers/main.swift and reads the same fixtures. */
class ParsersTest {
    private val dir = File(System.getProperty("fixtures"))

    @Test fun vcard() {
        val v = VCard.parse(File(dir, "contacts.vcf").readText())
        assertEquals(3, v.entries.size)
        assertEquals(1, v.skipped)
        assertEquals(VCard.Entry("Jordan Lee", "7201@pbx.example.com"), v.entries.first())
        assertTrue(v.entries.any { it.name == "FoldedName Person" && it.address == "alice@sip.example.com" })
        assertTrue(v.entries.any { it.name == "Jane Doe" && it.address == "jane@example.org" })
        assertTrue(v.entries.none { it.address.contains("+1612") })
    }

    @Test fun theL1neSectionSetsTheOutsideLinePrefix() {
        val xml = File(dir, "linphone-provision.xml").readText().replace("</config>", "<section name=\"l1ne\"><entry name=\"outbound_prefix\">9</entry></section></config>")
        val r = Provisioning.parse(xml.toByteArray())
        assertEquals("9", r.accounts[0].account.outboundPrefix)
        assertEquals("9", r.accounts[1].account.outboundPrefix)                                  // the l1ne section is the default for every account in the file
        val base = File(dir, "linphone-provision.xml").readText(); val sendRegister = "<entry name=\"reg_sendregister\" overwrite=\"true\">1</entry>"
        val own = Provisioning.parse(base.replace(sendRegister, sendRegister + "<entry name=\"l1ne_outbound_prefix\">9</entry>").toByteArray())
        assertEquals("9", own.accounts[0].account.outboundPrefix); assertEquals("", own.accounts[1].account.outboundPrefix)   // one account's own section: that account only
        val none = Provisioning.parse(xml.replace(sendRegister, sendRegister + "<entry name=\"l1ne_outbound_prefix\"></entry>").toByteArray())
        assertEquals("", none.accounts[0].account.outboundPrefix); assertEquals("9", none.accounts[1].account.outboundPrefix)   // an empty own entry beats the default
        val bad = Provisioning.parse(xml.replace(">9<", ">9x<").toByteArray())
        assertEquals("", bad.accounts[0].account.outboundPrefix)                                  // digits, * and # only
        assertEquals("", Provisioning.parse(File(dir, "linphone-provision.xml").readBytes()).accounts[0].account.outboundPrefix)   // a plain Linphone file sets nothing
    }

    @Test fun provisioning() {
        val r = Provisioning.parse(File(dir, "linphone-provision.xml").readBytes())
        assertEquals(2, r.accounts.size)
        assertEquals("sip.linphone.org", r.accounts[1].account.domain)                          // the linphone.org account is returned like any other, and added with the rest
        val a = r.accounts[0]
        assertEquals("7201", a.account.username)
        assertEquals("Max Example", a.account.displayName)   // the name in the QR/link is kept
        assertEquals("pbx.example.com", a.account.domain)
        assertEquals(5061, a.account.port)
        assertEquals(Transport.TLS, a.account.transport)
        assertEquals("pbx.example.com", a.account.label)
        assertEquals("test-secret-not-real", a.secret)
        assertEquals("https://pbx.example.com/p/contacts-0123456789abcdef0123456789abcdef.vcf", r.contactsUrl)
        assertEquals("another-fake", r.accounts[1].secret)
    }

    @Test fun links() {
        assertEquals("https://pbx.example.com/p/x.xml", Provisioning.configUrl("linphone-config:https://pbx.example.com/p/x.xml").toString())
        assertEquals("a.b", Provisioning.configUrl(" l1ne-config:https://a.b/c.xml ")?.host)
        assertNotNull(Provisioning.configUrl("https://a.b/c.xml"))
        assertNull(Provisioning.configUrl("http://a.b/c.xml"))
        assertNull(Provisioning.configUrl("sip:7201@a.b"))
        assertFailsWith<Provisioning.Failure> { Provisioning.parse("<html></html>".toByteArray()) }
    }

    @Test fun provisioningReadsEncryptionExpiryAndVoicemail() {
        fun parse(sip: String, proxy: String = "") = Provisioning.parse(("<config><section name=\"proxy_0\"><entry name=\"reg_identity\">sip:1@h.example</entry><entry name=\"reg_proxy\">sip:h.example;transport=tls</entry>$proxy</section>" +
            "<section name=\"auth_info_0\"><entry name=\"username\">1</entry><entry name=\"passwd\">x</entry></section><section name=\"sip\">$sip</section></config>").toByteArray())
        val d = parse("<entry name=\"media_encryption\">dtls</entry><entry name=\"media_encryption_mandatory\">1</entry>", "<entry name=\"reg_expires\">1800</entry><entry name=\"voicemail_uri\">sip:*98@h.example</entry>").accounts.first().account
        assertEquals(Media.SRTP_DTLS, d.media); assertTrue(d.mediaMandatory); assertEquals(1800, d.expires); assertEquals("sip:*98@h.example", d.voicemailURI)
        val z = parse("<entry name=\"media_encryption\">zrtp</entry>")
        assertEquals(Media.ZRTP, z.accounts.first().account.media); assertFalse(z.accounts.first().account.mediaMandatory); assertTrue(z.notes.none { "ZRTP" in it })
    }

    @Test fun callerIdIsKeptOnlyWhenItIsAName() {
        assertEquals("Ada Lovelace", SipAddress.callerIdName("\"Ada Lovelace\" <sip:6125550142@pbx.example.com>"))
        assertEquals("", SipAddress.callerIdName("\"6125550142\" <sip:6125550142@pbx.example.com>")); assertEquals("", SipAddress.callerIdName("\"(612) 555-0142\" <sip:6125550142@pbx.example.com>"))
        assertEquals("", SipAddress.callerIdName("<sip:7001@pbx.example.com>")); assertEquals("", SipAddress.callerIdName("sip:7001@pbx.example.com"))
    }

    @Test fun callsWithTheSamePersonAreMatched() {
        assertTrue(CallHistory.sameParty("7001@pbx.example.com", "7001@PBX.example.com")); assertTrue(CallHistory.sameParty("6517604266", "6517604266@pbx.example.com"))
        assertTrue(CallHistory.sameParty("16517604266@pbx", "(651) 760-4266")); assertTrue(CallHistory.sameParty("sip:7001@pbx", "7001"))
        assertFalse(CallHistory.sameParty("7001@pbx", "7002@pbx")); assertFalse(CallHistory.sameParty("7001@pbx", "7001@other"))
    }
}
