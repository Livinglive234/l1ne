import Foundation

/// Takes what must never be shown or shared out of SIP log text: passwords' digests, SRTP keys and anything that looks like a secret.
enum LogRedactor {
    private static let rules: [(NSRegularExpression, String)] = {
        func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            (re(#"^((?:Proxy-)?Authorization:).*$"#, [.caseInsensitive, .anchorsMatchLines]), "$1 [removed]"),       // the whole header: the digest response, and the user name with it
            (re(#"(inline:)\S+"#, [.caseInsensitive]), "$1[removed]"),                                              // a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:KEY
            (re(#"\b(response|cnonce)\s*=\s*"?[^",\s]*"?"#, [.caseInsensitive]), "$1=\"[removed]\""),
            (re(#"\b(password|passwd|secret|pwd)\b(\s*[=:]\s*)\S+"#, [.caseInsensitive]), "$1$2[removed]"),
        ]
    }()

    /// Words that must be present for a rule to have anything to remove: most log lines have none, and this runs on PJSIP's own thread for every line.
    private static let triggers = ["authorization:", "inline:", "response", "cnonce", "password", "passwd", "secret", "pwd"]

    static func clean(_ text: String) -> String {
        let lower = text.lowercased()
        guard triggers.contains(where: { lower.contains($0) }) else { return text }
        var s = text
        for (re, template) in rules { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template) }
        return s
    }
}

/// The last stretch of what the SIP engine did, kept in memory only (gone when L1ne closes), with secrets taken out as each entry arrives.
final class SipLog: @unchecked Sendable {
    static let shared = SipLog()
    private let lock = NSLock()
    private var entries: [String] = []
    private var changes = 0
    private let maxEntries = 2500, maxEntryChars = 6000

    func add(_ raw: String) {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var clean = LogRedactor.clean(raw.trimmingCharacters(in: .newlines))
        if clean.utf8.count > maxEntryChars { clean = String(clean.prefix(maxEntryChars)) + " …" }
        lock.lock(); defer { lock.unlock() }
        changes += 1
        entries.append(clean)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }
    func text(last n: Int = 2500) -> String { lock.lock(); defer { lock.unlock() }; return entries.suffix(n).joined(separator: "\n") }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    /// Goes up with every change, so a screen can tell whether anything is new without building the text (the count stops moving at the cap).
    var revision: Int { lock.lock(); defer { lock.unlock() }; return changes }
    func clear() { lock.lock(); entries.removeAll(); changes += 1; lock.unlock() }
}
