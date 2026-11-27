import Foundation

/// How a phone number is shown. Only for display: what is dialled, stored and matched against contacts stays as it was.
enum PhoneFormat {
    /// Does this look like a number for the outside world: 10 digits, or 11 starting with 1, with or without a leading +?
    /// Extensions (7001), codes (*97, 0) and numbers that already carry an outside-line prefix are not.
    static func isOutside(_ text: String) -> Bool {
        var s = text
        if s.hasPrefix("+") { s.removeFirst(); guard s.hasPrefix("1") else { return false } }
        if s.count == 11, s.hasPrefix("1") { s.removeFirst() }
        let d = Array(s)
        return d.count == 10 && d.allSatisfy { $0.isASCII && $0.isNumber } && "23456789".contains(d[0]) && "23456789".contains(d[3])
    }

    /// A bare North American number ("6517604266", "16517604266", "+16517604266") as "(651) 760-4266".
    /// Anything else (an extension, a name, an international number, a number already formatted) comes back unchanged.
    static func pretty(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("+") { s.removeFirst(); guard s.hasPrefix("1") else { return text } }
        if s.count == 11, s.hasPrefix("1") { s.removeFirst() }
        guard s.count == 10, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return text }
        let d = Array(s)
        guard "23456789".contains(d[0]), "23456789".contains(d[3]) else { return text }
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}
