import Foundation
import Security

struct Account: Codable, Identifiable, Equatable {
    enum Transport: String, Codable, CaseIterable { case tls, tcp, udp }
    enum Media: String, Codable, CaseIterable { case none, srtpSDES = "srtp-sdes", srtpDTLS = "srtp-dtls" }

    var id = UUID()
    var label = ""
    var displayName = ""              // shown to the people you call
    var domain = ""
    var port = 5061
    var transport = Transport.tls
    var registrarURI = ""             // optional raw override, e.g. sip:pbx.example.com:5061;transport=tls
    var outboundProxy = ""            // optional, e.g. sip:proxy.example.com;lr
    var expires = 3600
    var enabled = true                // the "Connected" switch
    var media = Media.srtpSDES
    var mediaMandatory = true         // refuse unencrypted calls (the form PBXes that require SRTP expect)
    var username = ""
    var authUser = ""                 // blank = same as username
    var contactsURL = ""              // where its contacts were last imported from (manual re-import only)
    var pushGateway = ""              // LATER (push proxy, see docs/ROADMAP.md): unused until then
    var dialStripPrefix = ""          // dial rules: remove this, then add dialAddPrefix
    var dialAddPrefix = ""
    var outboundPrefix = ""           // put in front of numbers that look like outside numbers (10 digits, or 1 + 10), never extensions; e.g. 9
    var intlPrefix = ""               // country calling code without "+", e.g. 1
    var formatWithPrefix = false      // turn national numbers into +<prefix><number>
    var plusTo00 = false              // send +… as 00…
    var voicemailURI = "*97"          // e.g. *97 or sip:*97@pbx
    var mwiEnabled = true             // subscribe to the message-waiting indicator
    var iceEnabled = false
    var turnEnabled = false
    var stunServer = ""               // host[:port]
    var turnUser = ""                 // the TURN password lives in the Keychain

    /// The standard SIP port for a transport: 5060 for UDP and TCP, 5061 for TLS.
    static func defaultPort(for t: Transport) -> Int { t == .tls ? 5061 : 5060 }

    /// Switching transport moves the port with it, unless you set a custom one (anything but 5060 / 5061).
    mutating func changeTransport(to t: Transport) {
        if port == 5060 || port == 5061 || port <= 0 { port = Account.defaultPort(for: t) }
        transport = t
    }

    /// Reads what you typed in the Domain field: `pbx.example.com`, `pbx.example.com:5080` or `sip:pbx.example.com`.
    mutating func setServer(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["sips:", "sip:"] where t.lowercased().hasPrefix(scheme) { t.removeFirst(scheme.count) }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        if let semi = t.firstIndex(of: ";") { t = String(t[..<semi]) }
        if !t.hasPrefix("["), let c = t.lastIndex(of: ":"), let p = Int(t[t.index(after: c)...]), (1...65535).contains(p) {
            port = p; t = String(t[..<c])
        }
        domain = t
    }

    /// Final touches when a new account is created from the short form: the server text is parsed, the account is named
    /// after its display name, and SRTP (which needs TLS for its keys) is only kept on TLS.
    mutating func finishNewAccount() {
        setServer(domain)
        if label.isEmpty { label = displayName }
        if transport != .tls && media == .srtpSDES { media = .none; mediaMandatory = false }
    }

    var title: String { label.isEmpty ? domain : label }
    /// The name with the sign-in name after it, "pbx.example.com (7001)": tells two accounts on one server apart in menus and pickers.
    var titleWithUser: String { username.isEmpty ? title : "\(title) (\(username))" }
    var sipAddress: String { "sip:\(username)@\(domain)" }

