import Foundation

extension AccountStore {
    /// Takes an account out for good: its registration, its chats and call history on this phone, the contacts and directory sources it brought in
    /// (its vCard link, CardDAV or LDAP), and the account itself.
    /// The editor and the swipe in the Accounts list both end here, so they always do the same thing.
    @MainActor func removeCompletely(_ id: UUID, engine: SIPEngine) {
        engine.unregister(id)
        MessageStore.shared.removeAccount(id)
        CallLogStore.shared.removeAccount(id)
        let dirs = DirectoryStore.shared
        for s in dirs.sources where s.accountID == id { ContactsStore.shared.delete(source: s.tag); dirs.remove(s.id) }
        ContactsStore.shared.removeImports(forAccount: id)
        remove(id)
    }
}
