import Foundation

/// Which tab is showing, whether the call screen is minimised, and where to jump from inside a call.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Tab: Hashable { case recents, contacts, conversations, voicemail, keypad }

    @Published var tab = Tab.recents
    @Published var callMinimized = false
    /// Set by the call screen's Messages button; the Conversations tab opens this thread.
    @Published var pendingThread: ThreadTarget?
    /// A sip: link opened from another app: the Keypad tab shows it, ready to call. (Never dials by itself: a web page shouldn't be able to place a call.)
    @Published var pendingDial: String?

    /// "sip:7001@pbx.example.com;transport=tls" -> "7001" when that is one of your servers, else "7001@pbx.example.com".
    static func dialTarget(fromSIP url: URL) -> String? {
        var t = url.absoluteString
        for scheme in ["sips:", "sip:"] where t.lowercased().hasPrefix(scheme) { t.removeFirst(scheme.count); break }
        t = t.removingPercentEncoding ?? t
        if let i = t.firstIndex(where: { $0 == ";" || $0 == "?" }) { t = String(t[..<i]) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2, AccountStore.shared.accounts.contains(where: { $0.domain.lowercased() == parts[1].lowercased().split(separator: ":").first.map(String.init) }) { return parts[0] }
        return t
    }
}
