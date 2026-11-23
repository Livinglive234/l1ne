import SwiftUI

struct RootView: View {
    @StateObject private var engine = SIPEngine.shared
    @StateObject private var store = AccountStore.shared
    @StateObject private var contacts = ContactsStore.shared
    @StateObject private var messages = MessageStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var dirs = DirectoryStore.shared
    @StateObject private var callLog = CallLogStore.shared
    @State private var setupLink: SetupLink?

    struct SetupLink: Identifiable { let id = UUID(); let text: String }

    var body: some View {
        TabView {
            RecentsView()
                .tabItem { Label("Recents", systemImage: "clock") }
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2") }
            ConversationsView()
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
                .badge(messages.unread)
            KeypadView()
                .tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
        }
        .tint(Theme.brand)
        .environmentObject(engine)
        .environmentObject(store)
        .environmentObject(contacts)
        .environmentObject(messages)
        .environmentObject(settings)
        .environmentObject(dirs)
        .environmentObject(callLog)
        .onOpenURL { setupLink = SetupLink(text: $0.absoluteString) }
        .sheet(item: $setupLink) {
            ProvisionSheet(initialLink: $0.text).environmentObject(engine).environmentObject(store).environmentObject(contacts).environmentObject(dirs)
        }
        .task {
            engine.start()
            for a in store.accounts { engine.register(a, secret: store.secret(a.id)) }
            #if DEBUG
            // tests/mock: place a call a few seconds after launch
            if let n = ProcessInfo.processInfo.environment["L1NE_AUTODIAL"], let a = store.selected {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                engine.call(n, from: a.id)
            }
            #endif
        }
        .fullScreenCover(isPresented: .constant(!engine.calls.isEmpty)) {
            CallScreen().environmentObject(engine).environmentObject(store).environmentObject(contacts)
        }
    }
}

// MARK: Keypad

