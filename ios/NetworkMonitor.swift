import Foundation
import Network

/// Tells the app whether it is on Wi-Fi (or wired) rather than cellular, for the "Use only Wi-Fi networks" setting.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var onWiFi = true
    private(set) var online = true
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && !path.usesInterfaceType(.cellular)
            let online = path.status == .satisfied
            Task { @MainActor in
                let m = NetworkMonitor.shared
                let changed = m.onWiFi != wifi || m.online != online
                m.onWiFi = wifi; m.online = online
                if changed { m.onChange?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "l1ne.network"))
    }
}
