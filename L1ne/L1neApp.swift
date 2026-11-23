import SwiftUI

@main
struct L1neApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var settings = AppSettings.shared

    init() { DirectorySync.shared.registerBackground() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(settings.appearance.scheme)
                // calling back from the Phone app's Recents
                .onContinueUserActivity("INStartCallIntent") { PhoneAppCallBack.handle($0) }
                .onContinueUserActivity("INStartAudioCallIntent") { PhoneAppCallBack.handle($0) }
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
