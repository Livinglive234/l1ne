import Foundation

/// L1ne's own address book. It never reads the phone's Contacts, never fetches by itself,
/// and only holds entries that have a SIP address. Entries arrive by a manual import or are typed in.
struct Contact: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String           // user@domain
    var accountID: UUID?          // which account dials it; nil = the first account
    var imported = false
    var source: String?           // "link", "file", "picker", or "dir:<id>" for a synced directory; nil = typed in

    var user: String { String(address.split(separator: "@").first ?? "") }
}

@MainActor
final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()
    @Published private(set) var contacts: [Contact] = []

    private let url: URL

    /// `url` is only for tests; the app uses its own Application Support folder.
    init(url: URL? = nil) {
        self.url = url ?? {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("contacts.json")
        }()
        if let d = try? Data(contentsOf: self.url), let c = try? JSONDecoder().decode([Contact].self, from: d) { contacts = c }
    }

    struct ImportSummary { var added = 0, updated = 0, kept = 0, skipped = 0, removed = 0 }

    /// Entries you typed in win over imported ones with the same address; an import only renames earlier imports.
    @discardableResult
    func merge(_ result: VCard.Result, account: UUID?, source: String = "link") -> ImportSummary {
        var s = ImportSummary(skipped: result.skipped)
        for e in result.entries {
            if let i = contacts.firstIndex(where: { $0.address.lowercased() == e.address.lowercased() }) {
                if contacts[i].imported {
                    if contacts[i].name != e.name { contacts[i].name = e.name; s.updated += 1 } else { s.kept += 1 }
                } else { s.kept += 1 }
            } else {
                contacts.append(Contact(name: e.name, address: e.address, accountID: account, imported: true, source: source))
                s.added += 1
            }
        }
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        return s
    }

    /// Makes the contacts from one synced directory match the directory exactly: new ones added, changed ones
    /// renamed, ones that left the directory removed. Contacts you typed in, or imported another way, are never touched.
    @discardableResult
    func replaceSource(_ tag: String, result: VCard.Result, account: UUID?) -> ImportSummary {
        var s = ImportSummary(skipped: result.skipped)
        let wanted = Dictionary(result.entries.map { ($0.address.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let before = contacts.count
        contacts.removeAll { $0.source == tag && wanted[$0.address.lowercased()] == nil }
        s.removed = before - contacts.count
        for (addr, e) in wanted {
            if let i = contacts.firstIndex(where: { $0.address.lowercased() == addr }) {
                if contacts[i].source == tag {
                    if contacts[i].name != e.name { contacts[i].name = e.name; s.updated += 1 } else { s.kept += 1 }
                } else { s.kept += 1 }          // someone else's entry wins; the directory doesn't overwrite it
            } else {
                contacts.append(Contact(name: e.name, address: e.address, accountID: account, imported: true, source: tag))
                s.added += 1
            }
        }
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        return s
    }

    /// Removes contacts that came from a vCard link (including ones saved before sources were tracked).
    @discardableResult
    func removeLinkImports() -> Int {
        let n = contacts.count
        contacts.removeAll { $0.imported && ($0.source == nil || $0.source == "link") }
        persist()
        return n - contacts.count
    }

    /// Removes every contact that came from one synced directory (when you delete the directory).
    func delete(source tag: String) { contacts.removeAll { $0.source == tag }; persist() }

    var hasLinkImports: Bool { contacts.contains { $0.imported && ($0.source == nil || $0.source == "link") } }

    func add(name: String, address: String, account: UUID?) -> Bool {
        guard let a = VCard.sipAddress("sip:" + address.replacingOccurrences(of: "sip:", with: "")) else { return false }
        contacts.append(Contact(name: name.isEmpty ? a : name, address: a, accountID: account))
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        return true
    }

    func remove(_ ids: [UUID]) { contacts.removeAll { ids.contains($0.id) }; persist() }
    func removeAll() { contacts = []; persist() }

    /// For caller display: match the user part (and domain when known).
    /// Finds who a call was with. Tries, in order: the same extension on the same server; the same extension on any server
    /// (when only one contact has it); a phone number that matches by its last ten digits (so +1 612… finds 612…).
    func name(forUser rawUser: String, domain rawDomain: String? = nil) -> String? {
        let user = rawUser.lowercased().replacingOccurrences(of: "sip:", with: "")
        let domain = rawDomain?.lowercased().split(separator: ":").first.map(String.init)
        func domainOf(_ c: Contact) -> String { c.address.split(separator: "@").dropFirst().first.map { String($0).lowercased() } ?? "" }

        if let exact = contacts.first(where: { $0.user.lowercased() == user && (domain == nil || domainOf($0) == domain) }) { return exact.name }
        let sameUser = contacts.filter { $0.user.lowercased() == user }
        if sameUser.count == 1 { return sameUser[0].name }

        let digits = user.filter(\.isNumber)
        if digits.count >= 7 {
            let tail = String(digits.suffix(10))
            let sameNumber = contacts.filter { let d = $0.user.filter(\.isNumber); return d.count >= 7 && String(d.suffix(10)) == tail }
            if sameNumber.count == 1 { return sameNumber[0].name }
        }
        return nil
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(contacts) { try? d.write(to: url, options: .atomic) }
    }

    /// One manual fetch. No background session, no retry loop.
    static func fetchVCard(from url: URL) async throws -> VCard.Result {
        guard url.scheme?.lowercased() == "https" else { throw Provisioning.Failure.notHTTPS }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let (data, resp) = try await URLSession(configuration: cfg).data(from: url)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw Provisioning.Failure.badStatus(h.statusCode) }
        return VCard.parse(String(decoding: data, as: UTF8.self))
    }
}
