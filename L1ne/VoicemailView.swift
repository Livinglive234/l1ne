import SwiftUI

/// The optional Voicemail tab: one row per account with a voicemail number, its new-message count (from the
/// message-waiting indicator) and a button that dials the mailbox.
struct VoicemailView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore

    @Environment(\.horizontalSizeClass) private var hSize
    private var accounts: [Account] { store.accounts.filter { $0.voicemailTarget != nil } }

    var body: some View {
        AppNavStack {
            List(accounts) { a in
                HStack(spacing: 14) {
                    Image(systemName: "recordingtape").font(.title3).foregroundStyle(Theme.brand)
                        .frame(width: 48, height: 48).background(Theme.brand.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accounts.count > 1 ? a.title : "Voicemail").font(.body.weight(.medium)).foregroundStyle(Theme.text)
                        let n = engine.voicemail[a.id] ?? 0
                        Text(n > 0 ? "\(n) new message\(n == 1 ? "" : "s")" : "No new messages")
                            .font(.footnote).foregroundStyle(n > 0 ? Theme.brand : Theme.muted)
                    }
                    Spacer(minLength: 8)
                    CallCircleButton { engine.callVoicemail(a.id) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.border)
            }
            .listStyle(.plain).hideScrollBackground()
            .frame(maxWidth: hSize == .regular ? 640 : .infinity)       // nothing to show beside it, so on a wide screen the list keeps a readable width
            .frame(maxWidth: .infinity)
            .overlay { if accounts.isEmpty { EmptyState("No voicemail", systemImage: "recordingtape", description: Text("Add an account to check its voicemail.")) } }
            .mainBackground()
            .navigationTitle("Voicemail")
            .profileToolbar()
        }
    }
}
