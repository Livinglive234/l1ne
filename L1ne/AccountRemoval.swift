import Foundation

extension AccountStore {
    /// Takes an account out for good: its registration, its chats and call history on this phone, and the account itself.
    /// The editor and the swipe in the Accounts list both end here, so they always do the same thing.
    @MainActor func removeCompletely(_ id: UUID, engine: SIPEngine) {
        engine.unregister(id)
        MessageStore.shared.removeAccount(id)
        CallLogStore.shared.removeAccount(id)
        remove(id)
    }
}
