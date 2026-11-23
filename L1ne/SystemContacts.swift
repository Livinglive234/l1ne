import Contacts

/// Turns picked system contacts into SIP-only entries (pure function, no permission needed).
enum SystemContacts {
    static func convert(_ contacts: [CNContact]) -> VCard.Result {
        var entries: [VCard.Entry] = []
        var skipped = 0
        for c in contacts {
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
            var found: [String] = []
            // Contacts stores a SIP address as an instant-message entry (service "SIP") or a URL.
            for im in c.instantMessageAddresses {
                let u = im.value.username.trimmingCharacters(in: .whitespaces)
                let isSIP = im.value.service.caseInsensitiveCompare("SIP") == .orderedSame
                if let a = VCard.sipAddress(u) ?? (isSIP ? VCard.sipAddress("sip:" + u) : nil), !found.contains(a) { found.append(a) }
            }
            for url in c.urlAddresses {
                if let a = VCard.sipAddress(url.value as String), !found.contains(a) { found.append(a) }
            }
            if found.isEmpty { skipped += 1; continue }
            for a in found { entries.append(VCard.Entry(name: name.isEmpty ? a : name, address: a)) }
        }
        return VCard.Result(entries: entries, skipped: skipped)
    }
}