struct KeypadView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @State private var number = ""
    private let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["*","0","#"]]

    private var account: Account? { store.selected }

    var body: some View {
        NavigationStack {
        VStack(spacing: 24) {
            if store.accounts.count > 1 {
                Picker("Account", selection: Binding(get: { store.selected?.id ?? store.accounts[0].id }, set: { store.select($0) })) {
                    ForEach(store.accounts) { Text($0.title).tag($0.id) }
                }.pickerStyle(.menu)
            } else if let a = store.accounts.first {
                Text(a.title).font(.footnote).foregroundStyle(.secondary)
            }
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 34, weight: .light, design: .rounded))
                .frame(height: 48)
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { k in
                        Button { number += k } label: {
                            Text(k).font(.title.weight(.light))
                                .frame(width: 76, height: 76)
                                .background(Theme.surface, in: Circle())
                                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                                .foregroundStyle(Theme.text)
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 24) {
                if let a = account, !a.voicemailURI.isEmpty {
                    Button { engine.callVoicemail(a.id) } label: {
                        Image(systemName: "recordingtape").font(.title2)
                            .frame(width: 76, height: 76).foregroundStyle(Theme.brand)
                            .overlay(alignment: .topTrailing) {
                                if let n = engine.voicemail[a.id], n > 0 {
                                    Text("\(n)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.danger, in: Capsule())
                                        .offset(x: -8, y: 8)
                                }
                            }
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 76, height: 76)
                }
                Button {
                    if let a = account, engine.call(number, from: a.id) { number = "" }
                } label: {
                    Image(systemName: "phone.fill").font(.title)
                        .frame(width: 76, height: 76)
                        .background(number.isEmpty || account == nil ? Theme.brandDim.opacity(0.5) : Theme.brand, in: Circle()).foregroundStyle(Theme.onBrand)
                }.buttonStyle(.plain).disabled(number.isEmpty || account == nil)
                Button { if !number.isEmpty { number.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title2)
                        .frame(width: 76, height: 76)
                }.buttonStyle(.plain).opacity(number.isEmpty ? 0 : 1)
            }
            if store.accounts.isEmpty {
                Text("Add an account first").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .l1neBackground()
        .toolbar { ProfileToolbar() }
        .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: Recents

struct RecentsView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var callLog: CallLogStore

    private var voicemailAccounts: [Account] { store.accounts.filter { !$0.voicemailURI.isEmpty } }

    var body: some View {
        NavigationStack {
            List {
                if !voicemailAccounts.isEmpty {
                    Section {
                        ForEach(voicemailAccounts) { a in
                            Button { engine.callVoicemail(a.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "recordingtape").foregroundStyle(Theme.brand)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(voicemailAccounts.count > 1 ? "Voicemail · \(a.title)" : "Voicemail").foregroundStyle(Theme.text)
                                        let n = engine.voicemail[a.id] ?? 0
                                        Text(n > 0 ? "\(n) new message\(n == 1 ? "" : "s")" : "No new messages")
                                            .font(.footnote).foregroundStyle(n > 0 ? Theme.brand : Theme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "phone").foregroundStyle(Theme.muted)
                                }
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
                Section {
                    ForEach(callLog.records) { r in
                        Button { callBack(r) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: r.direction == .outgoing ? "phone.arrow.up.right" : (r.direction == .missed ? "phone.arrow.down.left" : "phone.arrow.down.left"))
                                    .foregroundStyle(r.direction == .missed ? Theme.danger : Theme.brand)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name(r)).foregroundStyle(r.direction == .missed ? Theme.danger : Theme.text)
                                    Text(detail(r)).font(.footnote).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(r.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onDelete { idx in callLog.delete(idx.map { callLog.records[$0].id }) }
                }
            }
            .overlay {
                if callLog.records.isEmpty && voicemailAccounts.isEmpty {
                    ContentUnavailableView("No recent calls", systemImage: "clock")
                }
            }
            .l1neBackground()
            .navigationTitle("Recents")
            .toolbar { ProfileToolbar() }
        }
    }

    private func name(_ r: CallRecord) -> String {
        let p = r.peer.split(separator: "@").map(String.init)
        if p.count == 2, let n = contacts.name(forUser: p[0], domain: p[1]) { return n }
        return p.first ?? r.peer
    }

    private func detail(_ r: CallRecord) -> String {
        let kind = r.direction == .outgoing ? "Outgoing" : (r.direction == .missed ? "Missed" : "Incoming")
        guard r.duration > 0 else { return kind }
        return "\(kind) · \(String(format: "%d:%02d", r.duration / 60, r.duration % 60))"
    }

    private func callBack(_ r: CallRecord) {
        guard let acc = r.accountID.flatMap({ store.account($0) }) ?? store.selected else { return }
        engine.call(r.peer.contains("@") ? "sip:" + r.peer : r.peer, from: acc.id)
    }
}

// MARK: In a call

struct CallScreen: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @State private var dtmfFor: Int32?
    @State private var transferFor: SIPEngine.CallInfo?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ForEach(engine.calls) { c in
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text(c.remote).font(.largeTitle.weight(.light))
                        if let since = c.since {
                            TimelineView(.periodic(from: since, by: 1)) { ctx in
                                let s = Int(ctx.date.timeIntervalSince(since))
                                Text(String(format: "%d:%02d", s / 60, s % 60)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        } else { Text(c.state).foregroundStyle(.secondary) }
                        if engine.recording.contains(c.id) {
                            Label("Recording", systemImage: "record.circle").font(.footnote).foregroundStyle(Theme.danger)
                        }
                    }
                    if c.connected {
                        Grid(horizontalSpacing: 28, verticalSpacing: 18) {
                            GridRow {
                                control("mic.slash.fill", "Mute", engine.muted.contains(c.id)) { engine.toggleMute(c.id) }
                                control("circle.grid.3x3.fill", "Keypad", false) { dtmfFor = c.id }
                                control("speaker.wave.3.fill", "Speaker", engine.speaker) { engine.toggleSpeaker() }
                            }
                            GridRow {
                                control("pause.fill", "Hold", engine.held.contains(c.id)) { engine.toggleHold(c.id) }
                                control("record.circle", "Record", engine.recording.contains(c.id)) { engine.toggleRecording(c.id) }
                                control("phone.arrow.right", "Transfer", false) { transferFor = c }
                            }
                        }
                    }
                    HStack(spacing: 40) {
                        if c.incoming && !c.connected {
                            Button { engine.answer(c.id) } label: {
                                Image(systemName: "phone.fill").font(.title)
                                    .frame(width: 76, height: 76).background(Theme.brand, in: Circle()).foregroundStyle(Theme.onBrand)
                            }
                        }
                        Button { engine.hangup(c.id) } label: {
                            Image(systemName: "phone.down.fill").font(.title)
                                .frame(width: 76, height: 76).background(Theme.danger, in: Circle()).foregroundStyle(.white)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { dtmfFor != nil }, set: { if !$0 { dtmfFor = nil } })) {
            if let id = dtmfFor { DTMFSheet(call: id).environmentObject(engine) }
        }
        .sheet(item: $transferFor) { c in TransferSheet(call: c).environmentObject(engine).environmentObject(store).environmentObject(ContactsStore.shared) }
    }

    private func control(_ icon: String, _ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).frame(width: 64, height: 64)
                    .background(on ? Theme.brand : Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.border, lineWidth: on ? 0 : 1))
                    .foregroundStyle(on ? Theme.onBrand : Theme.text)
                Text(label).font(.caption).foregroundStyle(Theme.muted)
            }
        }.buttonStyle(.plain)
    }
}

struct DTMFSheet: View {
    let call: Int32
    @EnvironmentObject var engine: SIPEngine
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    private let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["*","0","#"]]

    var body: some View {
        VStack(spacing: 18) {
            Text(typed.isEmpty ? " " : typed).font(.system(size: 30, weight: .light, design: .rounded)).frame(height: 40)
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { k in
                        Button { typed += k; engine.sendDTMF(call, k) } label: {
                            Text(k).font(.title.weight(.light)).frame(width: 70, height: 70)
                                .background(Theme.surface, in: Circle()).overlay(Circle().stroke(Theme.border)).foregroundStyle(Theme.text)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button("Done") { dismiss() }.padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

struct TransferSheet: View {
    let call: SIPEngine.CallInfo
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Extension or number", text: $number).keyboardType(.phonePad)
                    Button("Transfer") { go(number) }.disabled(number.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Theme.surface)
                if !contacts.contacts.isEmpty {
                    Section("Contacts") {
                        ForEach(contacts.contacts) { c in
                            Button { go("sip:" + c.address) } label: { Text(c.name).foregroundStyle(Theme.text) }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .l1neBackground()
            .navigationTitle("Transfer call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func go(_ dest: String) {
        guard let acc = call.accountID ?? store.selected?.id else { return }
        if engine.transfer(call.id, to: dest, account: acc) { dismiss() }
    }
}
