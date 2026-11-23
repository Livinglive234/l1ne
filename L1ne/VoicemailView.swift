import SwiftUI

/// The optional Voicemail tab: one row per account with a voicemail number, its new-message count (from the
/// message-waiting indicator) and a button that dials the mailbox.
struct VoicemailView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore

    private var accounts: [Account] { store.accounts.filter { $0.voicemailTarget != nil } }

    var body: some View {
        NavigationStack {
            List(accounts) { a in
                Button { engine.callVoicemail(a.id) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "recordingtape").font(.title3).foregroundStyle(Theme.brand)
                            .frame(width: 42, height: 42).background(Theme.brand.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accounts.count > 1 ? a.title : "Voicemail").font(.body.weight(.medium)).foregroundStyle(Theme.text)
                            let n = engine.voicemail[a.id] ?? 0
                            Text(n > 0 ? "\(n) new message\(n == 1 ? "" : "s")" : "No new messages")
                                .font(.footnote).foregroundStyle(n > 0 ? Theme.brand : Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "phone.fill").font(.footnote).foregroundStyle(Theme.brand)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.border)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay { if accounts.isEmpty { ContentUnavailableView("No voicemail", systemImage: "recordingtape", description: Text("Add an account to check its voicemail.")) } }
            .mainBackground()
            .navigationTitle("Voicemail")
            .toolbar { ProfileToolbar() }
        }
    }
}

/// LATER (skeleton): tell the user when a new voicemail arrives. A notification while the app is closed needs push
/// (docs/ROADMAP.md, "push to the app for any server"). Until then this does nothing; the badge on the Voicemail tab
/// and the count on the keypad button are the only signals, and only while the app is running.
enum VoicemailNotifier {
    @MainActor static func newVoicemail(account: UUID, count: Int) {
        // Not implemented yet. Planned: if AppSettings.shared.voicemailNotify, post a local notification now (app
        // running) and, once the push gateway exists, from the gateway when the app is closed.
    }
}
