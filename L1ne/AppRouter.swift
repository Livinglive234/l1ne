import Foundation

/// Which tab is showing, whether the call screen is minimised, and where to jump from inside a call.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Tab: Hashable { case recents, contacts, conversations, keypad }

    @Published var tab = Tab.recents
    @Published var callMinimized = false
    /// Set by the call screen's Messages button; the Conversations tab opens this thread.
    @Published var pendingThread: ThreadTarget?
}
