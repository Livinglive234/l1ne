import Foundation
import AVFoundation
import CPJSIP

/// Thin Swift wrapper over the pjsua C API. All calls happen on the main thread (the thread that created pjsua,
/// so it is already registered with pjlib); pjsua's own threads only hop to main inside the callbacks below.
@MainActor
final class SIPEngine: ObservableObject {
    static let shared = SIPEngine()

    struct CallInfo: Identifiable, Equatable {
        let id: Int32
        var remote: String
        var state: String
        var incoming: Bool
        var connected: Bool
        var since: Date?
        var accountID: UUID?
        var address = ""              // user@domain of the other side
    }

    enum CallSecurity { case srtp, dtls, none, unknown }

    struct Codec: Identifiable, Equatable {
        var id: String            // "PCMU/8000/1"
        var name: String          // "PCMU"
        var rate: Int
        var channels: Int
        var detail: String { "\(rate) Hz (\(channels == 2 ? "Stereo" : "Mono"))" }
    }

    @Published var registration: [UUID: String] = [:]   // account id -> "Registered" / "Failed 403 ..."
    @Published var calls: [CallInfo] = []
    /// Per account: why texting isn't available on that server (set when it refuses a MESSAGE).
    /// What the hidden self-text showed about an account's server.
    enum MessagingCheck: Equatable {
        case unknown, checking
        case working                      // the test text came back to us: the server routes texts
        case notDelivered                 // the server took it but never delivered it back
    }
    @Published var messagingCheck: [UUID: MessagingCheck] = [:]
    private var probeTags: [Int: UUID] = [:]                 // pjsua send tag -> account, for the test text
    private var probeTokens: [UUID: String] = [:]            // account -> the tag carried in the test text
    private static let probePrefix = "L1NE-CHECK:"

