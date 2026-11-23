import Foundation

/// Turns directory entries into SIP-only contacts. Pure functions, so they can be tested without a server.
enum DirectoryMapping {
    /// - sipAttr: attribute holding the SIP address (`sip:max@pbx`, `max@pbx`, or a bare extension when `domain` is set)
    /// - phoneAsExtension: when an entry has no SIP address, treat its phone attribute as an extension on `domain`
    static func ldap(_ entries: [LDAPEntry], nameAttr: String, sipAttr: String, phoneAttr: String,
                     phoneAsExtension: Bool, domain: String) -> VCard.Result {
        var out: [VCard.Entry] = []
        var skipped = 0
        let dom = domain.trimmingCharacters(in: .whitespaces).lowercased()
        for e in entries {
            var addresses: [String] = []
            for raw in e.attributes[sipAttr.lowercased()] ?? [] {
                let v = raw.trimmingCharacters(in: .whitespaces)
                if let a = VCard.sipAddress(v.lowercased().hasPrefix("sip") ? v : (v.contains("@") ? "sip:" + v : (dom.isEmpty ? "" : "sip:\(v)@\(dom)"))),
                   !addresses.contains(a) { addresses.append(a) }
            }
            if addresses.isEmpty, phoneAsExtension, !dom.isEmpty, let phone = e.first(phoneAttr) {
                let ext = phone.filter { $0.isNumber }
                if !ext.isEmpty { addresses.append("\(ext)@\(dom)") }
            }
            if addresses.isEmpty { skipped += 1; continue }
            let name = e.first(nameAttr) ?? e.first("displayName") ?? e.first("cn")
                ?? [e.first("givenName"), e.first("sn")].compactMap { $0 }.joined(separator: " ")
            for a in addresses { out.append(VCard.Entry(name: name.isEmpty ? (rdnValue(e.dn) ?? a) : name, address: a)) }
        }
        return VCard.Result(entries: out, skipped: skipped)
    }

    /// "cn=Jordan Lee,ou=people,dc=example,dc=com" -> "Jordan Lee"
    static func rdnValue(_ dn: String) -> String? {
        guard let first = dn.split(separator: ",", maxSplits: 1).first, let eq = first.firstIndex(of: "=") else { return nil }
        let v = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
