#if DEBUG
import Foundation

/// Debug builds only. When the screen tests launch the app with `L1NE_UITEST_SEED=1`, it starts from a known state: one account that is
/// switched off (so nothing touches the network), a few contacts, a chat and some calls. Release builds do not contain this.
enum UITestSeed {
    static var requested: Bool { ProcessInfo.processInfo.environment["L1NE_UITEST_SEED"] == "1" }

    @MainActor static func apply() {
        let accounts = AccountStore.shared
        for a in accounts.accounts { accounts.remove(a.id) }
        ContactsStore.shared.removeAll(); MessageStore.shared.removeAll(); CallLogStore.shared.removeAll()

        var a = Account(); a.label = "Screen test"; a.domain = "pbx.test"; a.username = "7100"; a.enabled = false
        accounts.save(a, secret: "x")
        _ = ContactsStore.shared.add(name: "Alice Archer", address: "alice@pbx.test", account: a.id)
        _ = ContactsStore.shared.add(name: "Bob Brandt", address: "bob@pbx.test", account: a.id)
        _ = MessageStore.shared.add(Message(outgoing: false, text: "Are we still on for lunch?"), to: ThreadTarget(accountID: a.id, peer: "alice@pbx.test"))
        CallLogStore.shared.add(CallRecord(peer: "alice@pbx.test", accountID: a.id, direction: .incoming, duration: 120))
    }
}
#endif
