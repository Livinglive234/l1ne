import SwiftUI

struct RootView: View {
    @StateObject private var engine = SIPEngine.shared
    @StateObject private var store = AccountStore.shared
    @StateObject private var contacts = ContactsStore.shared
    @StateObject private var messages = MessageStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var dirs = DirectoryStore.shared
    @StateObject private var callLog = CallLogStore.shared
    @StateObject private var router = AppRouter.shared
    @State private var setupLink: SetupLink?

    struct SetupLink: Identifiable { let id = UUID(); let text: String }

    var body: some View {
        TabView(selection: $router.tab) {
            RecentsView()
                .tabItem { Label("Recents", systemImage: "clock") }.tag(AppRouter.Tab.recents)
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2") }.tag(AppRouter.Tab.contacts)
            ConversationsView()
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
                .badge(messages.unread).tag(AppRouter.Tab.conversations)
            KeypadView()
                .tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }.tag(AppRouter.Tab.keypad)
        }
        .tint(Theme.brand)
        .overlay(alignment: .bottom) {
            // while the call screen is minimised, a pill above the tab bar keeps the call one tap away
            if router.callMinimized, let c = engine.currentCall {
                Button { router.callMinimized = false } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                        Text(c.remote).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        if let since = c.since {
                            TimelineView(.periodic(from: since, by: 1)) { ctx in
                                let t = Int(ctx.date.timeIntervalSince(since)); Text(String(format: "%d:%02d", t / 60, t % 60)).monospacedDigit()
                            }
                        } else { Text(c.state) }
                        Text("Tap to return").foregroundStyle(Theme.onBrand.opacity(0.7))
                    }
                    .font(.footnote).foregroundStyle(Theme.onBrand)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Theme.brand, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: router.callMinimized)
        .environmentObject(engine)
        .environmentObject(store)
        .environmentObject(contacts)
        .environmentObject(messages)
        .environmentObject(settings)
        .environmentObject(dirs)
        .environmentObject(callLog)
        .environmentObject(router)
        .onOpenURL { setupLink = SetupLink(text: $0.absoluteString) }
        .sheet(item: $setupLink) {
            ProvisionSheet(initialLink: $0.text).environmentObject(engine).environmentObject(store).environmentObject(contacts).environmentObject(dirs)
        }
        .onChange(of: engine.calls.count) { old, new in
            if new > old || new == 0 { router.callMinimized = false }          // a new call, or none left: back to normal
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
        .fullScreenCover(isPresented: Binding(get: { !engine.calls.isEmpty && !router.callMinimized }, set: { if !$0 { router.callMinimized = true } })) {
            CallScreen().environmentObject(engine).environmentObject(store).environmentObject(contacts).environmentObject(router)
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
    @EnvironmentObject var router: AppRouter
    @State private var expanded = false
    @State private var showKeypad = false
    @State private var showTransfer = false
    @State private var showCalls = false

    var body: some View {
        if let c = engine.currentCall { screen(c) } else { Theme.bg.ignoresSafeArea() }
    }

    private func screen(_ c: SIPEngine.CallInfo) -> some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header(c)
                Spacer()
                avatar(c)
                VStack(spacing: 6) {
                    Text(c.remote).font(.title2.weight(.light))
                    if !c.address.isEmpty { Text(c.address).font(.callout).foregroundStyle(Theme.muted) }
                    if engine.held.contains(c.id) { Label("On hold", systemImage: "pause.circle.fill").font(.footnote).foregroundStyle(Theme.brand) }
                }.padding(.top, 18)
                Spacer(minLength: expanded ? 360 : 170)
            }
            sheet(c)
        }
        .sheet(isPresented: $showKeypad) { DTMFSheet(call: c.id).environmentObject(engine) }
        .sheet(isPresented: $showTransfer) { TransferSheet(call: c).environmentObject(engine).environmentObject(store).environmentObject(ContactsStore.shared) }
        .sheet(isPresented: $showCalls) { CallsListSheet().environmentObject(engine) }
    }

    // MARK: top: back, name | time, encryption, signal

    private func header(_ c: SIPEngine.CallInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button { router.callMinimized = true } label: { Image(systemName: "chevron.left").font(.title3.weight(.medium)).frame(width: 30, height: 30) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(c.remote).fontWeight(.bold).lineLimit(1)
                    Text("|").foregroundStyle(Theme.muted)
                    if let since = c.since {
                        TimelineView(.periodic(from: since, by: 1)) { ctx in
                            let s = Int(ctx.date.timeIntervalSince(since))
                            Text(String(format: "%02d:%02d", s / 60, s % 60)).fontWeight(.bold).monospacedDigit()
                        }
                    } else { Text(c.state).fontWeight(.bold) }
                }.font(.headline)
                if let line = securityLine(c) { Label(line.text, systemImage: line.icon).font(.footnote).foregroundStyle(line.color) }
                if engine.recording.contains(c.id) { Label("Recording", systemImage: "record.circle").font(.footnote).foregroundStyle(Theme.danger) }
            }
            Spacer()
            if c.connected { SignalBars(level: engine.quality[c.id] ?? 0) }
        }
        .padding(.horizontal, 18).padding(.top, 10)
    }

    private func securityLine(_ c: SIPEngine.CallInfo) -> (text: String, icon: String, color: Color)? {
        guard c.connected else { return nil }
        switch engine.encryption[c.id] ?? .unknown {
        case .srtp: return ("Point-to-point encrypted by SRTP", "lock.fill", Theme.brand)
        case .dtls: return ("Point-to-point encrypted by DTLS-SRTP", "lock.fill", Theme.brand)
        case .none: return ("Not encrypted", "lock.open.fill", Theme.danger)
        case .unknown: return nil
        }
    }

    private func avatar(_ c: SIPEngine.CallInfo) -> some View {
        let initials = String(c.remote.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased()
        return ZStack {
            Circle().fill(Theme.brand.opacity(0.16))
            Circle().stroke(Theme.brand.opacity(0.5), lineWidth: 1)
            Text(initials.isEmpty ? "?" : initials).font(.system(size: 96, weight: .semibold, design: .rounded)).foregroundStyle(Theme.brand)
        }.frame(width: 220, height: 220)
    }

    // MARK: bottom sheet: hang up, mute, speaker; expands to the rest

    private func sheet(_ c: SIPEngine.CallInfo) -> some View {
        VStack(spacing: 18) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "chevron.compact.down" : "chevron.compact.up").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }.buttonStyle(.plain)

            HStack(spacing: 14) {
                if c.incoming && !c.connected {
                    Button { engine.answer(c.id) } label: { Image(systemName: "phone.fill").font(.title2).frame(width: 96, height: 64).background(Theme.brand, in: Capsule()).foregroundStyle(Theme.onBrand) }
                }
                Button { engine.hangup(c.id) } label: {
                    Image(systemName: "phone.down.fill").font(.title2).frame(width: 96, height: 64).background(Theme.danger, in: Capsule()).foregroundStyle(.white)
                }
                Spacer()
                round("mic.slash.fill", on: engine.muted.contains(c.id), enabled: c.connected) { engine.toggleMute(c.id) }
                round("speaker.wave.3.fill", on: engine.speaker, enabled: true) { engine.toggleSpeaker() }
            }

            if expanded {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 14) {
                    item("phone.arrow.right", "Transfer", c.connected) { showTransfer = true }
                    item("phone.badge.plus", "New call", c.connected) { router.callMinimized = true; router.tab = .keypad }
                    item("list.bullet", "Calls list", true) { showCalls = true }
                    item("circle.grid.3x3.fill", "Dialer", c.connected) { showKeypad = true }
                    item("bubble.left", "Messages", !c.address.isEmpty) { openMessages(c) }
                    item(engine.held.contains(c.id) ? "play.fill" : "pause.fill", engine.held.contains(c.id) ? "Resume" : "Pause", c.connected, on: engine.held.contains(c.id)) { engine.toggleHold(c.id) }
                    item("record.circle", "Record", c.connected, on: engine.recording.contains(c.id)) { engine.toggleRecording(c.id) }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 6)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28).fill(Theme.surface).ignoresSafeArea(edges: .bottom)
        }
    }

    private func round(_ icon: String, on: Bool, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 64, height: 64)
                .background(on ? Theme.brand : Theme.bg.opacity(0.6), in: Circle())
                .foregroundStyle(on ? Theme.onBrand : Theme.text)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private func item(_ icon: String, _ label: String, _ enabled: Bool, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).frame(width: 60, height: 60)
                    .background(on ? Theme.brand : Theme.bg.opacity(0.6), in: Circle())
                    .foregroundStyle(on ? Theme.onBrand : Theme.text)
                Text(label).font(.footnote).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
            }
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private func openMessages(_ c: SIPEngine.CallInfo) {
        guard let acc = c.accountID ?? store.selected?.id, !c.address.isEmpty else { return }
        router.pendingThread = ThreadTarget(accountID: acc, peer: c.address)
        router.tab = .conversations
        router.callMinimized = true
    }
}

/// Five bars like a phone's signal meter; filled by call quality.
struct SignalBars: View {
    var level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5).fill(i <= level ? Theme.text : Theme.muted.opacity(0.35)).frame(width: 4, height: CGFloat(5 + i * 5))
            }
        }.frame(height: 32).accessibilityLabel("Call quality \(level) of 5")
    }
}

/// All calls in progress: switch to one (the others go on hold) or hang one up.
struct CallsListSheet: View {
    @EnvironmentObject var engine: SIPEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(engine.calls) { c in
                    HStack(spacing: 12) {
                        Button { engine.switchTo(c.id); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.remote).foregroundStyle(Theme.text)
                                Text(status(c)).font(.footnote).foregroundStyle(Theme.muted)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        if c.id == engine.currentCall?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.brand) }
                        Button { engine.hangup(c.id) } label: { Image(systemName: "phone.down.fill").foregroundStyle(Theme.danger) }.buttonStyle(.plain)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .l1neBackground()
            .navigationTitle("Calls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func status(_ c: SIPEngine.CallInfo) -> String {
        if !c.connected { return c.incoming ? "Incoming" : c.state }
        return engine.held.contains(c.id) ? "On hold" : "Active"
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
