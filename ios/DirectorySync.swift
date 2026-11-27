import Foundation
import BackgroundTasks

/// Runs directory syncs: on demand, on a timer while L1ne is open, and (when iOS allows) in the background.
/// A synced directory replaces the vCard-link import (see DirectoryViews).
@MainActor
final class DirectorySync: ObservableObject {
    static let shared = DirectorySync()
    static let taskID = "com.livenet.l1ne.directorysync"

    @Published private(set) var running: Set<UUID> = []
    private var loop: Task<Void, Never>?

    // MARK: fetching

    func fetch(_ s: DirectorySource, password: String) async throws -> VCard.Result {
        switch s.kind {
        case .vcardLink, .carddav:
            guard let url = URL(string: s.url.trimmingCharacters(in: .whitespaces)) else { throw CardDAV.Failure.badURL }
            return s.kind == .carddav ? try await CardDAV.fetch(url: url, username: s.username, password: password)
                                      : try await ContactsStore.fetchVCard(from: url)
        case .ldap:
            let domain = s.accountID.flatMap { AccountStore.shared.account($0)?.domain } ?? AccountStore.shared.selected?.domain ?? ""
            var attrs = ["cn", "displayName", "givenName", "sn", s.nameAttr, s.sipAttr]
            if s.phoneAsExtension { attrs.append(s.phoneAttr) }
            let settings = LDAPSettings(host: s.host, port: s.port, security: s.security, bindDN: s.bindDN, password: password,
                                        baseDN: s.baseDN, filter: s.filter, attributes: Array(Set(attrs)))
            let entries = try await LDAPClient.search(settings)
            return DirectoryMapping.ldap(entries, nameAttr: s.nameAttr, sipAttr: s.sipAttr, phoneAttr: s.phoneAttr,
                                         phoneAsExtension: s.phoneAsExtension, domain: domain)
        }
    }

    /// A connection test: fetches and counts, but changes no contacts.
    func test(_ s: DirectorySource, password: String) async -> String {
        do {
            let r = try await fetch(s, password: password)
            return "Works: found \(r.entries.count) with a SIP address, \(r.skipped) without."
        } catch { return "Failed: \(error.localizedDescription)" }
    }

    // MARK: syncing

    @discardableResult
    func sync(_ id: UUID) async -> String {
        let dirs = DirectoryStore.shared
        guard let s = dirs.sources.first(where: { $0.id == id }), !running.contains(id) else { return "" }
        running.insert(id)
        defer { running.remove(id) }
        dirs.update(id) { $0.lastAttempt = Date() }
        let result: String
        do {
            let r = try await fetch(s, password: dirs.password(id))
            let sum = ContactsStore.shared.replaceSource(s.tag, result: r, account: s.accountID ?? AccountStore.shared.selected?.id)
            result = "\(sum.added) added, \(sum.updated) updated, \(sum.removed) removed"
                + (sum.skipped > 0 ? "; \(sum.skipped) had no SIP address" : "")
            dirs.update(id) { $0.lastSync = Date(); $0.lastResult = result }
        } catch {
            result = "Failed: \(error.localizedDescription)"
            dirs.update(id) { $0.lastResult = result }
        }
        return result
    }

    func isDue(_ s: DirectorySource, onOpen: Bool) -> Bool {
        guard s.enabled, !running.contains(s.id) else { return false }
        switch s.interval {
        case .manual: return false
        case .onOpen: return onOpen
        default: return Date().timeIntervalSince(s.lastAttempt ?? .distantPast) >= (s.interval.seconds ?? .infinity)
        }
    }

    func syncDue(onOpen: Bool = false) async {
        for s in DirectoryStore.shared.sources where isDue(s, onOpen: onOpen) { await sync(s.id) }
    }

    // MARK: while the app is open

    func appBecameActive() {
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.syncDue(onOpen: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.syncDue()
            }
        }
    }

    func appWentToBackground() {
        loop?.cancel(); loop = nil
        scheduleBackground()
    }

    // MARK: background refresh (iOS picks the actual time, usually later than asked)

    nonisolated func registerBackground() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: DirectorySync.taskID, using: nil) { task in
            let work = Task { @MainActor in
                await DirectorySync.shared.syncDue()
                DirectorySync.shared.scheduleBackground()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackground() {
        let wanted = DirectoryStore.shared.sources.filter { $0.enabled }.compactMap { $0.interval.seconds }.min()
        guard let interval = wanted else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID); return }
        let req = BGAppRefreshTaskRequest(identifier: Self.taskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: max(900, interval))
        try? BGTaskScheduler.shared.submit(req)
    }
}
