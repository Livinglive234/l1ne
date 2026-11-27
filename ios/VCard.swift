import Foundation

/// Minimal vCard 3.0/4.0 reader that keeps only entries with a SIP address.
/// Phone numbers and everything else in the card are ignored on purpose.
enum VCard {
    struct Entry: Equatable {
        var name: String
        var address: String      // user@domain, domain lower-cased, no sip: scheme or URI parameters
    }
    struct Result: Equatable {
        var entries: [Entry]
        var skipped: Int         // cards with no SIP address
    }

    static func parse(_ text: String) -> Result {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalised.components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()        // folded line continues the previous one
            } else {
                lines.append(raw)
            }
        }

        var entries: [Entry] = []
        var skipped = 0
        var fn = "", n = ""
        var sips: [String] = []
        var inCard = false

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var prop = String(line[..<colon]).uppercased()
            let value = String(line[line.index(after: colon)...])
            if let dot = prop.firstIndex(of: ".") { prop = String(prop[prop.index(after: dot)...]) }   // item1.IMPP
            let base = prop.split(separator: ";", maxSplits: 1).first.map(String.init) ?? prop

            switch base {
            case "BEGIN" where value.uppercased() == "VCARD":
                inCard = true; fn = ""; n = ""; sips = []
            case "END" where value.uppercased() == "VCARD":
                guard inCard else { continue }
                inCard = false
                if sips.isEmpty { skipped += 1; continue }
                let name = !fn.isEmpty ? fn : n
                for s in sips { entries.append(Entry(name: name.isEmpty ? s : name, address: s)) }
            case "FN" where inCard:
                fn = unescape(value).trimmingCharacters(in: .whitespaces)
            case "N" where inCard:
                // Family;Given;Additional;Prefix;Suffix
                let p = value.components(separatedBy: ";").map { unescape($0).trimmingCharacters(in: .whitespaces) }
                n = [p.count > 1 ? p[1] : "", p.first ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            case "IMPP", "X-SIP", "SIP", "X-SIP-URI", "TEL", "URL":
                if inCard, let a = sipAddress(value), !sips.contains(a) { sips.append(a) }
            default: break
            }
        }
        return Result(entries: entries, skipped: skipped)
    }

    /// `sip:7201@Pbx.Example.com;transport=tls` -> `7201@pbx.example.com`; nil if it is not a SIP URI.
    static func sipAddress(_ value: String) -> String? {
        var v = unescape(value).trimmingCharacters(in: .whitespaces)
        let lower = v.lowercased()
        if lower.hasPrefix("sips:") { v.removeFirst(5) } else if lower.hasPrefix("sip:") { v.removeFirst(4) } else { return nil }
        if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
        if let q = v.firstIndex(of: "?") { v = String(v[..<q]) }
        let parts = v.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0] + "@" + parts[1].lowercased()
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\N", with: " ")
         .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