    /// Accounts whose server answered a text with "not supported" (405/501/415). Remembered across launches, and cleared
    /// as soon as a text goes through.
    @Published var messagingNote: [UUID: String] = {
        let d = UserDefaults.standard.dictionary(forKey: "messaging.unsupported") as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }() {
        didSet { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: messagingNote.map { ($0.key.uuidString, $0.value) }), forKey: "messaging.unsupported") }
    }
    /// New voicemail messages per account (from the message-waiting indicator).
    @Published var voicemail: [UUID: Int] = [:]
    @Published var recording: Set<Int32> = []
    @Published var muted: Set<Int32> = []
    @Published var held: Set<Int32> = []
    @Published var speaker = false
    /// The call shown on the call screen (others are on hold or ringing).
    @Published var currentCallID: Int32?
    @Published var encryption: [Int32: CallSecurity] = [:]
    @Published var quality: [Int32: Int] = [:]          // 1 (poor) ... 5 (excellent), from RTCP loss, jitter and delay
    @Published var qualityNumbers: [Int32: QualityNumbers] = [:]   // the raw figures behind that score, shown when you tap the indicator
    struct QualityNumbers: Equatable { var lossPercent: Double; var jitterMs: Double; var roundTripMs: Double }
    private var statsTask: Task<Void, Never>?

    var currentCall: CallInfo? { calls.first { $0.id == currentCallID } ?? calls.first }

    private var sendTags: [Int: (ThreadTarget, UUID)] = [:]
    private var nextTag = 1

    private var started = false
    private var tlsTransport: pjsua_transport_id = -1
    private var pjAccounts: [UUID: pjsua_acc_id] = [:]
    private var accountForPJ: [pjsua_acc_id: UUID] = [:]
    private var recorders: [Int32: pjsua_recorder_id] = [:]
    private var caPath: UnsafeMutablePointer<CChar>?
    private var cfgPool: UnsafeMutablePointer<pj_pool_t>?

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        guard pjsua_create() == 0 else { return }

        var cfg = pjsua_config()
        pjsua_config_default(&cfg)
        cfg.max_calls = 4
        cfg.cb.on_incoming_call = { acc, call, _ in
            Task { @MainActor in SIPEngine.shared.incoming(call: call) }
        }
        cfg.cb.on_call_state = { call, _ in
            // The call id is invalid once this callback returns, so read the info now.
            var ci = pjsua_call_info()
            guard pjsua_call_get_info(call, &ci) == 0 else { return }
            Task { @MainActor in SIPEngine.shared.refresh(call: call, incoming: nil, info: ci) }
        }
        cfg.cb.on_call_media_state = { call in
            Task { @MainActor in SIPEngine.shared.mediaChanged(call: call) }
        }
        cfg.cb.on_reg_state = { acc in
            Task { @MainActor in SIPEngine.shared.regChanged(acc: acc) }
        }
        cfg.cb.on_mwi_info = { acc, info in
            guard let info, let n = mwiNewCount(info.pointee.rdata) else { return }
            Task { @MainActor in SIPEngine.shared.mwiChanged(acc: acc, new: n) }
        }
        cfg.cb.on_pager2 = { _, from, _, _, mime, body, _, acc in
            guard let from, let mime, let body, str(mime.pointee).lowercased().hasPrefix("text/plain") else { return }
            let f = str(from.pointee), text = str(body.pointee)
            Task { @MainActor in SIPEngine.shared.received(from: f, text: text, acc: acc) }
        }
        cfg.cb.on_pager_status2 = { _, _, _, userData, status, reason, _, _, acc in
            let tag = Int(bitPattern: userData), code = Int(status.rawValue), why = reason.map { str($0.pointee) } ?? ""
            Task { @MainActor in SIPEngine.shared.sendResult(tag: tag, code: code, reason: why, acc: acc) }
        }

        var log = pjsua_logging_config()
        pjsua_logging_config_default(&log)
        log.console_level = 3
        var media = pjsua_media_config()
        pjsua_media_config_default(&media)
        media.snd_auto_close_time = 5

        guard pjsua_init(&cfg, &log, &media) == 0 else { return }

        // Transports. TLS verifies the server against the CA bundle shipped in the app (OpenSSL has no access to the
        // iPhone's own trust store). UDP and TCP exist so accounts can use them; IPv6 only if allowed.
        var t = pjsua_transport_config()
        pjsua_transport_config_default(&t)
        t.tls_setting.verify_server = 1
        var caFile = Bundle.main.path(forResource: "cacert", ofType: "pem")
        #if DEBUG
        if let extra = ProcessInfo.processInfo.environment["L1NE_CA_FILE"] { caFile = extra }   // tests/mock uses its own CA
        #endif
        if let path = caFile {
            caPath = strdup(path)
            t.tls_setting.ca_list_file = pj_str_t(ptr: caPath, slen: pj_ssize_t(strlen(path)))
        }
        guard pjsua_transport_create(PJSIP_TRANSPORT_TLS, &t, &tlsTransport) == 0 else { return }
        var other = pjsua_transport_config(); pjsua_transport_config_default(&other)
        var id: pjsua_transport_id = -1
        _ = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &other, &id)
        _ = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &other, &id)
        if AppSettings.shared.allowIPv6 {
            _ = pjsua_transport_create(PJSIP_TRANSPORT_TLS6, &t, &id)
            _ = pjsua_transport_create(PJSIP_TRANSPORT_UDP6, &other, &id)
            _ = pjsua_transport_create(PJSIP_TRANSPORT_TCP6, &other, &id)
        }

        cfgPool = pjsua_pool_create("l1ne-cfg", 2048, 2048)
        guard pjsua_start() == 0 else { return }
        _ = pjsua_set_no_snd_dev()      // the sound device opens only once CallKit has activated the audio session
        started = true
        applyCodecs()
        NetworkMonitor.shared.onChange = { SIPEngine.shared.networkChanged() }
    }

    static var version: String { String(cString: pj_get_version()) }

    // MARK: accounts

    func register(_ account: Account, secret: String) {
        start()
        guard started else { return }
        unregister(account.id)

        guard account.enabled else { registration[account.id] = "Off"; return }
        if AppSettings.shared.wifiOnly && !NetworkMonitor.shared.onWiFi {
            registration[account.id] = "Waiting for Wi-Fi"
            return
        }

        let cs = CStrings()
        var ac = pjsua_acc_config()
        pjsua_acc_config_default(&ac)

        let name = account.displayName.replacingOccurrences(of: "\"", with: "")
        ac.id = cs.make(name.isEmpty ? "sip:\(account.username)@\(account.domain)" : "\"\(name)\" <sip:\(account.username)@\(account.domain)>")
        ac.reg_uri = cs.make(account.registrarURI.isEmpty
            ? "sip:\(account.domain):\(account.port);transport=\(account.transport.rawValue)" : account.registrarURI)
        // Send everything (calls, texts, the voicemail subscription) through the server over the account's own
        // transport. Without a route PJSIP would resolve the domain and use plain UDP 5060, which a TLS-only PBX never sees.
        var route = account.outboundProxy.isEmpty ? (account.registrarURI.isEmpty
            ? "sip:\(account.domain):\(account.port);transport=\(account.transport.rawValue)" : account.registrarURI) : account.outboundProxy
        if !route.contains(";lr") { route += ";lr" }
        ac.proxy_cnt = 1
        ac.proxy.0 = cs.make(route)
        ac.reg_timeout = UInt32(max(60, account.expires))
        ac.reg_retry_interval = 30
        ac.mwi_enabled = account.mwiEnabled ? 1 : 0
        ac.rtp_cfg.port = 0

        ac.cred_count = 1
        ac.cred_info.0.realm = cs.make("*")
        ac.cred_info.0.scheme = cs.make("digest")
        ac.cred_info.0.username = cs.make(account.authUser.isEmpty ? account.username : account.authUser)
        ac.cred_info.0.data_type = Int32(PJSIP_CRED_DATA_PLAIN_PASSWD.rawValue)
        ac.cred_info.0.data = cs.make(secret)

        // Media encryption: none, SDES (keys in SDP, so only over TLS) or DTLS-SRTP (keys negotiated in the media path)
        switch account.media {
        case .none:
            ac.use_srtp = PJMEDIA_SRTP_DISABLED
        case .srtpSDES:
            ac.use_srtp = account.mediaMandatory ? PJMEDIA_SRTP_MANDATORY : PJMEDIA_SRTP_OPTIONAL
            ac.srtp_secure_signaling = account.transport == .tls ? 1 : 0
            ac.srtp_opt.keying_count = 1
            ac.srtp_opt.keying.0 = PJMEDIA_SRTP_KEYING_SDES
        case .srtpDTLS:
            ac.use_srtp = account.mediaMandatory ? PJMEDIA_SRTP_MANDATORY : PJMEDIA_SRTP_OPTIONAL
            ac.srtp_secure_signaling = 0
            ac.srtp_opt.keying_count = 1
            ac.srtp_opt.keying.0 = PJMEDIA_SRTP_KEYING_DTLS_SRTP
        }

        // IPv6
        let v6: pjsua_ipv6_use = AppSettings.shared.allowIPv6 ? PJSUA_IPV6_ENABLED_PREFER_IPV4 : PJSUA_IPV6_DISABLED
        ac.ipv6_sip_use = v6
        ac.ipv6_media_use = v6

        // NAT traversal. pjsua has one list of STUN servers for the whole app: the first account that sets one wins.
        if !account.stunServer.isEmpty && (account.iceEnabled || account.turnEnabled) {
            var srv = cs.make(account.stunServer)
            _ = pjsua_update_stun_servers(1, &srv, 0)
        }
        if account.iceEnabled {
            ac.ice_cfg_use = PJSUA_ICE_CONFIG_USE_CUSTOM
            var mc = pjsua_media_config(); pjsua_media_config_default(&mc)
            pjsua_ice_config_from_media_config(cfgPool, &ac.ice_cfg, &mc)
            ac.ice_cfg.enable_ice = 1
        }
        if account.turnEnabled, !account.stunServer.isEmpty {
            ac.turn_cfg_use = PJSUA_TURN_CONFIG_USE_CUSTOM
            var mc2 = pjsua_media_config(); pjsua_media_config_default(&mc2)
            pjsua_turn_config_from_media_config(cfgPool, &ac.turn_cfg, &mc2)
            ac.turn_cfg.enable_turn = 1
            ac.turn_cfg.turn_server = cs.make(account.stunServer)
            ac.turn_cfg.turn_auth_cred.type = PJ_STUN_AUTH_CRED_STATIC
            ac.turn_cfg.turn_auth_cred.data.static_cred.realm = cs.make("*")
            ac.turn_cfg.turn_auth_cred.data.static_cred.username = cs.make(account.turnUser)
            ac.turn_cfg.turn_auth_cred.data.static_cred.data_type = PJ_STUN_PASSWD_PLAIN
            ac.turn_cfg.turn_auth_cred.data.static_cred.data = cs.make(AccountStore.shared.turnSecret(account.id))
        }

        var accID: pjsua_acc_id = -1
        let status = pjsua_acc_add(&ac, 1, &accID)
        if status != 0 { registration[account.id] = "Could not add account: \(Self.errorText(status))"; return }
        pjAccounts[account.id] = accID
        accountForPJ[accID] = account.id
        registration[account.id] = "Registering…"
    }

    func unregister(_ id: UUID) {
        guard let pj = pjAccounts.removeValue(forKey: id) else { return }
        accountForPJ[pj] = nil
        pjsua_acc_del(pj)
        registration[id] = nil
        voicemail[id] = nil
    }

    /// Re-applies every account (after the Wi-Fi rule, IPv6 or a settings change).
    func reregisterAll() {
        let store = AccountStore.shared
        for a in store.accounts { register(a, secret: store.secret(a.id)) }
    }

    private func networkChanged() {
        guard started else { return }
        if AppSettings.shared.wifiOnly { reregisterAll(); return }
        var p = pjsua_ip_change_param()
        pjsua_ip_change_param_default(&p)
        _ = pjsua_handle_ip_change(&p)
    }

    private func regChanged(acc: pjsua_acc_id) {
        guard let id = accountForPJ[acc] else { return }
        var info = pjsua_acc_info()
        guard pjsua_acc_get_info(acc, &info) == 0 else { return }
        let code = Int(info.status.rawValue)
        let text = str(info.status_text)
        registration[id] = (code >= 200 && code < 300 && info.expires > 0) ? "Registered" : "\(code) \(text)"
        // once per launch, a registered account tests whether its server routes texts
        if registration[id] == "Registered", (messagingCheck[id] ?? .unknown) == .unknown {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)      // let the registration settle (and MWI subscribe)
                self?.checkMessaging(id)
            }
        }
    }

    /// Sends one hidden text to the account's own address. A server that routes texts hands it back to this registration;
    /// one that takes it and drops it does not. The test text never shows up in any conversation.
    func checkMessaging(_ id: UUID) {
        guard let acc = pjAccounts[id], let a = AccountStore.shared.account(id), registration[id] == "Registered" else { return }
        if messagingCheck[id] == .checking { return }
        let token = UUID().uuidString
        probeTokens[id] = token
        messagingCheck[id] = .checking
        let tag = nextTag; nextTag += 1
        probeTags[tag] = id
        let cs = CStrings()
        var to = cs.make("sip:\(a.username)@\(a.domain)"), mime = cs.make("text/plain"), content = cs.make(Self.probePrefix + token)
        let st = pjsua_im_send(acc, &to, &mime, &content, nil, UnsafeMutableRawPointer(bitPattern: tag))
        if st != 0 {
            probeTags[tag] = nil; messagingCheck[id] = .unknown; return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.probeTokens[id] == token, self.messagingCheck[id] == .checking else { return }
            self.messagingCheck[id] = .notDelivered
        }
    }

    private func mwiChanged(acc: pjsua_acc_id, new: Int) {
        guard let id = accountForPJ[acc] else { return }
        let old = voicemail[id] ?? 0
        voicemail[id] = new
        if new > old { VoicemailNotifier.newVoicemail(account: id, count: new) }
    }

    // MARK: codecs

    /// The codecs this build offers, in your order, with the ones you switched off at the end of the list.
    func availableCodecs() -> [Codec] {
        start()
        var infos = [pjsua_codec_info](repeating: pjsua_codec_info(), count: 32)
        var count = UInt32(infos.count)
        guard pjsua_enum_codecs(&infos, &count) == 0 else { return [] }
        var all: [Codec] = infos.prefix(Int(count)).compactMap { i in
            let id = str(i.codec_id)
            let p = id.split(separator: "/").map(String.init)
            guard p.count >= 1 else { return nil }
            return Codec(id: id, name: p[0], rate: Int(p.count > 1 ? p[1] : "") ?? 8000, channels: Int(p.count > 2 ? p[2] : "") ?? 1)
        }
        let order = AppSettings.shared.codecOrder
        all.sort { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            return ia == ib ? false : ia < ib
        }
        return all
    }

    /// Pushes your codec order and on/off choices into pjsua (priority 0 = off).
    func applyCodecs() {
        guard started else { return }
        let off = Set(AppSettings.shared.codecsOff)
        var priority = 250
        for c in availableCodecs() {
            let cs = CStrings()
            var id = cs.make(c.id)
            if off.contains(c.id) { _ = pjsua_codec_set_priority(&id, 0) } else { _ = pjsua_codec_set_priority(&id, pj_uint8_t(max(1, priority))); priority -= 5 }
        }
    }

    // MARK: calls

    @discardableResult
    func call(_ number: String, from account: UUID) -> Bool {
        guard let acc = pjAccounts[account], let a = AccountStore.shared.account(account) else { return false }
        let digits = number.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty else { return false }
        configureAudioSession()
        let uri = digits.lowercased().hasPrefix("sip:") || digits.lowercased().hasPrefix("sips:") ? digits : "sip:\(a.dial(digits))@\(a.domain)"
        var callID: pjsua_call_id = -1
        let cs = CStrings()
        var u = cs.make(uri)
        var setting = pjsua_call_setting()
        pjsua_call_setting_default(&setting)
        setting.txt_cnt = 0                       // audio only: no real-time-text stream in the offer
        for c in calls where c.connected && !held.contains(c.id) { toggleHold(c.id) }     // a new call puts the active one on hold
        let st = pjsua_call_make_call(acc, &u, &setting, nil, nil, &callID)
        let ok = st == 0
        if ok {
            currentCallID = callID
            let bare = VCard.sipAddress(uri) ?? digits
            CallKitManager.shared.reportOutgoing(callID, name: Self.callerName(from: uri), address: bare)
        }
        return ok
    }

    @discardableResult
    func callVoicemail(_ account: UUID) -> Bool {
        guard let a = AccountStore.shared.account(account), let target = a.voicemailTarget else { return false }
        return call(target, from: account)
    }

    func answer(_ id: Int32) {
        guard calls.first(where: { $0.id == id })?.connected != true else { return }
        configureAudioSession()
        for c in calls where c.id != id && c.connected && !held.contains(c.id) { toggleHold(c.id) }
        currentCallID = id
        pjsua_call_answer(id, 200, nil, nil)
    }

    /// Makes one call the live one and puts the others on hold.
    func switchTo(_ id: Int32) {
        for c in calls where c.id != id && c.connected && !held.contains(c.id) { toggleHold(c.id) }
        if held.contains(id) { toggleHold(id) }
        currentCallID = id
    }

    func hangup(_ id: Int32) {
        pjsua_call_hangup(id, 0, nil, nil)
    }

    func sendDTMF(_ id: Int32, _ digits: String) {
        let cs = CStrings()
        var d = cs.make(digits)
        pjsua_call_dial_dtmf(id, &d)
    }

    func hangupAll() { pjsua_call_hangup_all() }

    func toggleMute(_ id: Int32) {
        var ci = pjsua_call_info()
        guard pjsua_call_get_info(id, &ci) == 0, ci.conf_slot >= 0 else { return }
        if muted.contains(id) { pjsua_conf_connect(0, ci.conf_slot); muted.remove(id) }
        else { pjsua_conf_disconnect(0, ci.conf_slot); muted.insert(id) }
    }

    func toggleHold(_ id: Int32) {
        if held.contains(id) { pjsua_call_reinvite(id, UInt32(PJSUA_CALL_UNHOLD.rawValue), nil); held.remove(id) }
        else { pjsua_call_set_hold(id, nil); held.insert(id) }
    }

    func toggleSpeaker() {
        speaker.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    /// Blind transfer of a call to another number on the same account.
    @discardableResult
    func transfer(_ id: Int32, to number: String, account: UUID) -> Bool {
        guard let a = AccountStore.shared.account(account) else { return false }
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        let cs = CStrings()
        var dest = cs.make(n.lowercased().hasPrefix("sip") ? n : "sip:\(a.dial(n))@\(a.domain)")
        return pjsua_call_xfer(id, &dest, nil) == 0
    }

    // MARK: recording

    static var recordingsFolder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func toggleRecording(_ id: Int32) {
        if let rec = recorders.removeValue(forKey: id) { pjsua_recorder_destroy(rec); recording.remove(id); return }
        startRecording(id)
    }

    private func startRecording(_ id: Int32) {
        var ci = pjsua_call_info()
        guard recorders[id] == nil, pjsua_call_get_info(id, &ci) == 0, ci.conf_slot >= 0 else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let who = Self.callerName(from: str(ci.remote_info)).filter { $0.isLetter || $0.isNumber }
        let path = Self.recordingsFolder.appendingPathComponent("\(f.string(from: Date()))-\(who).wav").path
        let cs = CStrings()
        var file = cs.make(path)
        var rec: pjsua_recorder_id = -1
        guard pjsua_recorder_create(&file, 0, nil, 0, 0, &rec) == 0 else { return }
        let port = pjsua_recorder_get_conf_port(rec)
        pjsua_conf_connect(ci.conf_slot, port)      // what they say
        pjsua_conf_connect(0, port)                 // what you say
        recorders[id] = rec
        recording.insert(id)
    }

    private func incoming(call: pjsua_call_id) {
        // Tell the caller we are ringing (180), or send early media (183) if that is switched on.
        pjsua_call_answer(call, AppSettings.shared.allowOutgoingEarlyMedia ? 183 : 180, nil, nil)
        refresh(call: call, incoming: true)
        if let c = calls.first(where: { $0.id == call }) { CallKitManager.shared.reportIncoming(call, name: c.remote, address: c.address) }
    }

    private func refresh(call: pjsua_call_id, incoming: Bool?, info: pjsua_call_info? = nil) {
        var ci = info ?? pjsua_call_info()
        if info == nil { guard pjsua_call_get_info(call, &ci) == 0 else { return } }
        if ci.state == PJSIP_INV_STATE_DISCONNECTED {
            let secs = Int(ci.connect_duration.sec)
            let outgoing = ci.role == PJSIP_ROLE_UAC
            let remote = str(ci.remote_info)
            let inner = remote.firstIndex(of: "<").map { String(remote[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) } ?? remote
            CallLogStore.shared.add(CallRecord(
                peer: VCard.sipAddress(inner) ?? Self.displayName(from: remote),
                accountID: accountForPJ[ci.acc_id],
                direction: outgoing ? .outgoing : (secs > 0 ? .incoming : .missed),
                duration: secs))
            if let rec = recorders.removeValue(forKey: call) { pjsua_recorder_destroy(rec) }
            recording.remove(call); muted.remove(call); held.remove(call)
            calls.removeAll { $0.id == call }
            CallKitManager.shared.reportEnded(call)
            encryption[call] = nil; quality[call] = nil
            if currentCallID == call { currentCallID = calls.first?.id }
            if calls.isEmpty { speaker = false; statsTask?.cancel(); statsTask = nil }
            return
        }
        let connected = ci.state == PJSIP_INV_STATE_CONFIRMED
        let old = calls.first { $0.id == call }
        let entry = CallInfo(
            id: call,
            remote: Self.callerName(from: str(ci.remote_info)),
            state: Self.friendlyState(ci),
            incoming: incoming ?? (old?.incoming ?? false),
            connected: connected,
            since: connected ? (old?.since ?? Date()) : nil,
            accountID: accountForPJ[ci.acc_id],
            address: {
                let r = str(ci.remote_info)
                return VCard.sipAddress(r.firstIndex(of: "<").map { String(r[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) } ?? r) ?? ""
            }())
        if let i = calls.firstIndex(where: { $0.id == call }) { calls[i] = entry } else { calls.append(entry) }
        if currentCallID == nil || !calls.contains(where: { $0.id == currentCallID }) { currentCallID = call }
        if connected { startStats(); CallKitManager.shared.reportConnected(call, outgoing: !(entry.incoming)) }
    }

    // MARK: call quality and encryption (read from the media stream every two seconds)

    private func startStats() {
        guard statsTask == nil else { return }
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateStats()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func updateStats() {
        for c in calls where c.connected {
            var si = pjsua_stream_info()
            if pjsua_call_get_stream_info(c.id, 0, &si) == 0, si.type == PJMEDIA_TYPE_AUDIO {
                let p = si.info.aud.proto.rawValue
                let srtp = p & PJMEDIA_TP_PROFILE_SRTP.rawValue != 0
                let dtls = p & PJMEDIA_TP_PROTO_DTLS.rawValue != 0
                let account = c.accountID.flatMap { AccountStore.shared.account($0) }
                // "none" is only certain when the account asked for no encryption; otherwise leave it unknown
                encryption[c.id] = srtp ? (dtls ? .dtls : .srtp) : (account?.media == Account.Media.none ? CallSecurity.none : .unknown)
            }
            var st = pjsua_stream_stat()
            if pjsua_call_get_stream_stat(c.id, 0, &st) == 0 {
                let r = st.rtcp
                let total = Double(r.rx.pkt) + Double(r.rx.loss)
                let loss = total > 20 ? Double(r.rx.loss) * 100 / total : 0
                let jitterMs = Double(r.rx.jitter.mean) / 1000, rttMs = Double(r.rtt.last) / 1000
                // Forgiving on purpose: ordinary internet jitter and a distant server shouldn't cost a call its bars.
                var score = 5
                if loss > 3 { score -= 1 }; if loss > 8 { score -= 1 }; if loss > 15 { score -= 1 }
                if jitterMs > 60 { score -= 1 }; if jitterMs > 150 { score -= 1 }
                if rttMs > 350 { score -= 1 }; if rttMs > 700 { score -= 1 }
                quality[c.id] = max(1, score)
                qualityNumbers[c.id] = QualityNumbers(lossPercent: loss, jitterMs: jitterMs, roundTripMs: rttMs)
            }
        }
    }

    private func mediaChanged(call: pjsua_call_id) {
        var ci = pjsua_call_info()
        guard pjsua_call_get_info(call, &ci) == 0, ci.media_status == PJSUA_CALL_MEDIA_ACTIVE else { return }
        // Early media (audio before the call is answered) only plays if you allow it.
        if ci.state != PJSIP_INV_STATE_CONFIRMED && !AppSettings.shared.acceptEarlyMedia { return }
        pjsua_conf_connect(ci.conf_slot, 0)
        if !muted.contains(call) { pjsua_conf_connect(0, ci.conf_slot) }
        if ci.state == PJSIP_INV_STATE_CONFIRMED && AppSettings.shared.autoRecord { startRecording(call) }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        // CallKit activates the session (see audioSessionActivated); activating it here would fight with it.
    }

    /// CallKit has switched the audio session on: (re)open the sound device so audio flows on the lock screen too.
    func audioSessionDeactivated() { _ = pjsua_set_no_snd_dev() }

    func audioSessionActivated() {
        pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV)
        if speaker { try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker) }
    }

    // MARK: text messages (SIP MESSAGE)

    /// Sends a text and records it in the thread. The result arrives in `sendResult`.
    @discardableResult
    func sendMessage(_ text: String, to target: ThreadTarget, retrying existing: UUID? = nil) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let acc = pjAccounts[target.accountID] else { return false }
        let id: UUID
        if let existing { id = existing; MessageStore.shared.update(existing, status: .sending) }
        else { id = MessageStore.shared.add(Message(outgoing: true, text: body, status: .sending), to: target) }

        let tag = nextTag; nextTag += 1
        sendTags[tag] = (target, id)
        let cs = CStrings()
        var to = cs.make("sip:" + target.peer), mime = cs.make("text/plain"), content = cs.make(body)
        let status = pjsua_im_send(acc, &to, &mime, &content, nil, UnsafeMutableRawPointer(bitPattern: tag))
        if status != 0 {
            sendTags[tag] = nil
            MessageStore.shared.update(id, status: .failed, failure: "Couldn't send: \(Self.errorText(status))")
            return false
        }
        return true
    }

    private func sendResult(tag: Int, code: Int, reason: String, acc: pjsua_acc_id) {
        if let account = probeTags.removeValue(forKey: tag) {              // the hidden test text
            switch code {
            case 405, 501, 415:
                messagingNote[account] = "This server doesn't support text messages (\(code))."
                messagingCheck[account] = .unknown
            case 200..<300: break                                        // accepted: now wait to see whether it comes back
            default: messagingCheck[account] = .notDelivered             // refused (404, 403, ...): not routed
            }
            return
        }
        guard let (target, id) = sendTags.removeValue(forKey: tag) else { return }
        if (200..<300).contains(code) {
            MessageStore.shared.update(id, status: .sent)
            messagingNote[target.accountID] = nil
            return
        }
        let note: String
        switch code {
        case 405, 501, 415: // the server has no text routing: say so for the whole account
            note = "This server doesn't support text messages (\(code))."
            messagingNote[target.accountID] = note
        case 404, 480, 408, 503, 604: note = "Not delivered: they aren't reachable right now (\(code))."
        default: note = "Not delivered (\(code) \(reason))."
        }
        MessageStore.shared.update(id, status: .failed, failure: note)
    }

    private func received(from: String, text: String, acc: pjsua_acc_id) {
        guard let account = accountForPJ[acc] else { return }
        if text.hasPrefix(Self.probePrefix) {                              // our own test text came back: texting works here
            if probeTokens[account] == String(text.dropFirst(Self.probePrefix.count)) {
                messagingCheck[account] = .working
                messagingNote[account] = nil
            }
            return                                                       // never shown as a message
        }
        let inner = from.firstIndex(of: "<").map { String(from[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) } ?? from
        guard let peer = VCard.sipAddress(inner.components(separatedBy: ">").first ?? inner) else { return }
        MessageStore.shared.add(Message(outgoing: false, text: text, status: .sent, read: false), to: ThreadTarget(accountID: account, peer: peer))
    }

    // MARK: helpers

    /// PJSIP's own plain-language text for a status code ("Unable to resolve host…").
    static func errorText(_ status: pj_status_t) -> String {
        var buf = [CChar](repeating: 0, count: 160)
        _ = pj_strerror(status, &buf, pj_size_t(buf.count))
        let text = String(cString: buf)
        return text.isEmpty ? "error \(status)" : text
    }

    /// A name from L1ne's own contacts when the address matches, otherwise what the caller sent.
    static func callerName(from remote: String) -> String {
        if let addr = VCard.sipAddress(remote.firstIndex(of: "<").map { String(remote[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) } ?? remote) {
            let p = addr.split(separator: "@").map(String.init)
            if let n = ContactsStore.shared.name(forUser: p[0], domain: p[1]) { return n }
        }
        return displayName(from: remote)
    }

    /// What to show while a call is being set up, instead of PJSIP's internal names ("EARLY", "CONNECTING"):
    /// 180 Ringing means it is ringing at the other end; anything else before the answer is just "calling".
    static func friendlyState(_ ci: pjsua_call_info) -> String {
        switch ci.state {
        case PJSIP_INV_STATE_CALLING: return "Calling…"
        case PJSIP_INV_STATE_INCOMING: return "Incoming"
        case PJSIP_INV_STATE_EARLY: return ci.last_status == PJSIP_SC_RINGING ? "Ringing…" : "Calling…"
        case PJSIP_INV_STATE_CONNECTING: return "Connecting…"
        default: return str(ci.state_text).capitalized
        }
    }

    /// `"Max" <sip:7201@pbx>` -> `Max`, `sip:7201@pbx` -> `7201`
    static func displayName(from remote: String) -> String {
        if let q1 = remote.firstIndex(of: "\""), let q2 = remote[remote.index(after: q1)...].firstIndex(of: "\"") {
            let n = remote[remote.index(after: q1)..<q2]
            if !n.isEmpty { return String(n) }
        }
        var s = remote
        if let l = s.firstIndex(of: "<"), let g = s.firstIndex(of: ">") { s = String(s[s.index(after: l)..<g]) }
        s = s.replacingOccurrences(of: "sips:", with: "").replacingOccurrences(of: "sip:", with: "")
        return s.split(separator: "@").first.map(String.init) ?? s
    }
}

// MARK: pj_str_t bridging

private func str(_ s: pj_str_t) -> String {
    guard let p = s.ptr, s.slen > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(s.slen)), as: UTF8.self)
}

