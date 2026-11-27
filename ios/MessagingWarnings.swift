import SwiftUI
import UIKit

/// Cases where a text probably won't arrive, so L1ne says so before it is sent.
@MainActor
enum MessagingWarnings {
    /// Another line in L1ne that is the recipient ("7002@pbx" when you text from 7001@pbx). Two lines on one device and
    /// server share a connection, so the server can't route a text from one to the other properly.
    static func ownLine(peer: String, from accountID: UUID) -> Account? {
        let p = peer.lowercased().replacingOccurrences(of: "sip:", with: "")
        return AccountStore.shared.accounts.first {
            $0.id != accountID && p == "\($0.username)@\($0.domain)".lowercased()
        }
    }

    /// Other SIP apps this phone has that could be signed in to the same line (iOS only tells us about the ones listed in
    /// LSApplicationQueriesSchemes). If the same line is registered there too, the server may deliver texts to that app.
    static var otherSIPApps: [String] {
        [("Linphone", "linphone"), ("Zoiper", "zoiper"), ("Groundwire", "groundwire")].compactMap { name, scheme in
            URL(string: "\(scheme)://").flatMap { UIApplication.shared.canOpenURL($0) } == true ? name : nil
        }
    }

    static let dismissKey = "msgwarn.otherapps.dismissed"
    static var otherAppsDismissed: Bool { UserDefaults.standard.bool(forKey: dismissKey) }
}

struct WarningBanner: View {
    let text: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(Theme.muted) }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.5)))
    }
}
