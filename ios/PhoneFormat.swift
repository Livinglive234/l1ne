import Foundation

/// How a phone number is shown. Only for display: what is dialled, stored and matched against contacts stays as it was.
enum PhoneFormat {
    /// The ten digits of a bare North American number ("6517604266", "16517604266", "+16517604266"), or nil for anything else
    /// (an extension, a code like *97, a name, an international number, one already formatted, or one whose area code or exchange starts with 0 or 1).
    private static func nanp(_ text: String) -> [Character]? {
        var s = text
        if s.hasPrefix("+") { s.removeFirst(); guard s.hasPrefix("1") else { return nil } }
        if s.count == 11, s.hasPrefix("1") { s.removeFirst() }
        let d = Array(s)
        guard d.count == 10, d.allSatisfy({ $0.isASCII && $0.isNumber }), "23456789".contains(d[0]), "23456789".contains(d[3]) else { return nil }
        return d
    }

    /// Does this look like a number for the outside world: 10 digits, or 11 starting with 1, with or without a leading +?
    /// Extensions (7001), codes (*97, 0) and numbers that already carry an outside-line prefix are not.
    static func isOutside(_ text: String) -> Bool { nanp(text) != nil }

    /// The name a caller sent, to keep in the call history: "" when there is none, or when it is only the number again.
    static func callerIDName(remote: String) -> String {
        guard let lt = remote.firstIndex(of: "<"), lt != remote.startIndex else { return "" }
        let n = remote[..<lt].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        if n.isEmpty { return "" }
        var user = remote[lt...]; if let r = user.range(of: "sip:") ?? user.range(of: "sips:") { user = user[r.upperBound...] }
        let u = String(user.prefix { $0 != "@" && $0 != ">" && $0 != ";" })
        let digits = n.filter(\.isNumber)
        return (n.lowercased() == u.lowercased() || (!digits.isEmpty && digits == u.filter(\.isNumber))) ? "" : n
    }

    /// A bare North American number as "(651) 760-4266". Anything else comes back unchanged.
    static func pretty(_ text: String) -> String {
        guard let d = nanp(text.trimmingCharacters(in: .whitespaces)) else { return text }
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}
