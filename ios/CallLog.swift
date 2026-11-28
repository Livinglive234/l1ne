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

extension CallRecord {
    /// "Today | 12:37 PM", "Yesterday | 9:10 PM", "11/13 | 10:41 AM": the day and the time of the call.
    var whenText: String {
        let cal = Calendar.current
        let day = cal.isDateInToday(date) ? "Today" : cal.isDateInYesterday(date) ? "Yesterday" : date.formatted(.dateTime.month(.defaultDigits).day())
        return "\(day) | \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// How the call was encrypted, in words. SRTP and DTLS-SRTP protect the audio between the phone and the PBX (point to point); ZRTP between the two phones (end to end).
    var securityDescription: String? {
        switch security {
        case "zrtp": return "Encrypted end to end (ZRTP)"
        case "zrtp-verified": return "Encrypted end to end (ZRTP), code verified"
        case "srtp": return "Encrypted point to point (SRTP)"
        case "dtls": return "Encrypted point to point (DTLS-SRTP)"
        default: return nil
        }
    }

    /// Whether this call was with the same person as `address`: the same extension or number on the same server (a missing server matches any).
    func isWith(_ address: String) -> Bool {
        func parts(_ x: String) -> (String, String) {
            let t = x.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "sips:", with: "").replacingOccurrences(of: "sip:", with: "")
            let p = t.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return (p.first ?? "", p.count > 1 ? p[1] : "")
        }
        let (u1, d1) = parts(peer), (u2, d2) = parts(address)
        let g1 = u1.filter(\.isNumber), g2 = u2.filter(\.isNumber)
        let sameUser = u1 == u2 || (!g1.isEmpty && g1 == g2) || (g1.count >= 10 && g2.count >= 10 && g1.suffix(10) == g2.suffix(10))
        return sameUser && (d1.isEmpty || d2.isEmpty || d1 == d2)
    }
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
