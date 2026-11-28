import Foundation

/// L1ne's own address book. It never reads the phone's Contacts, never fetches by itself,
/// and only holds entries that have a SIP address. Entries arrive by a manual import or are typed in.
struct Contact: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String           // user@domain
    var accountID: UUID?          // which account dials it; nil = the first account
    var imported = false
    var favorite: Bool?           // starred: listed first in Contacts
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
        upsert(result.entries, account: account, source: source, mayRename: { $0.imported }, into: &s)
        sortAndPersist()
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
        // someone else's entry wins; the directory doesn't overwrite it
        upsert(Array(wanted.values), account: account, source: tag, mayRename: { $0.source == tag }, into: &s)
        sortAndPersist()
        return s
    }

    /// For each entry: an existing contact with that address is renamed when `mayRename` allows it and counted as kept otherwise;
    /// a new address is added. Looked up through one dictionary, so a directory of thousands is not searched once per entry.
    private func upsert(_ entries: [VCard.Entry], account: UUID?, source: String, mayRename: (Contact) -> Bool, into s: inout ImportSummary) {
        var index: [String: Int] = [:]
        for (i, c) in contacts.enumerated() where index[c.address.lowercased()] == nil { index[c.address.lowercased()] = i }
        for e in entries {
            let key = e.address.lowercased()
            if let i = index[key] {
                if mayRename(contacts[i]), contacts[i].name != e.name { contacts[i].name = e.name; s.updated += 1 } else { s.kept += 1 }
            } else {
                contacts.append(Contact(name: e.name, address: e.address, accountID: account, imported: true, source: source))
                index[key] = contacts.count - 1
                s.added += 1
            }
        }
    }

    /// Stars or unstars the contact with this address; one that is not saved yet is saved first.
    func setFavorite(address: String, name: String, account: UUID?, _ on: Bool) {
        if !contacts.contains(where: { $0.address.lowercased() == address.lowercased() }) { _ = add(name: name, address: address, account: account) }
        for i in contacts.indices where contacts[i].address.lowercased() == address.lowercased() { contacts[i].favorite = on }
        persist()
    }

    private func sortAndPersist() {
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    /// Removes contacts that came from a vCard link (including ones saved before sources were tracked).
    @discardableResult
    func removeLinkImports() -> Int {
        let n = contacts.count
        contacts.removeAll { $0.imported && ($0.source == nil || $0.source == "link") }
        persist()
        return n - contacts.count
    }

    /// Removes the contacts that were imported for an account (from its vCard link or a directory), when the account is removed. Contacts you typed in stay.
    func removeImports(forAccount id: UUID) {
        contacts.removeAll { $0.accountID == id && $0.imported }
        persist()
    }

    /// Removes every contact that came from one synced directory (when you delete the directory).
    func delete(source tag: String) { contacts.removeAll { $0.source == tag }; persist() }

    var hasLinkImports: Bool { contacts.contains { $0.imported && ($0.source == nil || $0.source == "link") } }

    func add(name: String, address: String, account: UUID?) -> Bool {
        guard let a = VCard.sipAddress("sip:" + address.replacingOccurrences(of: "sip:", with: "")) else { return false }
        contacts.append(Contact(name: name.isEmpty ? a : name, address: a, accountID: account))
        sortAndPersist()
        return true
    }

    func remove(_ ids: [UUID]) { contacts.removeAll { ids.contains($0.id) }; persist() }
    func removeAll() { contacts = []; persist() }

    /// What to show for a "user@domain" peer: the contact's name, else the number nicely formatted.
    func displayName(forPeer peer: String) -> String {
        let parts = peer.split(separator: "@").map(String.init)
        let user = parts.first ?? peer
        return name(forUser: user, domain: parts.count == 2 ? parts[1] : nil) ?? PhoneFormat.pretty(user)
    }

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
        VCard.parse(String(decoding: try await Provisioning.httpsData(url), as: UTF8.self))
    }
}
