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
            if settings.showVoicemailTab {
                VoicemailView()
                    .tabItem { Label("Voicemail", systemImage: "recordingtape") }
                    .badge(engine.voicemail.values.reduce(0, +)).tag(AppRouter.Tab.voicemail)
            }
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
    @EnvironmentObject var settings: AppSettings
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
                if settings.showKeypadVoicemail, let a = account, !a.voicemailURI.isEmpty {
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
        .mainBackground()
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

    @State private var missedOnly = false
    @State private var detail: PersonTarget?
    private var shown: [CallRecord] { missedOnly ? callLog.records.filter { $0.direction == .missed } : callLog.records }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { r in
                    HStack(spacing: 14) {
                        Button { detail = PersonTarget(name: name(r), address: r.peer, accountID: r.accountID) } label: {
                            HStack(spacing: 14) {
                                avatar(r)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name(r)).font(.body.weight(.medium))
                                        .foregroundStyle(r.direction == .missed ? Theme.danger : Theme.text).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Image(systemName: r.direction == .outgoing ? "arrow.up.right" : "arrow.down.left").font(.caption2.weight(.semibold))
                                        Text(subtitle(r)).lineLimit(1)
                                    }
                                    .font(.subheadline).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 8)
                                Text(when(r.date)).font(.subheadline).foregroundStyle(Theme.muted)
                            }
                        }.buttonStyle(.plain)
                        CallCircleButton { callBack(r) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.border)
                    .swipeActions { Button(role: .destructive) { callLog.delete([r.id]) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .navigationDestination(item: $detail) { ContactDetailView(person: $0) }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(missedOnly ? "No missed calls" : "No recent calls", systemImage: "clock")
                }
            }
            .mainBackground()
            .navigationTitle("Recents")
            .toolbar {
                ProfileToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $missedOnly) {
                            Label("All", systemImage: "phone").tag(false)
                            Label("Missed", systemImage: "phone.arrow.down.left").tag(true)
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                }
            }
        }
    }

    private func avatar(_ r: CallRecord) -> some View {
        let n = name(r)
        let initials = n.first.map { $0.isLetter } == true ? String(n.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased() : ""
        return ZStack {
            Circle().fill(Theme.surface)
            if initials.isEmpty { Image(systemName: "person.fill").font(.title3).foregroundStyle(Theme.muted) }
            else { Text(initials).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.brand) }
        }.frame(width: 48, height: 48)
    }

    private func subtitle(_ r: CallRecord) -> String {
        let acc = r.accountID.flatMap { store.account($0) }?.title ?? "L1ne"
        return r.direction == .missed ? "Missed · \(acc)" : acc
    }

    /// Like the Phone app: the time today, "Yesterday", the weekday this week, otherwise the date.
    private func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
        return d.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits))
    }

    private func name(_ r: CallRecord) -> String {
        let p = r.peer.split(separator: "@").map(String.init)
        if p.count == 2, let n = contacts.name(forUser: p[0], domain: p[1]) { return n }
        return p.first ?? r.peer
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
    @State private var showKeypad = false
    @State private var showTransfer = false
    @State private var showCalls = false

    var body: some View {
        if let c = engine.currentCall { screen(c) } else { Theme.bg.ignoresSafeArea() }
    }

    // Laid out like the iOS call screen: name and time at the top, six round buttons, one big end button.
    // What iOS doesn't normally show (transfer, record, messages, the calls list) lives under "more".
    private func screen(_ c: SIPEngine.CallInfo) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { router.callMinimized = true } label: { Image(systemName: "chevron.left").font(.title3.weight(.medium)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain)
                Spacer()
                if c.connected { SignalBars(level: engine.quality[c.id] ?? 0) }
            }
            .padding(.horizontal, 18).padding(.top, 8)

            VStack(spacing: 8) {
                Text(c.remote).font(.system(size: 36, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                if let since = c.since {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(since))
                        Text(String(format: "%d:%02d", s / 60, s % 60)).font(.title3).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                } else {
                    Text(c.incoming ? "incoming call" : c.state.lowercased()).font(.title3).foregroundStyle(Theme.muted)
                }
                if let line = securityLine(c) { Label(line.text, systemImage: line.icon).font(.footnote).foregroundStyle(line.color) }
                if engine.held.contains(c.id) { Label("On hold", systemImage: "pause.circle.fill").font(.footnote).foregroundStyle(Theme.brand) }
                if engine.recording.contains(c.id) { Label("Recording", systemImage: "record.circle").font(.footnote).foregroundStyle(Theme.danger) }
            }
            .padding(.horizontal, 24).padding(.top, 28)

            Spacer()
            if c.connected || !c.incoming { buttons(c) }
            Spacer()
            endButtons(c)
                .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showKeypad) { DTMFSheet(call: c.id).environmentObject(engine) }
        .sheet(isPresented: $showTransfer) { TransferSheet(call: c).environmentObject(engine).environmentObject(store).environmentObject(ContactsStore.shared) }
        .sheet(isPresented: $showCalls) { CallsListSheet().environmentObject(engine) }
    }

    private func securityLine(_ c: SIPEngine.CallInfo) -> (text: String, icon: String, color: Color)? {
        guard c.connected else { return nil }
        switch engine.encryption[c.id] ?? .unknown {
        case .srtp: return ("Encrypted by SRTP", "lock.fill", Theme.brand)
        case .dtls: return ("Encrypted by DTLS-SRTP", "lock.fill", Theme.brand)
        case .none: return ("Not encrypted", "lock.open.fill", Theme.danger)
        case .unknown: return nil
        }
    }

    // MARK: the six buttons

    private func buttons(_ c: SIPEngine.CallInfo) -> some View {
        let live = c.connected
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 26) {
            roundButton("mic.slash.fill", "mute", on: engine.muted.contains(c.id), enabled: live) { engine.toggleMute(c.id) }
            roundButton("circle.grid.3x3.fill", "keypad", enabled: live) { showKeypad = true }
            roundButton("speaker.wave.3.fill", "speaker", on: engine.speaker) { engine.toggleSpeaker() }
            roundButton("plus", "add call", enabled: live) { router.callMinimized = true; router.tab = .keypad }
            roundButton(engine.held.contains(c.id) ? "play.fill" : "pause.fill", engine.held.contains(c.id) ? "resume" : "hold",
                        on: engine.held.contains(c.id), enabled: live) { engine.toggleHold(c.id) }
            moreMenu(c)
        }
        .padding(.horizontal, 28)
    }

    private func moreMenu(_ c: SIPEngine.CallInfo) -> some View {
        let live = c.connected
        return Menu {
            Button("Transfer…", systemImage: "phone.arrow.right") { showTransfer = true }.disabled(!live)
            Button(engine.recording.contains(c.id) ? "Stop recording" : "Record call", systemImage: "record.circle") { engine.toggleRecording(c.id) }.disabled(!live)
            Button("Messages", systemImage: "bubble.left") { openMessages(c) }.disabled(c.address.isEmpty)
            Button("Calls list", systemImage: "list.bullet") { showCalls = true }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "ellipsis").font(.title2).frame(width: 78, height: 78)
                    .background(Theme.surface, in: Circle()).overlay(Circle().stroke(Theme.border)).foregroundStyle(Theme.text)
                Text("more").font(.footnote).foregroundStyle(Theme.text)
            }
        }
    }

    private func roundButton(_ icon: String, _ label: String, on: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).frame(width: 78, height: 78)
                    .background(on ? Theme.brand : Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.border, lineWidth: on ? 0 : 1))
                    .foregroundStyle(on ? Theme.onBrand : Theme.text)
                Text(label).font(.footnote).foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    // MARK: end / answer

    @ViewBuilder private func endButtons(_ c: SIPEngine.CallInfo) -> some View {
        if c.incoming && !c.connected {
            HStack(spacing: 90) {
                bigButton("phone.down.fill", "decline", Theme.danger, .white) { engine.hangup(c.id) }
                bigButton("phone.fill", "accept", Theme.brand, Theme.onBrand) { engine.answer(c.id) }
            }
        } else {
            bigButton("phone.down.fill", nil, Theme.danger, .white) { engine.hangup(c.id) }
        }
    }

    private func bigButton(_ icon: String, _ label: String?, _ fill: Color, _ fg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 30)).frame(width: 78, height: 78).background(fill, in: Circle()).foregroundStyle(fg)
                if let label { Text(label).font(.footnote).foregroundStyle(Theme.text) }
            }
        }.buttonStyle(.plain)
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
        .background(Theme.sheet.ignoresSafeArea())
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