/// Owns C copies of strings so pj_str_t values stay valid until the owner goes away.
private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func make(_ s: String) -> pj_str_t {
        let p = strdup(s)!
        pointers.append(p)
        return pj_str_t(ptr: p, slen: pj_ssize_t(strlen(p)))
    }
    deinit { pointers.forEach { free($0) } }
}

/// Reads "new messages" from a message-summary NOTIFY body ("Voice-Message: 2/5" or "Messages-Waiting: no").
private func mwiNewCount(_ rdata: UnsafeMutablePointer<pjsip_rx_data>?) -> Int? {
    guard let msg = rdata?.pointee.msg_info.msg, let body = msg.pointee.body, let data = body.pointee.data else { return nil }
    let text = String(decoding: UnsafeRawBufferPointer(start: data, count: Int(body.pointee.len)), as: UTF8.self)
    var waiting: Bool?
    for line in text.split(whereSeparator: \.isNewline) {
        let l = line.lowercased()
        if l.hasPrefix("messages-waiting:") { waiting = l.contains("yes") }
        if l.hasPrefix("voice-message:") {
            let rest = l.dropFirst("voice-message:".count).trimmingCharacters(in: .whitespaces)
            if let n = Int(rest.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "") { return n }
        }
    }
    return waiting == false ? 0 : (waiting == true ? 1 : nil)
}
