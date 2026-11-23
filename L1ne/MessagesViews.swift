import SwiftUI

@MainActor private func displayName(_ peer: String, contacts: ContactsStore) -> String {
    let p = peer.split(separator: "@").map(String.init)
    if p.count == 2, let n = contacts.name(forUser: p[0], domain: p[1]) { return n }
    return p.first ?? peer
}

struct ConversationsView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var messages: MessageStore
    @EnvironmentObject var router: AppRouter
    @State private var path: [ThreadTarget] = []
    @State private var composing = false

    private var list: some View {
        List {
            ForEach(messages.conversations) { c in
                NavigationLink(value: ThreadTarget(accountID: c.accountID, peer: c.peer)) {
                    HStack(spacing: 12) {
                        Circle().fill(c.unread > 0 ? Theme.brand : .clear).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(displayName(c.peer, contacts: contacts)).font(.headline).foregroundStyle(Theme.text)
                                Spacer()
                                if let d = c.last?.date { Text(d, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(Theme.muted) }
                            }
                            Text(c.last?.text ?? "").lineLimit(2).font(.subheadline).foregroundStyle(Theme.muted)
                            if store.accounts.count > 1, let a = store.account(c.accountID) {
                                Text("via \(a.title)").font(.caption).foregroundStyle(Theme.muted.opacity(0.8))
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .onDelete { idx in messages.delete(idx.map { messages.conversations[$0].id }) }
        }
        .scrollDisabled(messages.conversations.isEmpty)      // nothing to scroll when there are no conversations
        .overlay {
            if messages.conversations.isEmpty {
                ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Texts need a server that supports SIP messages."))
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
            .mainBackground()
            .navigationTitle("Conversations")
            .navigationDestination(for: ThreadTarget.self) { ThreadView(target: $0) }
            .task(id: router.pendingThread) {
                if let t = router.pendingThread { path = [t]; router.pendingThread = nil }
            }
            .toolbar {
                ProfileToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(store.accounts.isEmpty)
                }
            }
            .sheet(isPresented: $composing) {
                NewMessageSheet { path = [$0] }
            }
        }
    }
}

struct ThreadView: View {
    let target: ThreadTarget
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var messages: MessageStore
    @State private var draft = ""
    @State private var info: PersonTarget?
    @State private var otherAppsDismissed = MessagingWarnings.otherAppsDismissed

    private var line: Account? { store.account(target.accountID) }
    private var person: PersonTarget { PersonTarget(name: displayName(target.peer, contacts: contacts), address: target.peer, accountID: target.accountID) }

    private var conversation: Conversation? { messages.conversation(target) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if let note = engine.messagingNote[target.accountID] {
                        Text(note).font(.footnote).multilineTextAlignment(.center).foregroundStyle(Theme.danger)
                            .padding(10).frame(maxWidth: .infinity).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 8)
                    }
                    if engine.messagingCheck[target.accountID] == .notDelivered, engine.messagingNote[target.accountID] == nil {
                        WarningBanner(text: "This server took a test text but didn't deliver it back to you, so messages from this line probably won't arrive. The server may need texting switched on.")
                            .padding(.bottom, 4)
                    }
                    if let other = MessagingWarnings.ownLine(peer: target.peer, from: target.accountID) {
                        WarningBanner(text: "\(other.title) is another line in L1ne. Texts between two lines in the same app, on the same server, usually don't arrive. Use a different phone or app for the other line.")
                            .padding(.bottom, 4)
                    }
                    let apps = MessagingWarnings.otherSIPApps
                    if !apps.isEmpty && !otherAppsDismissed {
                        WarningBanner(text: "\(apps.joined(separator: " and ")) is installed on this phone. If this line is also signed in there, texts can land in that app instead of L1ne. Sign this line out of it.") {
                            otherAppsDismissed = true
                            UserDefaults.standard.set(true, forKey: MessagingWarnings.dismissKey)
                        }
                        .padding(.bottom, 4)
                    }
                    ForEach(conversation?.messages ?? []) { m in
                        Bubble(message: m) { engine.sendMessage(m.text, to: target, retrying: m.id) }
                            .id(m.id)
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = m.text }
                                Button("Delete", systemImage: "trash", role: .destructive) { messages.remove(messageID: m.id) }
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation?.messages.count) { _, _ in
                if let id = conversation?.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                messages.markRead(target)
            }
        }
        .mainBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $info) { ContactDetailView(person: $0) }
        .toolbar {
            // name on top, the line you are texting from underneath; tapping opens the contact page
            ToolbarItem(placement: .principal) {
                Button { info = person } label: {
                    VStack(spacing: 1) {
                        Text(person.name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                        if store.accounts.count > 1 {
                            Text("from \(line?.title ?? "—")").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }.buttonStyle(.plain)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { info = person } label: { Image(systemName: "info.circle") }
                Button {
                    if let a = line ?? store.selected { engine.call(target.peer.contains("@") ? "sip:" + target.peer : target.peer, from: a.id) }
                } label: { Image(systemName: "phone.fill") }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .onAppear { messages.markRead(target) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border))
            Button {
                if engine.sendMessage(draft, to: target) || !draft.trimmingCharacters(in: .whitespaces).isEmpty { draft = "" }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.brandDim.opacity(0.5) : Theme.brand)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.bg)
    }
}

private struct Bubble: View {
    let message: Message
    var retry: () -> Void

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
            Text(message.text)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .foregroundStyle(message.outgoing ? Theme.onBrand : Theme.text)
                .background(message.outgoing ? Theme.brand : Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                .opacity(message.status == .sending ? 0.6 : 1)
            if message.status == .failed {
                Button(action: retry) {
                    Label(message.failure ?? "Not delivered", systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.danger)
                }
                Text("Tap to try again").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
    }
}

struct NewMessageSheet: View {
    var open: (ThreadTarget) -> Void
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var accountID: UUID?

    private var account: Account? { accountID.flatMap { store.account($0) } ?? store.selected }

    var body: some View {
        NavigationStack {
            List {
                if store.accounts.count > 1 {
                    Picker("From", selection: Binding(get: { account?.id ?? UUID() }, set: { accountID = $0 })) {
                        ForEach(store.accounts) { Text($0.title).tag($0.id) }
                    }
                    .listRowBackground(Theme.surface)
                }
                Section {
                    TextField("Extension or user@domain", text: $typed)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    Button("Start") { start(typed) }.disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if let a = account, engine.messagingCheck[a.id] == .notDelivered {
                        Label("This server doesn't seem to deliver texts: a test text to this line didn't come back.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if let a = account, let other = MessagingWarnings.ownLine(peer: normalized(typed, account: a), from: a.id) {
                        Label("\(other.title) is another line in L1ne. Texts between two lines in the same app usually don't arrive.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Theme.surface)
                if !contacts.contacts.isEmpty {
                    Section("Contacts") {
                        ForEach(contacts.contacts) { c in
                            Button { start(c.address) } label: {
                                VStack(alignment: .leading) {
                                    Text(c.name).foregroundStyle(Theme.text)
                                    Text(c.address).font(.footnote).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .l1neBackground()
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    /// A bare extension ("7201") gets the account's domain.
    private func normalized(_ text: String, account a: Account) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : (t.contains("@") ? t : "\(t)@\(a.domain)")
    }

    private func start(_ text: String) {
        guard let a = account else { return }
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let addr = VCard.sipAddress("sip:" + (t.contains("@") ? t : "\(t)@\(a.domain)")) else { return }
        dismiss()
        open(ThreadTarget(accountID: a.id, peer: addr))
    }
}
