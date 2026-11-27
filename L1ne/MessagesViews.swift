import SwiftUI

struct ConversationsView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var messages: MessageStore
    @EnvironmentObject var router: AppRouter
    @State private var selected: ThreadTarget?
    @State private var composing = false
    @Environment(\.horizontalSizeClass) private var hSize
    private var wide: Bool { hSize == .regular }       // an iPad, or the iPhone Duo opened: the list on the left, the conversation on the right

    private func target(_ c: Conversation) -> ThreadTarget { ThreadTarget(accountID: c.accountID, peer: c.peer) }

    @ViewBuilder private func row(_ c: Conversation) -> some View {
        if wide {
            Button { selected = target(c) } label: { rowContent(c) }.buttonStyle(.plain)
                .listRowBackground(selected == target(c) ? Theme.brand.opacity(0.14) : Theme.surface)
        } else {
            Button { selected = target(c) } label: {
                HStack { rowContent(c); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted.opacity(0.6)) }
            }.buttonStyle(.plain)
                .listRowBackground(Theme.surface)
        }
    }

    private func rowContent(_ c: Conversation) -> some View {
        HStack(spacing: 12) {
            Circle().fill(c.unread > 0 ? Theme.brand : .clear).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(contacts.displayName(forPeer: c.peer)).font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if let d = c.last?.date { Text(d, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(Theme.muted) }
                }
                Text(c.last?.text ?? "").lineLimit(2).font(.subheadline).foregroundStyle(Theme.muted)
                if store.accounts.count > 1, let a = store.account(c.accountID) {
                    Text("via \(a.titleWithUser)").font(.caption).foregroundStyle(Theme.muted.opacity(0.8))
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(messages.conversations) { c in row(c) }
            .onDelete { idx in messages.delete(idx.map { messages.conversations[$0].id }) }
        }
        .scrollDisabledCompat(messages.conversations.isEmpty)      // nothing to scroll when there are no conversations
        .overlay {
            if messages.conversations.isEmpty {
                EmptyState("No chats", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Texts need a server that supports SIP messages."))
            }
        }
    }

    var body: some View {
        if wide {
            HStack(spacing: 0) {
                listStack.frame(width: 380)
                Divider()
                Group {
                    if let t = selected {
                        AppNavStack { ThreadView(target: t).id(t) }
                    } else {
                        EmptyState("No chat selected", systemImage: "bubble.left.and.bubble.right", description: Text("Pick one on the left, or start a new message."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity).mainBackground()
                    }
                }
            }
        } else { listStack }
    }

    private var listStack: some View {
        AppNavStack {
            list
            .navDestination(item: wide ? .constant(nil) : $selected) { ThreadView(target: $0) }       // a chat can be opened before it has a row (a new one, or from a contact)
            .mainBackground()
            .navigationTitle("Chats")
            .task(id: router.pendingThread) {
                if let t = router.pendingThread { selected = t; router.pendingThread = nil }
            }
            .profileToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message")
                        .disabled(store.accounts.isEmpty)
                }
            }
            .sheet(isPresented: $composing) {
                NewMessageSheet { selected = $0 }
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
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var draft = ""
    @State private var info: PersonTarget?
    @State private var otherAppsDismissed = MessagingWarnings.otherAppsDismissed

    private var line: Account? { store.account(target.accountID) }
    private var person: PersonTarget { PersonTarget(name: contacts.displayName(forPeer: target.peer), address: target.peer, accountID: target.accountID) }

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
            .startAtBottom()
            .onChangeCompat(of: conversation?.messages.count) { _, _ in
                if let id = conversation?.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                messages.markRead(target)
            }
        }
        .mainBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navDestination(item: $info) { ContactDetailView(person: $0) }
        .toolbar {
            // name on top, the line you are texting from underneath; tapping opens the contact page
            ToolbarItem(placement: .principal) {
                if hSize != .regular { nameButton }       // beside the list the iPad's top tab bar sits in the middle, so the name goes in a header instead
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { info = person } label: { Image(systemName: "info.circle") }
                Button {
                    if let a = line ?? store.selected { engine.call(target.peer, from: a.id) }
                } label: { Image(systemName: "phone.fill") }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .safeAreaInset(edge: .top, spacing: 0) {
            if hSize == .regular {
                HStack { Spacer(); nameButton; Spacer() }.padding(.horizontal, 16).padding(.vertical, 8).background(Theme.bg)
            }
        }
        .onAppear { messages.markRead(target) }
    }

    /// Name on top, the line you are texting from underneath; tapping opens the contact page.
    private var nameButton: some View {
        Button { info = person } label: {
            VStack(alignment: .center, spacing: 1) {
                Text(person.name).font(hSize == .regular ? .title2 : .headline).fontWeight(hSize == .regular ? .heavy : .semibold).foregroundStyle(Theme.text).lineLimit(1)
                if store.accounts.count > 1 {
                    Text("from \(line?.title ?? "—")").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }.buttonStyle(.plain)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            MessageField(text: $draft)
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

    private var account: Account? { store.dialAccount(accountID) }

    var body: some View {
        AppNavStack {
            List {
                if store.accounts.count > 1 {
                    Picker("From", selection: Binding(get: { account?.id ?? UUID() }, set: { accountID = $0 })) {
                        ForEach(store.accounts) { Text($0.title).tag($0.id) }
                    }
                    .listRowBackground(Theme.surface)
                }
                Section {
                    TextField("Extension or user@domain", text: $typed)
                        .plainInput(.emailAddress)
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
