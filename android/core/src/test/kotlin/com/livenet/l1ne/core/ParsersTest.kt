package com.livenet.l1ne.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
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
}
