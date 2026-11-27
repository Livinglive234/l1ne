import SwiftUI
import Combine

/// The last stretch of SIP messages and engine notes, to look at, copy or share. Kept in memory only; it starts empty each time L1ne opens.
struct SipLogView: View {
    @State private var text = SipLog.shared.text(last: 400)
    @State private var entries = SipLog.shared.count
    @State private var sharing = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contains phone numbers and server names. Passwords and encryption keys are removed. \(entries) entries, kept only while L1ne is open.")
                .font(.footnote).foregroundStyle(Theme.muted).padding(.horizontal, 16).padding(.vertical, 8)
            if text.isEmpty {
                Text("Nothing yet. Make a call or sign in to an account, then come back.").foregroundStyle(Theme.muted).padding(16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: text) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .l1neBackground()
        .navigationTitle("SIP log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { UIPasteboard.general.string = SipLog.shared.text() } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy")
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share")
                Button { SipLog.shared.clear(); text = ""; entries = 0 } label: { Image(systemName: "trash") }.accessibilityLabel("Clear")
            }
        }
        .sheet(isPresented: $sharing) { ShareSheet(items: [SipLog.shared.text()]) }
        .onReceive(tick) { _ in text = SipLog.shared.text(last: 400); entries = SipLog.shared.count }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
