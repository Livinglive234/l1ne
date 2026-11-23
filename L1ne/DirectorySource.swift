import Foundation

/// How often a directory is synced. Anything but "Manual only" runs only while L1ne is open (and opportunistically
/// in the background: iOS decides when, so it can be later than asked).
enum SyncInterval: String, Codable, CaseIterable, Identifiable {
    case manual, onOpen, min15, hourly, hours6, daily
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Manual only"
        case .onOpen: "Every time L1ne opens"
        case .min15: "Every 15 minutes"
        case .hourly: "Every hour"
        case .hours6: "Every 6 hours"
        case .daily: "Once a day"
        }
    }
    /// nil for manual / on open
    var seconds: TimeInterval? {
        switch self {
        case .min15: 900
        case .hourly: 3600
        case .hours6: 21600
        case .daily: 86400
        default: nil
        }
    }
}

struct DirectorySource: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case ldap, carddav, vcardLink }

    var id = UUID()
    var kind: Kind
    var name = ""
    var enabled = true
    var interval = SyncInterval.daily
    var accountID: UUID?            // the account whose domain completes bare extensions; the one that dials them
    var lastSync: Date?            // last successful sync
    var lastAttempt: Date?         // last try, successful or not: due times count from here
    var lastResult: String?

    // CardDAV
    var url = ""
    var username = ""

    // LDAP
    var host = ""
    var port = 636
    var security = LDAPSettings.Security.ldaps
    var bindDN = ""
    var baseDN = ""
    var filter = "(objectClass=person)"
    var nameAttr = "displayName"
    var sipAttr = "sipAddress"
    var phoneAttr = "telephoneNumber"
    var phoneAsExtension = false

    /// LDAP and CardDAV are directories; a vCard link is the simpler pull that a provisioning file can bring.
    var isDirectory: Bool { kind != .vcardLink }
    var title: String { name.isEmpty ? (kind == .ldap ? host : (URL(string: url)?.host ?? url)) : name }
    var tag: String { "dir:" + id.uuidString }

    init(kind: Kind) { self.kind = kind; if kind == .ldap { port = 636 } }
}

@MainActor
final class DirectoryStore: ObservableObject {
    static let shared = DirectoryStore()
    private let key = "directories.v1"
    @Published private(set) var sources: [DirectorySource] = []

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([DirectorySource].self, from: d) { sources = s }
    }

    var anyEnabled: Bool { sources.contains { $0.enabled } }
    /// A real directory (LDAP or CardDAV) is on. It replaces the vCard-link pull.
    var directoryEnabled: Bool { sources.contains { $0.enabled && $0.isDirectory } }

    func password(_ id: UUID) -> String { Keychain.get("dir." + id.uuidString) ?? "" }

    func save(_ s: DirectorySource, password: String?) {
        if let i = sources.firstIndex(where: { $0.id == s.id }) { sources[i] = s } else { sources.append(s) }
        if let password { Keychain.set(password, for: "dir." + s.id.uuidString) }
        persist()
    }

    func update(_ id: UUID, _ change: (inout DirectorySource) -> Void) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[i]); persist()
    }

    func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
        Keychain.delete("dir." + id.uuidString)
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: key) }
    }
}
