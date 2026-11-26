import Foundation

/// Text messages (SIP MESSAGE). Stored only on this phone, per account and peer.
struct Message: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case sending, sent, failed }
    var id = UUID()
    var date = Date()
    var outgoing: Bool
    var text: String
    var status = Status.sent
    var failure: String?          // why a send failed, shown under the bubble
    var read = true
}

struct Conversation: Codable, Identifiable, Equatable {
    var accountID: UUID
    var peer: String              // user@domain
    var messages: [Message] = []

    var id: String { Conversation.key(accountID, peer) }
    var last: Message? { messages.last }
    var unread: Int { messages.filter { !$0.read }.count }
    var user: String { String(peer.split(separator: "@").first ?? "") }

    static func key(_ account: UUID, _ peer: String) -> String { account.uuidString + "|" + peer.lowercased() }
}

/// Where to open a thread, whether or not it has messages yet.
struct ThreadTarget: Hashable, Identifiable {
    var accountID: UUID
    var peer: String
    var id: String { Conversation.key(accountID, peer) }
}

@MainActor
final class MessageStore: ObservableObject {
    static let shared = MessageStore()
    @Published private(set) var conversations: [Conversation] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messages.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode([Conversation].self, from: d) { conversations = c }
    }

    var unread: Int { conversations.reduce(0) { $0 + $1.unread } }

    func conversation(_ t: ThreadTarget) -> Conversation? {
        conversations.first { $0.id == Conversation.key(t.accountID, t.peer) }
    }

    /// Adds a message, creating the conversation if needed. Returns the message id.
    @discardableResult
    func add(_ m: Message, to t: ThreadTarget) -> UUID {
        let key = Conversation.key(t.accountID, t.peer)
        if let i = conversations.firstIndex(where: { $0.id == key }) {
            conversations[i].messages.append(m)
        } else {
            conversations.append(Conversation(accountID: t.accountID, peer: t.peer.lowercased(), messages: [m]))
        }
        sortAndSave()
        return m.id
    }

    func update(_ id: UUID, status: Message.Status, failure: String? = nil) {
        for c in conversations.indices {
            if let m = conversations[c].messages.firstIndex(where: { $0.id == id }) {
                conversations[c].messages[m].status = status
                conversations[c].messages[m].failure = failure
                save(); return
            }
        }
    }

    func remove(messageID id: UUID) {
        for c in conversations.indices { conversations[c].messages.removeAll { $0.id == id } }
        conversations.removeAll { $0.messages.isEmpty }
        save()
    }

    func markRead(_ t: ThreadTarget) {
        guard let i = conversations.firstIndex(where: { $0.id == Conversation.key(t.accountID, t.peer) }),
              conversations[i].unread > 0 else { return }
        for m in conversations[i].messages.indices { conversations[i].messages[m].read = true }
        save()
    }

    func delete(_ ids: [String]) { conversations.removeAll { ids.contains($0.id) }; save() }
    func removeAll() { conversations = []; save() }
    func removeAccount(_ id: UUID) { conversations.removeAll { $0.accountID == id }; save() }

    private func sortAndSave() {
        conversations.sort { ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast) }
        save()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(conversations) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
