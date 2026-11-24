package com.livenet.l1ne

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Media
import com.livenet.l1ne.core.Transport
import com.livenet.l1ne.core.VCard
import com.livenet.l1ne.data.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(AndroidJUnit4::class)
class StoresTest {
    private val ctx = TestContext()
    @After fun tearDown() = ctx.cleanup()

    // MARK: accounts

    @Test fun accountsKeepEveryFieldAndTheirSecretsApart() {
        val s = AccountStore(ctx)
        val a = Account(label = "Work", displayName = "Kai", domain = "pbx.example.com", port = 5080, transport = Transport.TCP, media = Media.SRTP_DTLS, mediaMandatory = false,
            username = "7101", authUser = "auth7101", expires = 600, enabled = false, intlPrefix = "1", formatWithPrefix = true, plusTo00 = true, voicemailURI = "8500",
            mwiEnabled = false, iceEnabled = true, turnEnabled = true, stunServer = "stun.example.com:3478", turnUser = "turner", dialStripPrefix = "9", dialAddPrefix = "0")
        s.save(a, "s3cret"); s.saveTurnSecret(a.id, "turnpw")
        val again = AccountStore(ctx)                                          // a fresh store reads what was saved
        assertEquals(listOf(a), again.accounts.value)
        assertEquals("s3cret", again.secret(a.id)); assertEquals("turnpw", again.turnSecret(a.id))
        assertEquals("", again.secret("nobody"))
    }
    @Test fun savingWithoutASecretKeepsTheOldOne_andRemovingDeletesIt() {
        val s = AccountStore(ctx); val a = Account(domain = "d", username = "u")
        s.save(a, "one"); s.save(a.copy(label = "renamed"), null)
        assertEquals("one", s.secret(a.id)); assertEquals("renamed", s.accounts.value.single().label)
        s.remove(a.id); assertTrue(s.accounts.value.isEmpty()); assertEquals("", s.secret(a.id))
    }
    @Test fun selectedAccountFallsBackToTheFirst() {
        val s = AccountStore(ctx); val a = Account(domain = "a", username = "1"); val b = Account(domain = "b", username = "2")
        s.save(a, "x"); s.save(b, "y")
        assertEquals(a.id, s.selected?.id); s.select(b.id); assertEquals(b.id, AccountStore(ctx).selected?.id)
        s.remove(b.id); assertEquals(a.id, s.selected?.id)
    }

    // MARK: call log

    @Test fun callLogKeepsTheNewestFirstAndCapsAtFiveHundred() {
        val log = CallLogStore(ctx)
        for (i in 1..510) log.add(CallRecord(peer = "p$i@x", accountID = null, direction = Direction.OUTGOING, duration = i))
        assertEquals(500, log.records.value.size); assertEquals("p510@x", log.records.value.first().peer)
        assertEquals(500, CallLogStore(ctx).records.value.size)               // persisted
    }
    @Test fun callLogDeletesOneOrAllOrAnAccountsCalls() {
        val log = CallLogStore(ctx); val r1 = CallRecord(peer = "a@x", accountID = "A", direction = Direction.MISSED, duration = 0)
        val r2 = CallRecord(peer = "b@x", accountID = "B", direction = Direction.INCOMING, duration = 9)
        log.add(r1); log.add(r2)
        log.removeAccount("A"); assertEquals(listOf(r2.id), log.records.value.map { it.id })
        log.add(r1); log.delete(r2.id); assertEquals(listOf(r1.id), log.records.value.map { it.id })
        log.removeAll(); assertTrue(CallLogStore(ctx).records.value.isEmpty())
    }

    // MARK: contacts

    private fun vcard(vararg e: Pair<String, String>, skipped: Int = 0) = VCard.Result(e.map { VCard.Entry(it.first, it.second) }, skipped)

