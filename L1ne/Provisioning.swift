import Foundation

/// Reads Linphone-style remote configuration: the same XML (`<config><section name="proxy_0"><entry name="...">`)
/// that Linphone fetches after scanning a QR code, so existing provisioning files keep working.
/// It is fetched once, on demand. Nothing here polls.
enum Provisioning {
    struct Parsed: Equatable {
        var account: Account
        var secret: String
    }
    struct Result: Equatable {
        var accounts: [Parsed] = []
        var contactsURL: String?
        var notes: [String] = []
    }
    enum Failure: Error, LocalizedError {
        case notHTTPS, badStatus(Int), notConfig, nothingUsable
        var errorDescription: String? {
            switch self {
            case .notHTTPS: "The configuration link must be https."
            case .badStatus(let c): "The server answered \(c)."
            case .notConfig: "That isn't a Linphone-style configuration file."
            case .nothingUsable: "The file has no usable SIP account."
            }
        }
    }

    // MARK: link handling

    /// Accepts a scanned or pasted string: `https://…`, `linphone-config:https://…`, `l1ne-config:https://…`.
    static func configURL(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["linphone-config:", "l1ne-config:"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
        }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    static func fetch(_ url: URL) async throws -> Result {
        try parse(xml: try await httpsData(url, userAgent: "L1ne"))
    }

    /// One manual HTTPS GET with a 15 second limit, for the setup file and the vCard link. Nothing is kept afterwards.
    static func httpsData(_ url: URL, userAgent: String? = nil) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.notHTTPS }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw Failure.badStatus(h.statusCode) }
        return data
    }

    // MARK: parsing

    static func parse(xml: Data) throws -> Result {
        let reader = SectionReader()
        let p = XMLParser(data: xml)
        p.delegate = reader
        guard p.parse(), !reader.sections.isEmpty else { throw Failure.notConfig }
        let s = reader.sections

        var result = Result()
        let proxies = s.keys.filter { $0.hasPrefix("proxy_") }.sorted { idx($0) < idx($1) }
        let auths = s.keys.filter { $0.hasPrefix("auth_info_") }.map { s[$0]! }

        for name in proxies {
            let e = s[name]!
            guard let ident = parseIdentity(e["reg_identity"] ?? "") else { continue }
            if e["reg_sendregister"] == "0" { continue }

            var a = Account()
            a.username = ident.user
            a.domain = ident.domain
            a.label = ident.domain            // named after the SIP address's domain; rename it in the editor
            a.displayName = ident.display
            if let ex = Int(e["reg_expires"] ?? ""), ex >= 60 { a.expires = ex }
            if let vm = e["voicemail_uri"] ?? e["mwi_uri"], !vm.isEmpty { a.voicemailURI = vm }
            if let proxy = parseProxy(e["reg_proxy"] ?? e["reg_route"] ?? "") {
                a.domain = proxy.host.isEmpty ? ident.domain : proxy.host
                a.port = proxy.port ?? (proxy.transport == .tls ? 5061 : 5060)
                a.transport = proxy.transport
            }

            let match = auths.first { ($0["username"] ?? "") == ident.user && (($0["domain"] ?? ident.domain) == ident.domain) }
                     ?? auths.first { ($0["username"] ?? "") == ident.user }
            var secret = ""
            if let m = match {
                if let u = m["userid"], !u.isEmpty, u != ident.user { a.authUser = u }
                secret = m["passwd"] ?? ""
                if secret.isEmpty, m["ha1"] != nil {
                    result.notes.append("\(ident.user)@\(ident.domain) only has a password hash (ha1); enter the secret by hand.")
                }
            } else {
                result.notes.append("No credentials for \(ident.user)@\(ident.domain); enter the secret by hand.")
            }
            let enc = (s["sip"]?["media_encryption"] ?? s["rtp"]?["media_encryption"] ?? e["media_encryption"] ?? "").lowercased()
            switch enc {
            case "none": a.media = .none
            case "dtls": a.media = .srtpDTLS
            case "zrtp":
                a.media = .srtpSDES
                result.notes.append("\(ident.user)@\(ident.domain) asks for ZRTP, which L1ne doesn't support; using SRTP instead.")
            default: a.media = .srtpSDES
            }
            let mandatory = (s["sip"]?["media_encryption_mandatory"] ?? e["media_encryption_mandatory"] ?? "0")
            a.mediaMandatory = (mandatory == "1" || mandatory.lowercased() == "true")
            result.accounts.append(Parsed(account: a, secret: secret))
        }

        if let c = s["misc"]?["contacts-vcard-list"], !c.isEmpty { result.contactsURL = c }
        // L1ne's own section (Linphone ignores it): <section name="l1ne"><entry name="outbound_prefix">9</entry></section>
        if let p = s["l1ne"]?["outbound_prefix"], p.count <= 4, p.allSatisfy({ "0123456789*#".contains($0) }), !p.isEmpty {
            for i in result.accounts.indices { result.accounts[i].account.outboundPrefix = p }
        }
        guard !result.accounts.isEmpty else { throw Failure.nothingUsable }
        return result
    }

    private static func idx(_ s: String) -> Int { Int(s.split(separator: "_").last ?? "") ?? 0 }

    /// `"Max B" <sip:7201@pbx.example.com>` / `sip:7201@host` / `<sip:…>`
    static func parseIdentity(_ raw: String) -> (display: String, user: String, domain: String)? {
        var display = ""
        var uri = raw.trimmingCharacters(in: .whitespaces)
        if let lt = uri.firstIndex(of: "<"), let gt = uri.lastIndex(of: ">"), lt < gt {
            display = String(uri[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            uri = String(uri[uri.index(after: lt)..<gt])
        }
        guard let addr = VCard.sipAddress(uri) else { return nil }
        let p = addr.split(separator: "@", maxSplits: 1).map(String.init)
        return (display, p[0], p[1])
    }

    static func parseProxy(_ raw: String) -> (host: String, port: Int?, transport: Account.Transport)? {
        var v = raw.trimmingCharacters(in: CharacterSet(charactersIn: " <>\""))
        guard !v.isEmpty else { return nil }
        var transport = Account.Transport.udp
        let lower = v.lowercased()
        if lower.hasPrefix("sips:") { v.removeFirst(5); transport = .tls } else if lower.hasPrefix("sip:") { v.removeFirst(4) }
        let parts = v.components(separatedBy: ";")
        v = parts[0]
        for p in parts.dropFirst() where p.lowercased().hasPrefix("transport=") {
            transport = Account.Transport(rawValue: String(p.dropFirst(10)).lowercased()) ?? transport
        }
        var port: Int?
        if let c = v.lastIndex(of: ":"), let n = Int(v[v.index(after: c)...]) { port = n; v = String(v[..<c]) }
        return (v.lowercased(), port, transport)
    }

    private final class SectionReader: NSObject, XMLParserDelegate {
        var sections: [String: [String: String]] = [:]
        private var section: String?
        private var entry: String?
        private var text = ""

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "section": section = attributes["name"]
            case "entry": entry = attributes["name"]; text = ""
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if entry != nil { text += s } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "entry", let sec = section, let e = entry {
                sections[sec, default: [:]][e] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                entry = nil
            } else if name == "section" { section = nil }
        }
    }
}
