import Foundation

/// Reads an address book over CardDAV (RFC 6352): one REPORT returns every card; servers that don't allow it
/// get a PROPFIND listing and one GET per card. Only entries with a SIP address are kept (see VCard).
enum CardDAV {
    enum Failure: Error, LocalizedError {
        case badURL, status(Int), noCards
        var errorDescription: String? {
            switch self {
            case .badURL: "That isn't a valid address book URL."
            case .status(401): "The server rejected the user name or password (401)."
            case .status(404): "The address book wasn't found (404). Check the URL."
            case .status(let c): "The server answered \(c)."
            case .noCards: "The address book answered, but it contains no cards."
            }
        }
    }

    static func fetch(url: URL, username: String, password: String) async throws -> VCard.Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { throw Failure.badURL }
        let auth = Auth(username: username, password: password)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg, delegate: auth, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // 1. REPORT addressbook-query
        var req = URLRequest(url: url)
        req.httpMethod = "REPORT"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
          <D:prop><D:getetag/><C:address-data/></D:prop>
        </C:addressbook-query>
        """.utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 207 {
            let cards = MultiStatus.texts(data, element: "address-data")
            return VCard.parse(cards.joined(separator: "\n"))
        }
        guard code == 405 || code == 501 else { throw Failure.status(code) }

        // 2. fallback: PROPFIND for the card list, then GET each
        var list = URLRequest(url: url)
        list.httpMethod = "PROPFIND"
        list.setValue("1", forHTTPHeaderField: "Depth")
        list.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        list.httpBody = Data(#"<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>"#.utf8)
        let (ldata, lresp) = try await session.data(for: list)
        let lcode = (lresp as? HTTPURLResponse)?.statusCode ?? 0
        guard lcode == 207 else { throw Failure.status(lcode) }
        var texts: [String] = []
        for href in MultiStatus.texts(ldata, element: "href").prefix(3000) where href.lowercased().hasSuffix(".vcf") {
            guard let card = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
            if let (d, r) = try? await session.data(from: card), (r as? HTTPURLResponse)?.statusCode == 200 {
                texts.append(String(decoding: d, as: UTF8.self))
            }
        }
        return VCard.parse(texts.joined(separator: "\n"))
    }

    /// Answers Basic and Digest challenges with the saved credentials, once.
    private final class Auth: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let username: String, password: String
        init(username: String, password: String) { self.username = username; self.password = password }
        func urlSession(_ s: URLSession, task: URLSessionTask, didReceive c: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let m = c.protectionSpace.authenticationMethod
            guard (m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest),
                  c.previousFailureCount == 0, !username.isEmpty else {
                completionHandler(.performDefaultHandling, nil); return
            }
            completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        }
    }

    /// Collects the text of every element with a given local name in a WebDAV multistatus answer.
    private final class MultiStatus: NSObject, XMLParserDelegate {
        let want: String
        var out: [String] = []
        private var current: String?
        init(_ want: String) { self.want = want }
        static func texts(_ data: Data, element: String) -> [String] {
            let m = MultiStatus(element)
            let p = XMLParser(data: data); p.shouldProcessNamespaces = true; p.delegate = m; p.parse()
            return m.out
        }
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName q: String?, attributes: [String: String]) {
            if name.lowercased() == want { current = "" }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if current != nil { current! += s } }
        func parser(_ p: XMLParser, foundCDATA b: Data) { if current != nil { current! += String(decoding: b, as: UTF8.self) } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName q: String?) {
            if name.lowercased() == want, let c = current { out.append(c.trimmingCharacters(in: .whitespacesAndNewlines)); current = nil }
        }
    }
}
