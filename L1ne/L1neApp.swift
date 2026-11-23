import SwiftUI

@main
struct L1neApp: App {
    @Environment(\.scenePhase) private var phase

    init() { DirectorySync.shared.registerBackground() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: DirectorySync.shared.appBecameActive()
            case .background: DirectorySync.shared.appWentToBackground()
            default: break
            }
        }
    }
}
