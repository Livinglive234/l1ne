import Foundation

struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case outgoing, incoming, missed }
    var id = UUID()
    var date = Date()
    var peer: String              // user@domain, or what was dialled
    var accountID: UUID?
    var direction: Direction
    var duration: Int             // seconds connected
    var security: String?         // how the call was encrypted: "srtp", "dtls", "zrtp", or "zrtp-verified" (the code was compared with this person); nil when not or unknown
    var callerName: String?       // the name the caller sent (caller ID), kept so the history shows it with the number underneath
}

/// Call history, kept only on this phone.
@MainActor
final class CallLogStore: ObservableObject {
    static let shared = CallLogStore()
    @Published private(set) var records: [CallRecord] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("calllog.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([CallRecord].self, from: d) { records = r }
    }

    func add(_ r: CallRecord) {
        records.insert(r, at: 0)
        if records.count > 500 { records.removeLast(records.count - 500) }
        save()
    }
    func delete(_ ids: [UUID]) { records.removeAll { ids.contains($0.id) }; save() }
    func removeAll() { records = []; save() }
    func removeAccount(_ id: UUID) { records.removeAll { $0.accountID == id }; save() }

    private func save() {
        guard let d = try? JSONEncoder().encode(records) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