    @Test fun importsNeverOverwriteWhatYouTypedIn() {
        val c = ContactsStore(ctx)
        assertTrue(c.add("My Jordan", "7201@pbx.example.com", null))
        val sum = c.merge(vcard("Jordan Lee" to "7201@pbx.example.com", "Alex Example" to "7202@pbx.example.com"), "acc")
        assertEquals(1, sum.added); assertEquals(1, sum.kept)
        assertEquals(listOf("Alex Example", "My Jordan"), c.contacts.value.map { it.name })      // sorted, and your name for 7201 won
        val again = c.merge(vcard("Alex Renamed" to "7202@pbx.example.com"), "acc")
        assertEquals(1, again.updated); assertEquals("Alex Renamed", c.contacts.value.first { it.address.startsWith("7202") }.name)
    }
    @Test fun aSyncedDirectoryMakesItsContactsMatchExactlyAndLeavesOthersAlone() {
        val c = ContactsStore(ctx)
        c.add("Typed", "7000@pbx.example.com", null); c.merge(vcard("Link One" to "7301@pbx.example.com"), null, "link")
        val s1 = c.replaceSource("dir:1", vcard("Dir A" to "7401@pbx.example.com", "Dir B" to "7402@pbx.example.com", "Link One" to "7301@pbx.example.com"), "acc")
        assertEquals(2, s1.added); assertEquals(1, s1.kept)                                       // Link One already exists: not stolen
        val s2 = c.replaceSource("dir:1", vcard("Dir A2" to "7401@pbx.example.com"), "acc")
        assertEquals(1, s2.updated); assertEquals(1, s2.removed)                                  // B left the directory
        assertEquals(setOf("Typed", "Link One", "Dir A2"), c.contacts.value.map { it.name }.toSet())
        c.deleteSource("dir:1"); assertEquals(setOf("Typed", "Link One"), c.contacts.value.map { it.name }.toSet())
        assertEquals(1, c.removeLinkImports()); assertEquals(listOf("Typed"), c.contacts.value.map { it.name })
    }
    @Test fun addRejectsAddressesWithoutAServer() {
        val c = ContactsStore(ctx)
        assertFalse(c.add("Nope", "", null)); assertTrue(c.contacts.value.isEmpty())
        assertTrue(c.add("", "sip:7500@pbx.example.com", null)); assertEquals("7500@pbx.example.com", c.contacts.value.single().name)   // no name: the address stands in
    }
    @Test fun namesAreFoundByExtensionOnTheSameServerThenAnyServerThenByLastTenDigits() {
        val c = ContactsStore(ctx)
        c.add("Jordan", "7201@pbx.example.com", null); c.add("Other Jordan", "7201@elsewhere.org", null); c.add("Alex", "7300@pbx.example.com", null)
        c.add("Cell Phone", "16125551234@pbx.example.com", null)
        assertEquals("Jordan", c.name("7201", "pbx.example.com")); assertEquals("Other Jordan", c.name("7201", "elsewhere.org"))
        assertNull(c.name("7201", "third.net"))                                                    // two people share it and neither is on that server: ambiguous
        assertEquals("Jordan", c.name("7201"))                                                     // no server given: the first match, same as on iOS
        assertEquals("Alex", c.name("7300", "unknown.net")); assertEquals("Alex", c.name("sip:7300"))
        assertEquals("Cell Phone", c.name("+1 612 555 1234".filter { it.isDigit() || it == '+' }, "x.net"))
        assertEquals("Cell Phone", c.name("6125551234", "x.net")); assertNull(c.name("9999"))
    }
    @Test fun contactsSurviveARestart() {
        ContactsStore(ctx).add("Kept", "7777@pbx.example.com", "acc-1")
        val back = ContactsStore(ctx).contacts.value.single()
        assertEquals("Kept", back.name); assertEquals("acc-1", back.accountID); assertFalse(back.imported)
    }

    // MARK: messages

