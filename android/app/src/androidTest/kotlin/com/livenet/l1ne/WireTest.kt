package com.livenet.l1ne

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Media
import com.livenet.l1ne.core.Transport
import com.livenet.l1ne.data.*
import com.livenet.l1ne.sip.SipEngine
import org.junit.After
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.net.Socket
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlin.test.assertTrue

/**
 * L1ne's real SIP engine (PJSIP, not a stand-in) against the fake PBX in `tests/mock/pbx.py`, which has to be running on the computer
 * (`tests/mock/run-android-wire-tests.sh` does that). Each test registers an account, does one thing, and checks both what the engine
 * reports and what the server saw on the wire. The extension or number used picks the scenario; see the header of pbx.py.
 * The emulator reaches the computer as 10.0.2.2 (pass `-e pbx <ip>` to the runner for a phone on Wi-Fi).
 */
@RunWith(AndroidJUnit4::class)
class WireTest {
    @get:Rule val perms: GrantPermissionRule = GrantPermissionRule.grant(android.Manifest.permission.RECORD_AUDIO)

    companion object {
        private val args = InstrumentationRegistry.getArguments()
        val host: String = args.getString("pbx") ?: "10.0.2.2"
        lateinit var accounts: AccountStore; lateinit var settings: AppSettings; lateinit var engine: SipEngine
        lateinit var messages: MessageStore; lateinit var callLog: CallLogStore

        /** PJSIP can only be started once per process and the app has already started it, so the tests drive the app's own engine and stores.
         *  Run them on an emulator or a spare phone: they add and remove their own accounts but also touch the codec settings. */
        @BeforeClass @JvmStatic fun boot() {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as com.livenet.l1ne.L1neApplication
            accounts = app.store; settings = app.settings; messages = app.messages; callLog = app.callLog; engine = app.engine
            InstrumentationRegistry.getInstrumentation().runOnMainSync { engine.start(); accounts.accounts.value.toList().forEach { engine.unregister(it.id); accounts.remove(it.id) } }   // a clean slate: PJSIP has a fixed number of account slots
        }
    }

