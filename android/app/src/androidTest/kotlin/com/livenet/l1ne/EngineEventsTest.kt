package com.livenet.l1ne

import android.os.Handler
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.data.*
import com.livenet.l1ne.sip.SipEngine
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The engine's brain without a network: feed it the events PJSIP would send (a call ringing, answered, ended; a text; a voicemail
 * count) and check what it keeps: the call list, the call log, the messages. State numbers are PJSIP's: 1 calling, 2 incoming,
 * 3 early (ringing), 4 connecting, 5 confirmed, 6 disconnected. The fields of the last argument are role|status|reason|seconds|media|account.
 */
@RunWith(AndroidJUnit4::class)
class EngineEventsTest {
    private val ctx = TestContext()
    private lateinit var accounts: AccountStore
    private lateinit var log: CallLogStore
    private lateinit var messages: MessageStore
    private lateinit var engine: SipEngine
    private lateinit var account: Account

    @Before fun setUp() {
        accounts = AccountStore(ctx); log = CallLogStore(ctx); messages = MessageStore(ctx)
        account = Account(label = "Test", domain = "pbx.example.com", username = "7101"); accounts.save(account, "pw")
        runMain {
            engine = SipEngine(ctx, accounts, AppSettings(ctx)).also { it.callLog = log; it.messages = messages; it.accOfPJ[0] = account.id }
        }
    }
    @After fun tearDown() = ctx.cleanup()

    private fun runMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    private fun event(type: String, id: Int, state: Int, remote: String = "\"Jordan Lee\" <sip:7201@pbx.example.com>", fields: String) = runMain { engine.event(type, id, state, remote, fields) }
    private fun incoming(id: Int) = event("incoming", id, 2, fields = "1|0||0|0|0")
    private fun settle(ms: Long) { val l = CountDownLatch(1); Handler(Looper.getMainLooper()).postDelayed({ l.countDown() }, ms); l.await() }

