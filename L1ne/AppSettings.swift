import Foundation

/// App-wide settings (not tied to one account). Stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var autoRecord: Bool { didSet { d.set(autoRecord, forKey: "set.autoRecord") } }
    @Published var acceptEarlyMedia: Bool { didSet { d.set(acceptEarlyMedia, forKey: "set.acceptEarlyMedia") } }
    @Published var allowOutgoingEarlyMedia: Bool { didSet { d.set(allowOutgoingEarlyMedia, forKey: "set.outEarlyMedia") } }
    @Published var wifiOnly: Bool { didSet { d.set(wifiOnly, forKey: "set.wifiOnly") } }
    @Published var allowIPv6: Bool { didSet { d.set(allowIPv6, forKey: "set.allowIPv6") } }
    @Published var provisioningURL: String { didSet { d.set(provisioningURL, forKey: "set.provisioningURL") } }
    /// Codec ids ("PCMU/8000/1") in the order you want them offered, and the ones switched off.
    @Published var codecOrder: [String] { didSet { d.set(codecOrder, forKey: "set.codecOrder") } }
    @Published var codecsOff: [String] { didSet { d.set(codecsOff, forKey: "set.codecsOff") } }

    init() {
        autoRecord = d.bool(forKey: "set.autoRecord")
        acceptEarlyMedia = d.bool(forKey: "set.acceptEarlyMedia")
        allowOutgoingEarlyMedia = d.bool(forKey: "set.outEarlyMedia")
        wifiOnly = d.bool(forKey: "set.wifiOnly")
        allowIPv6 = d.object(forKey: "set.allowIPv6") as? Bool ?? true
        provisioningURL = d.string(forKey: "set.provisioningURL") ?? ""
        codecOrder = d.stringArray(forKey: "set.codecOrder") ?? []
        codecsOff = d.stringArray(forKey: "set.codecsOff") ?? []
    }
}