    /// Up to two letters for the avatar: initials of the display name ("Max Example" -> ME), else of the label, else the first letters of the server name.
    var initials: String {
        let source = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? label : displayName
        let words = source.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        if !words.isEmpty { return String(words.prefix(2).compactMap { $0.first }).uppercased() }
        return String(domain.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    /// Where the voicemail button dials: a bare number or code (`*97`, `7000`) becomes sip:<it>@<your server>, a full
    /// sip: address is used as typed. defaults to *97; nil only if the field is cleared during editing.
    var voicemailTarget: String? {
        let v = voicemailURI.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        let l = v.lowercased()
        return (l.hasPrefix("sip:") || l.hasPrefix("sips:")) ? v : "sip:\(v)@\(domain)"
    }

    /// Applies the account's dial rules to what was typed.
    func dial(_ number: String) -> String {
        var n = number.filter { !" -()".contains($0) }
        if !dialStripPrefix.isEmpty, n.hasPrefix(dialStripPrefix) { n.removeFirst(dialStripPrefix.count) }
        // an outside number (10 digits, or 1 + 10) gets the outside-line prefix, and is already complete, so no country code is added
        let outside = !outboundPrefix.isEmpty && PhoneFormat.isOutside(n)
        // national number -> international: only long numbers, never extensions or codes like *97
        if !outside, formatWithPrefix, !intlPrefix.isEmpty, !n.hasPrefix("+"), !n.hasPrefix("00"),
           n.first?.isNumber == true, n.filter(\.isNumber).count >= 7 {
            if n.hasPrefix("0") { n.removeFirst() }
            n = "+" + intlPrefix + n
        }
        if outside { n = outboundPrefix + (n.hasPrefix("+") ? String(n.dropFirst()) : n) }
        else if plusTo00, n.hasPrefix("+") { n = "00" + n.dropFirst() }
        return dialAddPrefix + n
    }

    /// An address as it was dialled -> as it should be kept in the call history: without the outside-line prefix, so redial and
    /// callbacks still work. "96125550142@pbx" with prefix 9 -> "6125550142@pbx".
    func withoutOutboundPrefix(_ address: String) -> String {
        guard !outboundPrefix.isEmpty else { return address }
        let parts = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts[0].hasPrefix(outboundPrefix) else { return address }
        let rest = String(parts[0].dropFirst(outboundPrefix.count))
        guard PhoneFormat.isOutside(rest) else { return address }
        return parts.count == 2 ? rest + "@" + parts[1] : rest
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, label, displayName, domain, port, transport, registrarURI, outboundProxy, expires, enabled, media, mediaMandatory
        case username, authUser, contactsURL, pushGateway, dialStripPrefix, dialAddPrefix, outboundPrefix, intlPrefix, formatWithPrefix, plusTo00
        case voicemailURI, mwiEnabled, iceEnabled, turnEnabled, stunServer, turnUser
    }

    /// Older saved accounts have fewer fields; every missing one takes its default.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Account()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? def.id
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? def.label
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? def.displayName
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? def.domain
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? def.port
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? def.transport
        registrarURI = try c.decodeIfPresent(String.self, forKey: .registrarURI) ?? def.registrarURI
        outboundProxy = try c.decodeIfPresent(String.self, forKey: .outboundProxy) ?? def.outboundProxy
        expires = try c.decodeIfPresent(Int.self, forKey: .expires) ?? def.expires
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? def.enabled
        media = try c.decodeIfPresent(Media.self, forKey: .media) ?? def.media
        mediaMandatory = try c.decodeIfPresent(Bool.self, forKey: .mediaMandatory) ?? def.mediaMandatory
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? def.username
        authUser = try c.decodeIfPresent(String.self, forKey: .authUser) ?? def.authUser
        contactsURL = try c.decodeIfPresent(String.self, forKey: .contactsURL) ?? def.contactsURL
        pushGateway = try c.decodeIfPresent(String.self, forKey: .pushGateway) ?? def.pushGateway
        dialStripPrefix = try c.decodeIfPresent(String.self, forKey: .dialStripPrefix) ?? def.dialStripPrefix
        dialAddPrefix = try c.decodeIfPresent(String.self, forKey: .dialAddPrefix) ?? def.dialAddPrefix
        outboundPrefix = try c.decodeIfPresent(String.self, forKey: .outboundPrefix) ?? def.outboundPrefix
        intlPrefix = try c.decodeIfPresent(String.self, forKey: .intlPrefix) ?? def.intlPrefix
        formatWithPrefix = try c.decodeIfPresent(Bool.self, forKey: .formatWithPrefix) ?? def.formatWithPrefix
        plusTo00 = try c.decodeIfPresent(Bool.self, forKey: .plusTo00) ?? def.plusTo00
        voicemailURI = try c.decodeIfPresent(String.self, forKey: .voicemailURI).flatMap { $0.isEmpty ? nil : $0 } ?? def.voicemailURI
        mwiEnabled = try c.decodeIfPresent(Bool.self, forKey: .mwiEnabled) ?? def.mwiEnabled
        iceEnabled = try c.decodeIfPresent(Bool.self, forKey: .iceEnabled) ?? def.iceEnabled
        turnEnabled = try c.decodeIfPresent(Bool.self, forKey: .turnEnabled) ?? def.turnEnabled
        stunServer = try c.decodeIfPresent(String.self, forKey: .stunServer) ?? def.stunServer
        turnUser = try c.decodeIfPresent(String.self, forKey: .turnUser) ?? def.turnUser
    }
}

/// Country calling codes offered by the international-prefix picker.
enum Countries {
    static let all: [(name: String, code: String)] = [
        ("United States / Canada", "1"), ("United Kingdom", "44"), ("Australia", "61"), ("New Zealand", "64"),
        ("Ireland", "353"), ("Germany", "49"), ("France", "33"), ("Spain", "34"), ("Italy", "39"), ("Netherlands", "31"),
        ("Belgium", "32"), ("Switzerland", "41"), ("Austria", "43"), ("Sweden", "46"), ("Norway", "47"), ("Denmark", "45"),
        ("Finland", "358"), ("Poland", "48"), ("Portugal", "351"), ("Czechia", "420"), ("Greece", "30"), ("Turkey", "90"),
        ("Israel", "972"), ("India", "91"), ("Japan", "81"), ("South Korea", "82"), ("China", "86"), ("Singapore", "65"),
        ("Hong Kong", "852"), ("Philippines", "63"), ("Mexico", "52"), ("Brazil", "55"), ("Argentina", "54"),
        ("Chile", "56"), ("Colombia", "57"), ("South Africa", "27"), ("Nigeria", "234"), ("Egypt", "20"), ("UAE", "971")
    ]
    static func name(for code: String) -> String? { all.first { $0.code == code }?.name }
}

/// Accounts live in UserDefaults; secrets only in the Keychain.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    private let key = "accounts.v1"

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedID: UUID?
    private let selectedKey = "accounts.selected.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let a = try? JSONDecoder().decode([Account].self, from: d) { accounts = a }
        selectedID = UserDefaults.standard.string(forKey: selectedKey).flatMap(UUID.init)
    }

    /// The account that dials and whose initials show on the avatar. Falls back to the first account.
    var selected: Account? { accounts.first { $0.id == selectedID } ?? accounts.first }

    func select(_ id: UUID) {
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
    }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    /// The account that dials for something tied to `id` (a contact, a call, a chat): that account, or the selected one when there is none.
    func dialAccount(_ id: UUID?) -> Account? { id.flatMap(account) ?? selected }

    func save(_ account: Account, secret: String?, turnSecret: String? = nil) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        if let secret { Keychain.set(secret, for: account.id.uuidString) }
        if let turnSecret { Keychain.set(turnSecret, for: account.id.uuidString + ".turn") }
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) { select(account.id) }
        persist()
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        Keychain.delete(id.uuidString)
        Keychain.delete(id.uuidString + ".turn")
        if selectedID == id { selectedID = accounts.first?.id; UserDefaults.standard.set(selectedID?.uuidString, forKey: selectedKey) }
        persist()
    }

    func secret(_ id: UUID) -> String { Keychain.get(id.uuidString) ?? "" }
    func turnSecret(_ id: UUID) -> String { Keychain.get(id.uuidString + ".turn") ?? "" }

    private func persist() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: key) }
    }
}

enum Keychain {
    private static let service = "com.livenet.l1ne.account"

    static func set(_ value: String, for key: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]  // readable when a push wakes the app
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
