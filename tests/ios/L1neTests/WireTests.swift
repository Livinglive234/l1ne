import XCTest
import Darwin
import CPJSIP
@testable import L1ne

/// L1ne's real SIP engine (PJSIP, not a stand-in) on the iPhone, against the fake PBX in `tests/mock/pbx.py`, which has to be running
/// on this computer (`tests/mock/run-ios-wire-tests.sh` does that). Each test registers an account, does one thing, and checks both what the
/// engine reports and what the server saw on the wire. The extension or number used picks the scenario; see the header of pbx.py.
/// These are the same scenarios as the Android `WireTest`. The simulator reaches the computer as 127.0.0.1 (`PBX=<ip>` for a phone on Wi-Fi).
/// PJSIP can only start once per process and the app has already started it, so the tests drive the app's own engine and stores.
@MainActor
final class WireTests: XCTestCase {
    private let engine = SIPEngine.shared
    private let accounts = AccountStore.shared
    private let settings = AppSettings.shared
    private let host = ProcessInfo.processInfo.environment["PBX"] ?? "127.0.0.1"
    private var made: [Account] = []
    private var earlyMediaBefore = false

    // MARK: setup

    override func setUp() async throws {
        engine.start()
        for a in accounts.accounts { engine.unregister(a.id); accounts.remove(a.id) }          // a clean slate
        try waitFor("no calls left over") { engine.calls.isEmpty }
        _ = http("/clear")
        settings.codecsOff = []; engine.applyCodecs()
        earlyMediaBefore = settings.acceptEarlyMedia; settings.acceptEarlyMedia = true                  // no local ringback tone: this computer's simulator has no audio device and each attempt to play one stalls the app for ~15 s
    }

    override func tearDown() async throws {
        engine.hangupAll(); pause(0.4)
        for a in made { engine.unregister(a.id); accounts.remove(a.id) }; made.removeAll()
        settings.acceptEarlyMedia = earlyMediaBefore
    }

    // MARK: helpers

    /// An account for the fake PBX, not saved anywhere.
    private func makeAccount(_ user: String, transport: Account.Transport = .tcp, media: Account.Media = .none, _ build: (inout Account) -> Void = { _ in }) -> Account {
        var a = Account()
        a.label = "mock \(user)"; a.domain = host; a.username = user
        a.media = media; a.mediaMandatory = false
        a.changeTransport(to: transport)                  // 5060 for TCP and UDP
        build(&a)
        return a
    }
    private func account(_ user: String, password: String = "secret", transport: Account.Transport = .tcp, media: Account.Media = .none,
                         _ build: (inout Account) -> Void = { _ in }) -> Account {
        let a = makeAccount(user, transport: transport, media: media, build)
        accounts.save(a, secret: password); made.append(a)
        return a
    }
    private func register(_ a: Account) { engine.register(a, secret: accounts.secret(a.id)) }
    private func status(_ a: Account) -> String { engine.registration[a.id] ?? "" }
    @discardableResult private func registered(_ a: Account) throws -> Account { register(a); try waitFor("register \(a.username)") { status(a) == "Registered" }; return a }
    private func dial(_ a: Account, _ number: String) { XCTAssertTrue(engine.call(number, from: a.id), "the engine refused to place the call to \(number)") }
    private var onlyCall: SIPEngine.CallInfo? { engine.calls.count == 1 ? engine.calls[0] : nil }