    private val made = ArrayList<Account>()
    private fun main(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    /** An account for the fake PBX, not saved anywhere. */
    private fun draft(user: String, transport: Transport = Transport.TCP, media: Media = Media.NONE, build: (Account) -> Account = { it }): Account =
        build(Account(label = "mock $user", domain = host, username = user, media = media, mediaMandatory = false).withTransport(transport))
    private fun account(user: String, password: String = "secret", transport: Transport = Transport.TCP, media: Media = Media.NONE, build: (Account) -> Account = { it }): Account {
        val a = draft(user, transport, media, build); accounts.save(a, password); made += a; return a
    }
    private fun register(a: Account) { main { engine.register(a) } }
    private fun status(a: Account) = engine.registration.value[a.id].orEmpty()
    private fun dial(a: Account, number: String) { var ok = false; main { ok = engine.call(number, a) }; assertTrue(ok, "the engine refused to place the call to $number") }
    private fun registered(a: Account): Account { register(a); waitFor("register ${a.username}") { status(a) == "Registered" }; return a }
    private fun onlyCall() = engine.calls.value.singleOrNull()

    private fun waitFor(what: String, seconds: Int = 10, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + seconds * 1000L
        while (System.currentTimeMillis() < end) { if (cond()) return; Thread.sleep(100) }
        throw AssertionError("timed out waiting for: $what\n--- server log ---\n${serverLog()}")
    }
    /** The fake PBX's log (plain HTTP over a raw socket: the app's network rules forbid cleartext through the normal URL classes). */
    private fun http(path: String): String = Socket(host, 8099).use { s ->
        s.soTimeout = 5000; s.getOutputStream().apply { write("GET $path HTTP/1.0\r\nHost: x\r\n\r\n".toByteArray()); flush() }
        s.getInputStream().readBytes().decodeToString().substringAfter("\r\n\r\n")
    }
    private fun serverLog() = http("/log")
    private fun serverSaw(text: String) = serverLog().contains(text)
    private fun waitServer(text: String, seconds: Int = 10) = waitFor("the server to log \"$text\"", seconds) { serverSaw(text) }

    @Before fun fresh() { waitFor("no calls left over") { engine.calls.value.isEmpty() }; http("/clear"); settings.codecsOff = emptySet(); main { engine.applyCodecs() } }
    @After fun cleanUp() {
        main { engine.hangupAll() }; Thread.sleep(400)
        made.forEach { a -> main { engine.unregister(a.id) }; accounts.remove(a.id) }; made.clear()
    }

    // ---------------- registration ----------------
    @Test fun registersWithADigestLogin() { val a = registered(account("7100")); assertTrue(serverSaw("401 challenge")); assertTrue(serverSaw("REGISTER 7100 -> 200 OK")); assertEquals("Registered", status(a)) }
    @Test fun aWrongPasswordIsRefused() { val a = account("7100", password = "nope"); register(a); waitFor("403") { status(a).contains("403") }; assertTrue(status(a).startsWith("Not registered")) }
    @Test fun anUnknownExtensionIsRefused() { val a = account("7104"); register(a); waitFor("404") { status(a).contains("404") } }
    @Test fun aServerThatIsDownIsReported() { val a = account("7105"); register(a); waitFor("503") { status(a).contains("503") } }
    @Test fun aServerThatNeverAnswersStaysRegistering() { val a = account("7106"); register(a); Thread.sleep(4000); assertEquals("Registering…", status(a)) }
    @Test fun registersOverUdpToo() { registered(account("7100", transport = Transport.UDP)); assertTrue(serverSaw("via=udp")) }
    @Test fun aDisabledAccountDoesNotRegister() { val a = account("7100") { it.copy(enabled = false) }; register(a); Thread.sleep(1500); assertEquals("Off", status(a)); assertFalse(serverSaw("REGISTER")) }

    // ---------------- calls ----------------
    @Test fun anOutgoingCallIsAnsweredHeldResumedAndHungUp() {
        val a = registered(account("7100")); dial(a, "1001")
        waitFor("call answered") { onlyCall()?.active == true }; assertTrue(serverSaw("INVITE 1001")); waitServer("ACK")
        val id = onlyCall()!!.id
        main { engine.toggleHold(id) }; waitServer("dir=sendonly"); assertTrue(id in engine.held.value)
        main { engine.toggleHold(id) }; waitServer("dir=sendrecv")
        main { engine.hangup(id) }; waitServer("BYE"); waitFor("call gone") { engine.calls.value.isEmpty() }
        assertEquals(Direction.OUTGOING, callLog.records.value.first().direction)
    }
    @Test fun aBusyNumberEndsTheCall() { val a = registered(account("7100")); dial(a, "1002"); waitServer("486 Busy"); waitFor("call gone") { engine.calls.value.isEmpty() } }
    @Test fun aDeclinedCallEndsTheCall() { val a = registered(account("7100")); dial(a, "1006"); waitServer("603 Decline"); waitFor("call gone") { engine.calls.value.isEmpty() } }
    @Test fun anUnknownNumberEndsTheCall() { val a = registered(account("7100")); dial(a, "1005"); waitServer("-> 404"); waitFor("call gone") { engine.calls.value.isEmpty() } }
    @Test fun aRingingCallCanBeCancelled() {
        val a = registered(account("7100")); dial(a, "1004")
        waitFor("ringing") { onlyCall()?.let { it.state == 3 && it.ringing } == true }
        main { engine.hangup(onlyCall()!!.id) }; waitServer("CANCEL"); waitFor("call gone") { engine.calls.value.isEmpty() }
    }
    @Test fun earlyMediaThenAnswerWorks() { val a = registered(account("7100")); dial(a, "1003"); waitServer("183 early media"); waitFor("answered") { onlyCall()?.active == true } }
    @Test fun aCallCanBeTransferred() {
        val a = registered(account("7100")); dial(a, "1001"); waitFor("answered") { onlyCall()?.active == true }
        main { engine.transfer(onlyCall()!!.id, "7200", a) }; waitServer("REFER Refer-To: sip:7200@$host")
    }
    @Test fun aTransferShowsItsProgressAndThenTheCallEnds() {
        val a = registered(account("7100")); dial(a, "1001"); waitFor("answered") { onlyCall()?.active == true }
        val id = onlyCall()!!.id
        main { assertTrue(engine.transfer(id, "7200", a)) }
        assertTrue(engine.transferNote.value[id]?.startsWith("Transferring") == true, "the call screen says a transfer is under way as soon as it is asked for")
        waitFor("the call to end once the other side has taken over") { engine.calls.value.isEmpty() }
    }
    @Test fun aFailedTransferSaysSoAndTheCallGoesOn() {
        val a = registered(account("7100")); dial(a, "1001"); waitFor("answered") { onlyCall()?.active == true }
        val id = onlyCall()!!.id
        main { assertTrue(engine.transfer(id, "7404", a)) }
        waitFor("the failure to be reported") { engine.transferNote.value[id]?.startsWith("Transfer failed: 404") == true }
        assertTrue(onlyCall()?.active == true, "the call is still there")
    }
    @Test fun aQuickHoldThenResumeEndsUpResumed() {                      // the second tap comes while the first is still being negotiated
        val a = registered(account("7100")); dial(a, "1001"); waitFor("answered") { onlyCall()?.active == true }
        val id = onlyCall()!!.id
        main { engine.toggleHold(id); engine.toggleHold(id) }
        waitFor("the resume to reach the server") { serverLog().let { it.contains("dir=sendonly") && it.contains("dir=sendrecv") } }
        assertTrue(id !in engine.held.value, "the call is not left on hold")
    }
    @Test fun theVoicemailButtonDialsTheVoicemailNumber() { val a = registered(account("7100")); main { engine.callVoicemail(a.id) }; waitServer("INVITE *97") }
    @Test fun dialRulesChangeWhatIsDialled() { val a = registered(account("7100") { it.copy(dialStripPrefix = "9") }); dial(a, "91001"); waitServer("INVITE 1001") }
    @Test fun theSipLogShowsTheMessagesWithoutSecrets() {
        com.livenet.l1ne.core.SipLog.clear()
        val a = registered(account("7100")); dial(a, "1001"); waitServer("INVITE 1001")
        waitFor("the log has the sign-in and the call") { val t = com.livenet.l1ne.core.SipLog.text(); t.contains("REGISTER sip:") && t.contains("INVITE sip:") }
        val t = com.livenet.l1ne.core.SipLog.text()
        assertTrue(t.contains("Authorization: [removed]"), "the digest header is removed")
        assertFalse(Regex("response=\"[0-9a-f]{8,}").containsMatchIn(t), "no digest response is left")
        assertFalse(t.contains("inline:") && !t.contains("inline:[removed]"), "no SRTP key is left")
    }
    private fun shell(cmd: String): String = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(cmd).let { fd -> java.io.FileInputStream(fd.fileDescriptor).bufferedReader().readText() }

    /** Android only applies the speaker / earpiece / Bluetooth choice Telecom makes when Telecom owns the call's audio mode. Setting the mode in the app made the app the owner and every route change was ignored. */
    @Test fun theAppIsNotTheAudioModeOwnerOfACallTelecomHas() {
        val a = registered(account("7100")); dial(a, "1001"); waitFor("answered") { onlyCall()?.active == true }
        Thread.sleep(1000)
        val dump = shell("dumpsys audio")
        val owner = Regex("""AudioModeInfo: mMode=\w+, mPid=(\d+)""").find(dump) ?: Regex("""mode owner[^\n]*mPid=(\d+)""", RegexOption.IGNORE_CASE).find(dump)
        org.junit.Assume.assumeTrue("this Android version's audio dump does not name the audio mode owner", owner != null)
        assertTrue(owner!!.groupValues[1].toInt() != android.os.Process.myPid(), "the app does not own the audio mode (pid ${owner.groupValues[1]})")
    }

    /** The speaker button: audio moves to the speaker through Telecom, and back to the earpiece. */
    @Test fun theSpeakerButtonSwitchesTheAudioToTheSpeakerAndBack() {
        val telecom = (InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as com.livenet.l1ne.L1neApplication).telecom
        val a = registered(account("7100")); dial(a, "1001"); waitFor("answered") { onlyCall()?.active == true }
        waitFor("Telecom to offer the speaker") { telecom.routes.value.supported and android.telecom.CallAudioState.ROUTE_SPEAKER != 0 }
        main { engine.setSpeaker(true) }; waitFor("the speaker is the active route") { telecom.routes.value.speaker }
        assertTrue(com.livenet.l1ne.core.SipLog.text().contains("[audio]"), "the route changes are in the SIP log")
        if (telecom.routes.value.supported and android.telecom.CallAudioState.ROUTE_EARPIECE != 0) {        // an emulator has no earpiece to go back to
            main { engine.setSpeaker(false) }; waitFor("the earpiece is the active route again") { !telecom.routes.value.speaker }
        }
    }
    @Test fun anIncomingCallRingsIsAnsweredAndHangsUp() {
        registered(account("7100")); http("/invite?user=7100")
        waitFor("incoming call") { onlyCall()?.incoming == true }
        waitFor("the phone rings") { com.livenet.l1ne.sip.Ringer.isRinging }          // ringtone and vibration start with the incoming call
        main { engine.answer(onlyCall()!!.id) }; waitFor("answered") { onlyCall()?.active == true }; waitServer("ACK to phone")
        waitFor("the ringing stops once it is answered") { !com.livenet.l1ne.sip.Ringer.isRinging }
        main { engine.hangup(onlyCall()!!.id) }; waitServer("BYE"); waitFor("call gone") { engine.calls.value.isEmpty() }
    }

    // ---------------- what goes on the wire ----------------
    @Test fun noEncryptionOffersPlainRtp() { val a = registered(account("7100", media = Media.NONE)); dial(a, "1001"); waitServer("INVITE 1001"); val l = serverLog(); assertTrue("RTP/AVP" in l); assertFalse("a=crypto" in l) }
    @Test fun sdesOffersSrtpWithKeys() { val a = registered(account("7100", media = Media.SRTP_SDES)); dial(a, "1001"); waitServer("INVITE 1001"); val l = serverLog(); assertTrue("a=crypto:" in l && "AES_CM_128_HMAC_SHA1" in l, l.lines().first { "INVITE 1001" in it }) }   // optional SRTP offers keys on plain RTP/AVP; a mandatory (RTP/SAVP) offer needs TLS
    @Test fun dtlsOffersAFingerprint() { val a = registered(account("7100", media = Media.SRTP_DTLS)); dial(a, "1001"); waitServer("INVITE 1001"); val l = serverLog(); assertTrue("UDP/TLS/RTP/SAVP" in l && "a=fingerprint" in l) }
    @Test fun aDisabledCodecIsNotOffered() {
        val all = engine.availableCodecs().map { it.id }; assertTrue(all.any { it.startsWith("PCMA/") })
        settings.codecsOff = all.filter { !it.startsWith("PCMA/") }.toSet(); main { engine.applyCodecs() }
        val a = registered(account("7100")); dial(a, "1001"); waitServer("INVITE 1001")
        val line = serverLog().lines().first { "INVITE 1001" in it }; assertTrue("PCMA" in line, line); assertFalse("PCMU" in line, line); assertFalse("G722" in line, line)
    }
    @Test fun theCodecOrderIsTheOrderOffered() {
        val order = engine.availableCodecs().map { it.id }.let { l -> listOf(l.first { it.startsWith("PCMA/") }) + l.filter { !it.startsWith("PCMA/") } }
        settings.codecOrder = order; main { engine.applyCodecs() }
        val a = registered(account("7100")); dial(a, "1001"); waitServer("INVITE 1001")
        val line = serverLog().lines().first { "INVITE 1001" in it }; assertTrue(line.indexOf("PCMA") in 0 until line.indexOf("PCMU").let { if (it < 0) Int.MAX_VALUE else it }, line)
    }
    /** pjsua has one STUN server for the whole app: an account that doesn't use STUN must not use another account's. */
    @Test fun anAccountWithoutStunDoesNotUseAnotherAccountsStunServer() {
        val withStun = registered(account("7100") { it.copy(stunServer = "$host:3478", iceEnabled = true) }); dial(withStun, "1001")
        waitServer("INVITE 1001", 15)                                         // the INVITE goes out once the address gathering (STUN) is done
        assertTrue(serverSaw("STUN binding request"), "the account with STUN asked the STUN server")
        main { engine.hangupAll() }; waitFor("the first call to end") { engine.calls.value.isEmpty() }
        Thread.sleep(1500)                                                    // the first account's last messages arrive before the log is cleared
        http("/clear")
        val plain = registered(account("7101")); dial(plain, "1001"); waitServer("INVITE 1001")
        Thread.sleep(1500)
        assertFalse(serverSaw("STUN binding request"), "the account without STUN made no STUN request")
    }
    /** Needs a real TURN server (the fake PBX only does STUN): tests/mock/run-turn-test.sh android starts one and passes its host:port as the "turn" argument. */
    @Test fun aTurnServerGivesTheOfferARelayAddress() {
        val turn = InstrumentationRegistry.getArguments().getString("turn")
        org.junit.Assume.assumeTrue("needs a TURN server: run tests/mock/run-turn-test.sh android", !turn.isNullOrEmpty())
        val a = account("7100") { it.copy(stunServer = turn!!, iceEnabled = true, turnEnabled = true, turnUser = "l1ne") }
        accounts.saveTurnSecret(a.id, "turnpass")
        registered(a); dial(a, "1001"); waitServer("INVITE 1001", 15)
        assertTrue(serverLog().contains("typ relay"), "the offer carries a relayed candidate from the TURN server")
        assertTrue(serverLog().contains("typ host"), "and still the phone's own address")
    }
    @Test fun aStunServerIsAskedForThePublicAddress() {
        val a = registered(account("7100") { it.copy(stunServer = "$host:3478", iceEnabled = true) }); dial(a, "1001"); waitServer("INVITE 1001")
        waitFor("the STUN server to be contacted", 15) { serverSaw("STUN binding request") }
    }
    @Test fun iceAddsCandidatesToTheOffer() { val a = registered(account("7100") { it.copy(stunServer = "$host:3478", iceEnabled = true) }); dial(a, "1001"); waitServer("INVITE 1001"); assertTrue("a=candidate" in serverLog() || "a=ice-ufrag" in serverLog()) }

    // ---------------- texts and voicemail ----------------
    @Test fun aTextIsSent() { val a = registered(account("7100")); assertTrue(engine.sendText(a, "7200@$host", "hello from L1ne")); waitServer("MESSAGE from phone: 7100 -> 7200 | hello from L1ne") }
    @Test fun aTextIsReceived() { registered(account("7100")); val before = messages.conversations.value.sumOf { it.messages.size }; http("/text?user=7100&text=ping%20from%20the%20pbx"); waitFor("the text") { messages.conversations.value.sumOf { it.messages.size } > before } }
    @Test fun messageWaitingShowsNewVoicemail() { val a = registered(account("7100")); waitServer("SUBSCRIBE message-summary"); waitFor("3 new") { engine.voicemail.value[a.id] == 3 } }

    // ---- the login check used by the QR / setup-link screen (and the Welcome form's rule): try the account, keep it only if it registers ----

    private fun unsaved(user: String) = draft(user)
    private fun check(a: Account, password: String, timeoutMs: Long = 25_000): String? =
        runBlocking { withContext(Dispatchers.Main) { com.livenet.l1ne.ui.verifyLogin(engine, a, password, timeoutMs) } }

    @Test fun loginCheckLetsAGoodLoginThroughAndSavesNothing() {
        val a = unsaved("7100"); assertNull(check(a, "secret"))
        assertTrue(accounts.accounts.value.none { it.id == a.id }, "the check must not save the account")
        main { engine.unregister(a.id) }
    }
    @Test fun loginCheckRefusesAWrongPasswordInPlainWords() {
        val a = unsaved("7100"); assertEquals("The PBX refused that username or password. Check them and try again.", check(a, "wrong"))
        assertNull(engine.registration.value[a.id], "a refused account must not stay registered")
    }
    @Test fun loginCheckSaysWhenTheExtensionDoesNotExist() {
        val a = unsaved("7104"); assertEquals("The PBX doesn't know that username or extension.", check(a, "secret")); assertNull(engine.registration.value[a.id])
    }
    @Test fun loginCheckSaysWhenTheServerCannotBeReached() {
        val a = unsaved("7105"); assertEquals("Couldn't reach the PBX. Check the server name and your connection.", check(a, "secret")); assertNull(engine.registration.value[a.id])
    }
    @Test fun loginCheckGivesUpWhenTheServerNeverAnswers() {
        val a = unsaved("7106"); val why = check(a, "secret", timeoutMs = 4_000)
        assertNotNull(why); assertTrue(why.contains("didn't answer"), why); assertNull(engine.registration.value[a.id])
    }
}
