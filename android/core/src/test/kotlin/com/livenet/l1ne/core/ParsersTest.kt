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

    @Test fun provisioning() {
        val r = Provisioning.parse(File(dir, "linphone-provision.xml").readBytes())
        assertEquals(2, r.accounts.size)
        assertTrue(r.accounts[1].pushOnly && r.accounts[1].account.domain == "sip.linphone.org" && !r.accounts[0].pushOnly)
        val a = r.accounts[0]
        assertEquals("7201", a.account.username)
        assertEquals("Max Example", a.account.displayName)   // the name in the QR/link is kept
        assertEquals("pbx.example.com", a.account.domain)
        assertEquals(5061, a.account.port)
        assertEquals(Transport.TLS, a.account.transport)
        assertEquals("pbx.example.com", a.account.label)
        assertEquals(1, r.selectedByDefault.size)
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
