import Foundation
import Intents

/// Tapping a call in the iPhone Phone app's Recents (or the green call button in a contact) opens L1ne with a "start call"
/// request. This places that call on the right line, waiting for the account to register if the app was just launched.
@MainActor
enum PhoneAppCallBack {
    static let activityTypes = ["INStartCallIntent", "INStartAudioCallIntent"]

    static func handle(_ activity: NSUserActivity) {
        let intent = activity.interaction?.intent
        let value = (intent as? INStartCallIntent)?.contacts?.first?.personHandle?.value
            ?? (intent as? INStartAudioCallIntent)?.contacts?.first?.personHandle?.value
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return }
        place(raw)
    }

    /// `raw` is what L1ne gave CallKit as the handle: "7001@pbx.example.com", or a number.
    static func place(_ raw: String) {
        let address = raw.lowercased().hasPrefix("sip:") ? String(raw.dropFirst(4)) : raw
        let store = AccountStore.shared
        // the line whose server the address is on; otherwise the selected line
        let domain = address.split(separator: "@").dropFirst().first.map { String($0).lowercased() }
        let account = domain.flatMap { d in store.accounts.first { $0.domain.lowercased() == d } } ?? store.selected
        guard let account else { return }
        let target = address.contains("@") ? "sip:" + address : address
        Task { @MainActor in
            // just launched: give the account a moment to register before dialling
            for _ in 0..<24 where SIPEngine.shared.registration[account.id] != "Registered" {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            SIPEngine.shared.call(target, from: account.id)
        }
    }
}