    @Test fun anIncomingCallAppearsIsAnsweredAndLogged() {
        incoming(7)
        val c = engine.calls.value.single()
        assertTrue(c.incoming); assertFalse(c.active); assertEquals("7201", c.number); assertEquals("7201@pbx.example.com", c.peerAddress); assertEquals(account.id, c.accountID)
        event("call", 7, 5, fields = "1|200|OK|0|1|0"); assertTrue(engine.calls.value.single().active)
        event("call", 7, 6, fields = "1|200|OK|12|1|0")
        assertTrue(engine.calls.value.isEmpty())
        val r = log.records.value.single(); assertEquals(Direction.INCOMING, r.direction); assertEquals(12, r.duration); assertEquals("7201@pbx.example.com", r.peer); assertEquals(account.id, r.accountID)
    }
    @Test fun anUnansweredIncomingCallIsMissed_aDeclinedOneIsNot() {
        incoming(1); event("call", 1, 6, fields = "1|487|Request Terminated|0|0|0")
        assertEquals(Direction.MISSED, log.records.value.first().direction)
        incoming(2); runMain { engine.hangup(2) }; event("call", 2, 6, fields = "1|603|Decline|0|0|0")
        assertEquals(Direction.INCOMING, log.records.value.first().direction); assertEquals(0, log.records.value.first().duration)      // shown as Declined
        assertEquals(2, log.records.value.size)
    }
    @Test fun anOutgoingCallIsLoggedWhetherOrNotItWasAnswered() {
        event("call", 3, 1, fields = "0|0||0|0|0"); assertFalse(engine.calls.value.single().incoming)
        event("call", 3, 5, fields = "0|200|OK|0|1|0"); event("call", 3, 6, fields = "0|200|OK|31|1|0")
        assertEquals(Direction.OUTGOING, log.records.value.first().direction); assertEquals(31, log.records.value.first().duration)
        event("call", 4, 3, fields = "0|180|Ringing|0|0|0"); event("call", 4, 6, fields = "0|486|Busy Here|0|0|0")
        assertEquals(Direction.OUTGOING, log.records.value.first().direction); assertEquals(0, log.records.value.first().duration)
        assertEquals(2, log.records.value.size)
    }
    @Test fun twoCallsAreTrackedSeparately() {
        incoming(1); incoming(2); assertEquals(setOf(1, 2), engine.calls.value.map { it.id }.toSet())
        event("call", 1, 6, fields = "1|200|OK|5|1|0"); assertEquals(listOf(2), engine.calls.value.map { it.id })
        assertEquals(2, engine.currentCall?.id)
    }
    @Test fun aFailedOutgoingCallAfterANetworkChangeIsRedialledNotLogged() {
        val target = SipEngine.Redial("7001", null, account.id, 0)
        runMain { engine.outgoingTargets[5] = target; engine.lastNetworkEvent = System.currentTimeMillis() }
        event("call", 5, 1, fields = "0|0||0|0|0")
        event("call", 5, 6, fields = "0|503|Service Unavailable|0|0|0")        // the old connection died under it
        settle(3200)
        assertTrue(log.records.value.isEmpty(), "the dropped attempt must not appear in Recents")
    }
    @Test fun aServerErrorWithNoNetworkChangeIsJustLogged() {
        runMain { engine.outgoingTargets[6] = SipEngine.Redial("7001", null, account.id, 0); engine.lastNetworkEvent = 0 }
        event("call", 6, 1, fields = "0|0||0|0|0"); event("call", 6, 6, fields = "0|503|Service Unavailable|0|0|0")
        settle(3200)
        assertEquals(Direction.OUTGOING, log.records.value.single().direction)
    }
    @Test fun aRedialIsOnlyEverTriedOnce() {
        runMain { engine.outgoingTargets[8] = SipEngine.Redial("7001", null, account.id, 1); engine.lastNetworkEvent = System.currentTimeMillis() }
        event("call", 8, 1, fields = "0|0||0|0|0"); event("call", 8, 6, fields = "0|503|Service Unavailable|0|0|0")
        settle(3200); assertEquals(1, log.records.value.size)
    }
    @Test fun registrationStatusIsShownAsText() {
        runMain { engine.event("reg", 0, 200, "OK", "") }; assertEquals("Registered", engine.registration.value[account.id])
        runMain { engine.event("reg", 0, 403, "Forbidden", "") }; assertEquals("Not registered: 403 Forbidden", engine.registration.value[account.id])
        runMain { engine.event("reg", 0, 100, "Trying", "") }; assertEquals("Registering…", engine.registration.value[account.id])
    }
    @Test fun incomingTextsAreStoredUnread_andOurOwnCheckTextIsSwallowed() {
        runMain { engine.event("message", 0, 0, "\"Jordan\" <sip:7201@PBX.example.com>", "hello there") }
        val c = messages.conversation(account.id, "7201@pbx.example.com")!!
        assertEquals("hello there", c.last!!.text); assertFalse(c.last!!.outgoing); assertEquals(1, c.unread)
        runMain { engine.event("message", 99, 0, "<sip:7201@pbx.example.com>", "x") }       // an account we don't have: ignored
        assertEquals(1, messages.conversations.value.size)
    }
    @Test fun theVoicemailCountIsKeptPerAccount() {
        runMain { engine.event("mwi", 0, 3, "", "") }; assertEquals(3, engine.voicemail.value[account.id])
        runMain { engine.event("mwi", 0, 0, "", "") }; assertEquals(0, engine.voicemail.value[account.id])
    }
    @Test fun callSecondsCountFromWhenItConnected() {
        incoming(9); assertEquals(0, engine.elapsed(9))
        event("call", 9, 5, fields = "1|200|OK|0|1|0"); settle(2200); assertTrue(engine.elapsed(9) in 2..3, "elapsed ${engine.elapsed(9)}")
        event("call", 9, 6, fields = "1|200|OK|2|1|0"); assertEquals(0, engine.elapsed(9))
        assertNull(engine.calls.value.firstOrNull())
    }
}