    @Test fun messagesGroupByAccountAndPeerAndTrackUnread() {
        val m = MessageStore(ctx)
        m.add(Message(outgoing = false, text = "hi", read = false), "A", "7001@x"); m.add(Message(outgoing = false, text = "again", read = false), "A", "7001@X")     // peer is case-insensitive
        m.add(Message(outgoing = true, text = "hello"), "B", "7001@x")
        assertEquals(2, m.conversations.value.size); assertEquals(2, m.unread)
        m.markRead("A", "7001@x"); assertEquals(0, m.unread)
        assertEquals(2, MessageStore(ctx).conversation("A", "7001@x")!!.messages.size)            // persisted
    }
    @Test fun aFailedSendCanBeRetriedAndDeletingTheLastMessageDropsTheConversation() {
        val m = MessageStore(ctx); val id = m.add(Message(outgoing = true, text = "x", status = MsgStatus.SENDING), "A", "7002@x")
        m.update(id, MsgStatus.FAILED, "404 Not Found")
        assertEquals(MsgStatus.FAILED, m.conversation("A", "7002@x")!!.last!!.status); assertEquals("404 Not Found", m.conversation("A", "7002@x")!!.last!!.failure)
        m.remove(id); assertNull(m.conversation("A", "7002@x")); assertTrue(m.conversations.value.isEmpty())
    }
    @Test fun conversationsAreOrderedByTheirLatestMessageAndRemovedWithTheirAccount() {
        val m = MessageStore(ctx)
        m.add(Message(date = 1000, outgoing = true, text = "old"), "A", "a@x"); m.add(Message(date = 3000, outgoing = true, text = "new"), "B", "b@x"); m.add(Message(date = 2000, outgoing = true, text = "mid"), "A", "c@x")
        assertEquals(listOf("b@x", "c@x", "a@x"), m.conversations.value.map { it.peer })
        m.removeAccount("A"); assertEquals(listOf("b@x"), m.conversations.value.map { it.peer })
        m.delete(listOf(Conversation.key("B", "b@x"))); assertTrue(m.conversations.value.isEmpty())
    }

    // MARK: directories and settings

    @Test fun directorySourcesKeepTheirSettingsAndPasswords() {
        val accounts = AccountStore(ctx); val dirs = DirectoryStore(ctx, accounts)
        val d = DirectorySource(kind = DirKind.LDAP, name = "Company", host = "ldap.example.com", baseDN = "dc=example,dc=com", interval = SyncInterval.HOURLY, phoneAsExtension = true)
        dirs.save(d, "pw"); dirs.update(d.id) { it.copy(lastResult = "ok", enabled = false) }
        val back = DirectoryStore(ctx, accounts).sources.value.single()
        assertEquals(d.copy(lastResult = "ok", enabled = false), back); assertEquals("pw", dirs.password(d.id))
        assertTrue(back.isDirectory); assertFalse(DirectoryStore(ctx, accounts).directoryEnabled)
        dirs.remove(d.id); assertTrue(DirectoryStore(ctx, accounts).sources.value.isEmpty())
    }
    @Test fun settingsHaveSaneDefaultsAndPersist() {
        val s = AppSettings(ctx)
        assertFalse(s.acceptEarlyMedia); assertEquals(com.livenet.l1ne.sip.RingbackTone.UK, s.ringback); assertTrue(s.allowIPv6); assertTrue(s.keepAlive)
        assertTrue(s.showKeypadVoicemail); assertFalse(s.showVoicemailTab); assertEquals(Appearance.SYSTEM, s.appearance)
        s.ringback = com.livenet.l1ne.sip.RingbackTone.CHIME; s.appearance = Appearance.LIGHT; s.codecOrder = listOf("PCMA/8000/1", "PCMU/8000/1"); s.codecsOff = setOf("GSM/8000/1")
        val back = AppSettings(ctx)
        assertEquals(com.livenet.l1ne.sip.RingbackTone.CHIME, back.ringback); assertEquals(Appearance.LIGHT, back.appearance)
        assertEquals(listOf("PCMA/8000/1", "PCMU/8000/1"), back.codecOrder); assertEquals(setOf("GSM/8000/1"), back.codecsOff)
    }
}