    /// Lets the engine's callbacks (which arrive on the main thread) run while waiting.
    private func pause(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func waitFor(_ what: String, seconds: Double = 10, _ cond: () -> Bool) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return }; pause(0.1) }
        XCTFail("timed out waiting for: \(what)\ncalls: \(engine.calls)\n--- server log ---\n\(serverLog())")
        throw XCTSkip("timed out")                      // stop this test here
    }
    private func serverLog() -> String { http("/log") }
    private func serverSaw(_ text: String) -> Bool { serverLog().contains(text) }
    private func waitServer(_ text: String, seconds: Double = 10) throws { try waitFor("the server to log \"\(text)\"", seconds: seconds) { serverSaw(text) } }

    /// The fake PBX's log over plain HTTP, on a raw socket (short and local, so blocking for a moment is fine).
    private func http(_ path: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return "" }
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(8099).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return "" }
        let req = "GET \(path) HTTP/1.0\r\nHost: x\r\n\r\n"
        _ = req.withCString { send(fd, $0, strlen($0), 0) }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 8192)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out.append(buf, count: n) }
        let text = String(decoding: out, as: UTF8.self)
        return text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
    }

    // MARK: registration

    func testRegistersWithADigestLogin() throws {
        let a = try registered(account("7100"))
        XCTAssertTrue(serverSaw("401 challenge")); XCTAssertTrue(serverSaw("REGISTER 7100 -> 200 OK")); XCTAssertEqual(status(a), "Registered")
    }
    func testAWrongPasswordIsRefused() throws {
        let a = account("7100", password: "nope"); register(a)
        try waitFor("403") { status(a).contains("403") }
        XCTAssertFalse(status(a) == "Registered")
    }
    func testAnUnknownExtensionIsRefused() throws { let a = account("7104"); register(a); try waitFor("404") { status(a).contains("404") } }
    func testAServerThatIsDownIsReported() throws { let a = account("7105"); register(a); try waitFor("503") { status(a).contains("503") } }
    func testAServerThatNeverAnswersStaysRegistering() { let a = account("7106"); register(a); pause(4); XCTAssertEqual(status(a), "Registering…") }
    func testRegistersOverUdpToo() throws { try registered(account("7100", transport: .udp)); XCTAssertTrue(serverSaw("via=udp")) }
    func testADisabledAccountDoesNotRegister() {
        let a = account("7100") { $0.enabled = false }; register(a); pause(1.5)
        XCTAssertEqual(status(a), "Off"); XCTAssertFalse(serverSaw("REGISTER"))
    }

    // MARK: calls

    func testAnOutgoingCallIsAnsweredHeldResumedAndHungUp() throws {
        let a = try registered(account("7100")); dial(a, "1001")
        try waitFor("call answered") { onlyCall?.connected == true }
        XCTAssertTrue(serverSaw("INVITE 1001")); try waitServer("ACK")
        let id = onlyCall!.id
        engine.toggleHold(id); try waitServer("dir=sendonly"); XCTAssertTrue(engine.held.contains(id))
        engine.toggleHold(id); try waitServer("dir=sendrecv")
        engine.hangup(id); try waitServer("BYE"); try waitFor("call gone") { engine.calls.isEmpty }
        XCTAssertEqual(CallLogStore.shared.records.first?.direction, .outgoing)
    }
    func testABusyNumberEndsTheCall() throws { let a = try registered(account("7100")); dial(a, "1002"); try waitServer("486 Busy"); try waitFor("call gone") { engine.calls.isEmpty } }
    func testADeclinedCallEndsTheCall() throws { let a = try registered(account("7100")); dial(a, "1006"); try waitServer("603 Decline"); try waitFor("call gone") { engine.calls.isEmpty } }
    func testAnUnknownNumberEndsTheCall() throws { let a = try registered(account("7100")); dial(a, "1005"); try waitServer("-> 404"); try waitFor("call gone") { engine.calls.isEmpty } }
    func testARingingCallCanBeCancelled() throws {
        let a = try registered(account("7100")); dial(a, "1004")
        try waitFor("ringing") { onlyCall?.state == "Ringing…" }
        engine.hangup(onlyCall!.id); try waitServer("CANCEL"); try waitFor("call gone") { engine.calls.isEmpty }
    }
    func testEarlyMediaThenAnswerWorks() throws { let a = try registered(account("7100")); dial(a, "1003"); try waitServer("183 early media"); try waitFor("answered") { onlyCall?.connected == true } }
    func testACallCanBeTransferred() throws {
        let a = try registered(account("7100")); dial(a, "1001"); try waitFor("answered") { onlyCall?.connected == true }
        XCTAssertTrue(engine.transfer(onlyCall!.id, to: "7200", account: a.id)); try waitServer("REFER Refer-To: sip:7200@\(host)")
    }
    func testATransferShowsItsProgressAndThenTheCallEnds() throws {
        let a = try registered(account("7100")); dial(a, "1001"); try waitFor("answered") { onlyCall?.connected == true }
        let id = onlyCall!.id
        XCTAssertTrue(engine.transfer(id, to: "7200", account: a.id))
        XCTAssertTrue(engine.transferNote[id]?.hasPrefix("Transferring") == true, "the call screen says a transfer is under way as soon as it is asked for")
        try waitFor("the call to end once the other side has taken over") { engine.calls.isEmpty }
    }
    // ---- attended transfer: ask the new person first, with the caller on hold ----

    private func startConsult(to number: String) throws -> (original: Int32, consult: Int32) {
        let a = try registered(account("7100")); dial(a, "1001"); try waitFor("answered") { onlyCall?.connected == true }
        let original = onlyCall!.id
        XCTAssertTrue(engine.startConsult(from: original, to: number, account: a.id))
        let consult = engine.consults.first { $0.value == original }!.key
        XCTAssertTrue(engine.held.contains(original), "the caller is put on hold while the new person is asked")
        return (original, consult)
    }
    func testAnAttendedTransferConnectsThemOnceTheNewPersonHasAnswered() throws {
        let (original, consult) = try startConsult(to: "7200")
        try waitFor("the new person to answer") { engine.calls.first { $0.id == consult }?.connected == true }
        XCTAssertTrue(engine.completeTransfer(consult: consult))
        try waitServer("Replaces=")                                                   // the caller is told to replace our call to the new person with theirs
        try waitFor("both of our calls to end once the PBX has done it") { engine.calls.isEmpty }
        _ = original
    }
    func testCancellingAnAttendedTransferGoesBackToTheCaller() throws {
        let (original, consult) = try startConsult(to: "7200")
        try waitFor("the new person to answer") { engine.calls.first { $0.id == consult }?.connected == true }
        engine.cancelConsult(consult)
        try waitFor("the call to the new person to end") { engine.calls.count == 1 }
        try waitFor("the caller to be taken off hold") { !engine.held.contains(original) }
        XCTAssertEqual(engine.calls.first?.id, original); XCTAssertEqual(engine.calls.first?.connected, true)
    }
    func testAConsultNobodyAnswersPutsYouBackWithTheCaller() throws {
        let (original, _) = try startConsult(to: "1002")                                // 1002 is busy
        try waitFor("the busy call to end") { engine.calls.count == 1 }
        try waitFor("the caller to be taken off hold") { !engine.held.contains(original) }
        XCTAssertTrue(engine.transferNote[original]?.contains("back with this caller") == true)
    }
    func testAQuickHoldThenResumeEndsUpResumed() throws {                // the second tap comes while the first is still being negotiated
        let a = try registered(account("7100")); dial(a, "1001"); try waitFor("answered") { onlyCall?.connected == true }
        let id = onlyCall!.id
        engine.toggleHold(id); engine.toggleHold(id)
        try waitFor("the resume to reach the server") { let l = serverLog(); return l.contains("dir=sendonly") && l.contains("dir=sendrecv") }
        XCTAssertFalse(engine.held.contains(id), "the call is not left on hold")
    }
    func testAFailedTransferSaysSoAndTheCallGoesOn() throws {
        let a = try registered(account("7100")); dial(a, "1001"); try waitFor("answered") { onlyCall?.connected == true }
        let id = onlyCall!.id
        XCTAssertTrue(engine.transfer(id, to: "7404", account: a.id))
        try waitFor("the failure to be reported") { engine.transferNote[id]?.hasPrefix("Transfer failed: 404") == true }
        XCTAssertEqual(onlyCall?.connected, true, "the call is still there")
    }
    func testTheVoicemailButtonDialsTheVoicemailNumber() throws { let a = try registered(account("7100")); engine.callVoicemail(a.id); try waitServer("INVITE *97") }
    func testDialRulesChangeWhatIsDialled() throws { let a = try registered(account("7100") { $0.dialStripPrefix = "9" }); dial(a, "91001"); try waitServer("INVITE 1001") }
    func testAnIncomingCallRingsIsAnsweredAndHangsUp() throws {
        try registered(account("7100")); _ = http("/invite?user=7100")
        try waitFor("incoming call") { onlyCall?.incoming == true }
        engine.answer(onlyCall!.id); try waitFor("answered") { onlyCall?.connected == true }; try waitServer("ACK to phone")
        engine.hangup(onlyCall!.id); try waitServer("BYE"); try waitFor("call gone") { engine.calls.isEmpty }
    }

    // MARK: what goes on the wire

    func testTheSipLogShowsTheMessagesWithoutSecrets() throws {
        SipLog.shared.clear()
        let a = try registered(account("7100")); dial(a, "1001"); try waitServer("INVITE 1001")
        try waitFor("the log has the sign-in and the call") { let t = SipLog.shared.text(); return t.contains("REGISTER sip:") && t.contains("INVITE sip:") }
        let t = SipLog.shared.text()
        XCTAssertTrue(t.contains("Authorization: [removed]"), "the digest header is removed")
        XCTAssertNil(t.range(of: #"response="[0-9a-f]{8,}"#, options: .regularExpression), "no digest response is left")
    }
    func testNoEncryptionOffersPlainRtp() throws {
        let a = try registered(account("7100", media: .none)); dial(a, "1001"); try waitServer("INVITE 1001")
        let l = serverLog(); XCTAssertTrue(l.contains("RTP/AVP")); XCTAssertFalse(l.contains("a=crypto"))
    }
    func testSdesOffersSrtpWithKeys() throws {
        let a = try registered(account("7100", media: .srtpSDES)); dial(a, "1001"); try waitServer("INVITE 1001")
        let l = serverLog(); XCTAssertTrue(l.contains("a=crypto:") && l.contains("AES_CM_128_HMAC_SHA1"), l)
    }
    func testDtlsOffersAFingerprint() throws {
        let a = try registered(account("7100", media: .srtpDTLS)); dial(a, "1001"); try waitServer("INVITE 1001")
        let l = serverLog(); XCTAssertTrue(l.contains("UDP/TLS/RTP/SAVP") && l.contains("a=fingerprint"), l)
    }
    // Auto answer: only when the account has it on, the call asks for it, and the caller is allowed
    func testAnInterComCallIsNotAnsweredByDefault() throws {
        try registered(account("7100")); _ = http("/invite?user=7100&autoanswer=1")
        try waitFor("incoming call") { onlyCall?.incoming == true }; pause(1)
        XCTAssertEqual(onlyCall?.connected, false, "it keeps ringing: auto answer is off"); XCTAssertTrue(engine.autoAnswered.isEmpty)
    }
    func testAnInterComCallIsAnsweredWithTheMicrophoneOffWhenTheAccountAllowsIt() throws {
        try registered(account("7100") { $0.autoAnswer = true }); _ = http("/invite?user=7100&autoanswer=1")
        try waitFor("the call to be answered by itself") { onlyCall?.connected == true }
        guard let id = onlyCall?.id else { return XCTFail("the call ended at once") }
        XCTAssertEqual(engine.autoAnswered[id], false); try waitFor("the microphone to be off") { engine.muted.contains(id) }
        XCTAssertNotNil(engine.notice, "the person is told")
    }
    func testAnInterComCallWithTheMicrophoneOnIsNotMuted() throws {
        try registered(account("7100") { $0.autoAnswer = true; $0.autoAnswerMic = true }); _ = http("/invite?user=7100&autoanswer=1")
        try waitFor("the call to be answered by itself") { onlyCall?.connected == true }
        guard let id = onlyCall?.id else { return XCTFail("the call ended at once") }          // (the simulator's CallKit ends calls nobody touches, so look straight away)
        XCTAssertEqual(engine.autoAnswered[id], true); XCTAssertFalse(engine.muted.contains(id))
    }
    func testAnInterComCallFromSomeoneNotOnTheListKeepsRinging() throws {
        try registered(account("7100") { $0.autoAnswer = true; $0.autoAnswerFrom = "7001, 7002" }); _ = http("/invite?user=7100&autoanswer=1")
        try waitFor("incoming call") { onlyCall?.incoming == true }; pause(1)
        XCTAssertEqual(onlyCall?.connected, false); XCTAssertTrue(engine.autoAnswered.isEmpty)
    }
    func testAnOrdinaryCallIsNotAnsweredEvenWithAutoAnswerOn() throws {
        try registered(account("7100") { $0.autoAnswer = true }); _ = http("/invite?user=7100")
        try waitFor("incoming call") { onlyCall?.incoming == true }; pause(1)
        XCTAssertEqual(onlyCall?.connected, false, "no auto-answer header, so it rings")
    }
    func testRemovingAnAccountWhileItsCallIsStillRingingEndsTheCallAndDoesNotCrash() throws {
        let a = try registered(account("7100")); dial(a, "1004"); try waitServer("INVITE 1004"); try waitFor("the call") { !engine.calls.isEmpty }
        engine.unregister(a.id)                                        // PJSIP crashed when an account went away under a call that was still setting up
        try waitFor("the call to end") { engine.calls.isEmpty }
        let again = try registered(account("7101")); dial(again, "1001"); try waitServer("INVITE 1001")        // and the engine still works
    }
    // ZRTP, against tests/zrtp/zrtp_peer.c (started by the mock PBX on its media port): the keys are agreed on the media path, both sides show the same code, and SRTP flows
    func testZrtpAgreesKeysAndMediaFlows() throws {
        let a = try registered(account("7100", media: .zrtp)); dial(a, "1001"); try waitServer("INVITE 1001")
        XCTAssertTrue(serverLog().contains("a=zrtp-hash:1.10"), "the offer says we speak ZRTP")
        try waitFor("ZRTP secure on our side") { engine.calls.first.flatMap { engine.zrtp[$0.id]?.state } == 1 }
        try waitServer("zrtp-peer: secure")
        // the peer sends SRTP of its own (this computer's simulator has no audio device, so the app itself sends none): what arrives is read and reaches the stream
        try waitFor("SRTP from the peer to be read by the stream") {
            var st = pjsua_stream_stat(); guard let id = engine.calls.first?.id, pjsua_call_get_stream_stat(id, 0, &st) == 0 else { return false }
            return st.rtcp.rx.pkt > 10 }
        let code = engine.calls.first.flatMap { engine.zrtp[$0.id]?.code } ?? ""
        XCTAssertEqual(code.count, 4); XCTAssertTrue(serverLog().contains("zrtp-peer: sas \(code)"), "both sides show the same code (\(code))\n\(serverLog())")
        try waitFor("the call to be shown as ZRTP-encrypted") { engine.calls.first.map { engine.encryption[$0.id] } == .some(.zrtp) }
    }
    func testZrtpRequiredEndsTheCallWhenThePeerHasNoZrtp() throws {
        let a = try registered(account("7100", media: .zrtp) { $0.mediaMandatory = true }); dial(a, "1007"); try waitServer("INVITE 1007"); try waitFor("the call") { !engine.calls.isEmpty }
        try waitFor("the call to be ended because ZRTP never came", seconds: 25) { engine.calls.isEmpty }
        XCTAssertTrue(serverSaw("BYE"))
    }
    func testZrtpWhenAvailableKeepsTheCallInTheClearIfThePeerHasNoZrtp() throws {
        let a = try registered(account("7100", media: .zrtp)); dial(a, "1007"); try waitServer("INVITE 1007")
        try waitFor("ZRTP to be given up", seconds: 25) { engine.calls.first.flatMap { engine.zrtp[$0.id]?.state } == 2 }
        XCTAssertEqual(engine.calls.count, 1, "the call goes on")
        try waitFor("the call to be shown as not encrypted") { engine.calls.first.flatMap { engine.encryption[$0.id] } == SIPEngine.CallSecurity.none }
    }
    func testADisabledCodecIsNotOffered() throws {
        let all = engine.availableCodecs().map(\.id); XCTAssertTrue(all.contains { $0.hasPrefix("PCMA/") })
        settings.codecsOff = all.filter { !$0.hasPrefix("PCMA/") }; engine.applyCodecs()
        let a = try registered(account("7100")); dial(a, "1001"); try waitServer("INVITE 1001")
        let line = serverLog().components(separatedBy: "\n").first { $0.contains("INVITE 1001") } ?? ""
        XCTAssertTrue(line.contains("PCMA"), line); XCTAssertFalse(line.contains("PCMU"), line); XCTAssertFalse(line.contains("G722"), line)
    }
    func testTheCodecOrderIsTheOrderOffered() throws {
        let ids = engine.availableCodecs().map(\.id)
        settings.codecOrder = [ids.first { $0.hasPrefix("PCMA/") }!] + ids.filter { !$0.hasPrefix("PCMA/") }; engine.applyCodecs()
        let a = try registered(account("7100")); dial(a, "1001"); try waitServer("INVITE 1001")
        let line = serverLog().components(separatedBy: "\n").first { $0.contains("INVITE 1001") } ?? ""
        let pcma = line.range(of: "PCMA")?.lowerBound, pcmu = line.range(of: "PCMU")?.lowerBound
        XCTAssertNotNil(pcma, line); if let pcma, let pcmu { XCTAssertLessThan(pcma, pcmu, line) }
    }
    /// pjsua has one STUN server for the whole app: an account that doesn't use STUN must not use another account's.
    func testAnAccountWithoutStunDoesNotUseAnotherAccountsStunServer() throws {
        let withStun = try registered(account("7100") { $0.stunServer = "\(host):3478"; $0.iceEnabled = true })
        dial(withStun, "1001"); try waitServer("INVITE 1001", seconds: 15)           // the INVITE goes out once the address gathering (STUN) is done
        XCTAssertTrue(serverSaw("STUN binding request"), "the account with STUN asked the STUN server")
        engine.hangupAll(); try waitFor("the first call to end") { engine.calls.isEmpty }
        pause(1.5)                                                                  // the first account's last messages arrive before the log is cleared
        _ = http("/clear")
        let plain = try registered(account("7101")); dial(plain, "1001"); try waitServer("INVITE 1001")
        pause(1.5)
        XCTAssertFalse(serverSaw("STUN binding request"), "the account without STUN made no STUN request")
    }
    /// Needs a real TURN server (the fake PBX only does STUN): tests/mock/run-turn-test.sh starts one and sets L1NE_TURN to its host:port.
    func testATurnServerGivesTheOfferARelayAddress() throws {
        guard let turn = ProcessInfo.processInfo.environment["L1NE_TURN"], !turn.isEmpty else { throw XCTSkip("needs a TURN server: run tests/mock/run-turn-test.sh") }
        let a = account("7100") { $0.stunServer = turn; $0.iceEnabled = true; $0.turnEnabled = true; $0.turnUser = "l1ne" }
        accounts.save(a, secret: nil, turnSecret: "turnpass")
        try registered(a); dial(a, "1001"); try waitServer("INVITE 1001", seconds: 15)
        XCTAssertTrue(serverLog().contains("typ relay"), "the offer carries a relayed candidate from the TURN server")
        XCTAssertTrue(serverLog().contains("typ host"), "and still the phone's own address")
    }
    func testAStunServerIsAskedForThePublicAddress() throws {
        let a = try registered(account("7100") { $0.stunServer = "\(host):3478"; $0.iceEnabled = true }); dial(a, "1001"); try waitServer("INVITE 1001")
        try waitFor("the STUN server to be contacted", seconds: 15) { serverSaw("STUN binding request") }
    }
    func testIceAddsCandidatesToTheOffer() throws {
        let a = try registered(account("7100") { $0.stunServer = "\(host):3478"; $0.iceEnabled = true }); dial(a, "1001"); try waitServer("INVITE 1001")
        let l = serverLog(); XCTAssertTrue(l.contains("a=candidate") || l.contains("a=ice-ufrag"), l)
    }

    // MARK: texts and voicemail

    func testATextIsSent() throws {
        let a = try registered(account("7100"))
        XCTAssertTrue(engine.sendMessage("hello from L1ne", to: ThreadTarget(accountID: a.id, peer: "7200@\(host)")))
        try waitServer("MESSAGE from phone: 7100 -> 7200 | hello from L1ne")
    }
    func testATextIsReceived() throws {
        try registered(account("7100")); let before = MessageStore.shared.conversations.reduce(0) { $0 + $1.messages.count }
        _ = http("/text?user=7100&text=ping%20from%20the%20pbx")
        try waitFor("the text") { MessageStore.shared.conversations.reduce(0) { $0 + $1.messages.count } > before }
        XCTAssertTrue(MessageStore.shared.conversations.contains { $0.messages.contains { $0.text == "ping from the pbx" } })
    }
    func testMessageWaitingShowsNewVoicemail() throws {
        let a = try registered(account("7100")); try waitServer("SUBSCRIBE message-summary"); try waitFor("3 new") { engine.voicemail[a.id] == 3 }
    }

    // MARK: the login check the QR / setup-link screen runs before it keeps an account (and the Welcome form's rule)

    private func unsaved(_ user: String) -> Account { makeAccount(user) }
    func testLoginCheckLetsAGoodLoginThroughAndSavesNothing() async {
        let a = unsaved("7100"); let why = await LoginCheck.verify(a, secret: "secret", engine: engine)
        XCTAssertNil(why); XCTAssertFalse(accounts.accounts.contains { $0.id == a.id }, "the check must not save the account"); engine.unregister(a.id)
    }
    func testLoginCheckRefusesAWrongPasswordInPlainWords() async {
        let a = unsaved("7100"); let why = await LoginCheck.verify(a, secret: "wrong", engine: engine)
        XCTAssertEqual(why, "The PBX refused that username or password. Check them and try again."); XCTAssertNil(engine.registration[a.id], "a refused account must not stay registered")
    }
    func testLoginCheckSaysWhenTheExtensionDoesNotExist() async {
        let a = unsaved("7104"); let why = await LoginCheck.verify(a, secret: "secret", engine: engine)
        XCTAssertEqual(why, "The PBX doesn't know that username or extension."); XCTAssertNil(engine.registration[a.id])
    }
    func testLoginCheckSaysWhenTheServerCannotBeReached() async {
        let a = unsaved("7105"); let why = await LoginCheck.verify(a, secret: "secret", engine: engine)
        XCTAssertEqual(why, "Couldn't reach the PBX. Check the server name and your connection."); XCTAssertNil(engine.registration[a.id])
    }
    func testLoginCheckGivesUpWhenTheServerNeverAnswers() async {
        let a = unsaved("7106"); let why = await LoginCheck.verify(a, secret: "secret", engine: engine, timeout: 4)
        XCTAssertNotNil(why); XCTAssertTrue(why?.contains("didn't answer") == true, why ?? ""); XCTAssertNil(engine.registration[a.id])
    }
}
