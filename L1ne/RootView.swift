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
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
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
            if let n = ProcessInfo.processInfo.environment["L1NE_CALLBACK"] { PhoneAppCallBack.place(n) }     // as if tapped in the Phone app
            if let n = ProcessInfo.processInfo.environment["L1NE_AUTODIAL"], let a = store.selected {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                engine.call(n, from: a.id)
            }
            #endif
        }
        .fullScreenCover(isPresented: Binding(get: { !engine.calls.isEmpty && !router.callMinimized }, set: { if !$0 { router.callMinimized = true } })) {
            CallScreen().environmentObject(engine).environmentObject(store).environmentObject(contacts).environmentObject(router)
                .preferredColorScheme(.dark)       // like the iPhone's own call screen, always dark
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
    @State private var search = ""
    @State private var confirmClear = false
    private var shown: [CallRecord] {
        let base = missedOnly ? callLog.records.filter { $0.direction == .missed } : callLog.records
        guard !search.isEmpty else { return base }
        return base.filter { name($0).localizedCaseInsensitiveContains(search) || $0.peer.localizedCaseInsensitiveContains(search) }
    }

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
                                        Text(whenText(r.date)).lineLimit(1)
                                    }
                                    .font(.subheadline).foregroundStyle(Theme.muted)
                                    if let d = details(r) { Text(d).font(.caption).foregroundStyle(r.direction == .missed ? Theme.danger.opacity(0.85) : Theme.muted).lineLimit(1) }
                                }
                                Spacer(minLength: 8)
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
            .searchable(text: $search)
            .confirmationDialog("Delete all recent calls?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { callLog.removeAll() }
            }
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
                        Divider()
                        Button("Delete all calls", systemImage: "trash", role: .destructive) { confirmClear = true }.disabled(callLog.records.isEmpty)
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

    /// "Today | 12:37 PM", "Yesterday | 9:10 PM", "11/13 | 10:41 AM": the day and the time of every call.
    private func whenText(_ d: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.month(.defaultDigits).day())
        return "\(day) | \(d.formatted(date: .omitted, time: .shortened))"
    }

    /// Missed, how long it lasted, and which account (only when there is more than one).
    private func details(_ r: CallRecord) -> String? {
        var parts: [String] = []
        if r.direction == .missed { parts.append("Missed") }
        else if r.duration > 0 { parts.append(String(format: "%d:%02d", r.duration / 60, r.duration % 60)) }
        else { parts.append(r.direction == .outgoing ? "Not answered" : "Declined") }
        if store.accounts.count > 1, let a = r.accountID.flatMap({ store.account($0) }) { parts.append(a.title) }
        return parts.joined(separator: " · ")
    }

    private func name(_ r: CallRecord) -> String {
        let p = r.peer.split(separator: "@").map(String.init)
        if let n = contacts.name(forUser: p.first ?? r.peer, domain: p.count == 2 ? p[1] : nil) { return n }
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
    @State private var showMore = false

    var body: some View {
        if let c = engine.currentCall { screen(c) } else { Theme.bg.ignoresSafeArea() }
    }

    // Laid out like the iOS call screen: name and time at the top, six round buttons, one big end button.
    // What iOS doesn't normally show (transfer, record, messages, the calls list) lives under "more".
    private func screen(_ c: SIPEngine.CallInfo) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { router.callMinimized = true } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Minimise call")
                Spacer()
                if c.connected { SignalBars(level: engine.quality[c.id] ?? 0, numbers: engine.qualityNumbers[c.id]) }
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
                    Text(c.incoming ? "Incoming call" : c.state).font(.title3).foregroundStyle(Theme.muted)
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
        .fullScreenCover(isPresented: $showKeypad) { DTMFScreen(call: c.id).environmentObject(engine).preferredColorScheme(.dark) }
        .sheet(isPresented: $showTransfer) { TransferSheet(call: c).environmentObject(engine).environmentObject(store).environmentObject(ContactsStore.shared) }
        .sheet(isPresented: $showCalls) { CallsListSheet().environmentObject(engine) }
        .sheet(isPresented: $showMore) { moreSheet(c).presentationDetents([.height(300)]).presentationDragIndicator(.visible).preferredColorScheme(.dark) }
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

    /// "more": a button that slides a sheet up from the bottom (like the old keypad sheet) instead of the system pop-up menu.
    private func moreMenu(_ c: SIPEngine.CallInfo) -> some View {
        Button { showMore = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "ellipsis").font(.title2).frame(width: 78, height: 78)
                    .background(Theme.surface, in: Circle()).overlay(Circle().stroke(Theme.border)).foregroundStyle(Theme.text)
                Text("more").font(.footnote).foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
    }

    private func moreSheet(_ c: SIPEngine.CallInfo) -> some View {
        let live = c.connected
        // a sheet can't open another sheet while it is closing, so the follow-up action waits for it to go away
        func pick(_ action: @escaping () -> Void) {
            showMore = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: action)
        }
        func row(_ icon: String, _ title: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
            Button { pick(action) } label: {
                HStack(spacing: 16) {
                    Image(systemName: icon).font(.title3).foregroundStyle(Theme.brand).frame(width: 30)
                    Text(title).font(.body).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
        return VStack(spacing: 10) {
            row("phone.arrow.right", "Transfer…", enabled: live) { showTransfer = true }
            row("record.circle", engine.recording.contains(c.id) ? "Stop recording" : "Record call", enabled: live) { engine.toggleRecording(c.id) }
            row("bubble.left", "Messages", enabled: !c.address.isEmpty) { openMessages(c) }
            row("list.bullet", "Calls list") { showCalls = true }
        }
        .padding(.horizontal, 16).padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sheet.ignoresSafeArea())
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
/// Call quality as a small pill: five rounded bars in the brand green (amber when fair, red when poor) and the word for it.
struct SignalBars: View {
    var level: Int
    var numbers: SIPEngine.QualityNumbers?

    // green for fair and better, amber when it is really degraded, red when it is bad
    private var tint: Color { level >= 3 ? Theme.brand : (level == 2 ? .orange : Theme.danger) }
    private var word: String { ["", "Poor", "Poor", "Fair", "Good", "Excellent"][max(0, min(5, level))] }

    private var pill: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(1...5, id: \.self) { i in
                Capsule().fill(i <= level ? tint : Theme.muted.opacity(0.28)).frame(width: 3.5, height: CGFloat(4 + i * 3))
            }
        }
        .frame(height: 19)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }

    @State private var showNumbers = false

    var body: some View {
        // tapping shows the figures behind the score, as plain text in a small popover
        Button { if numbers != nil { showNumbers = true } } label: { pill }
            .buttonStyle(.plain)
            .popover(isPresented: $showNumbers, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                if let n = numbers {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Call quality: \(word.lowercased())").font(.headline)
                        Text(String(format: "Packet loss: %.1f %%", n.lossPercent))
                        Text(String(format: "Jitter: %.0f ms", n.jitterMs))
                        Text(n.roundTripMs > 0 ? String(format: "Round trip: %.0f ms", n.roundTripMs) : "Round trip: not reported")
                    }
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.text)
                    .padding(18)
                    .presentationCompactAdaptation(.popover)
                }
            }
            .accessibilityLabel("Call quality \(word.lowercased())")
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

/// The in-call keypad, full screen like the iPhone's: a back button, the digits you have sent, the keys and the end button.
struct DTMFScreen: View {
    let call: Int32
    @EnvironmentObject var engine: SIPEngine
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    private let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).accessibilityLabel("Back to the call")
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 8)

            Text(typed.isEmpty ? " " : typed)
                .font(.system(size: 38, weight: .light, design: .rounded)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.5).frame(height: 56).padding(.horizontal, 24).padding(.top, 24)
            Spacer(minLength: 12)

            VStack(spacing: 16) {
                ForEach(keys, id: \.self.first!.0) { row in
                    HStack(spacing: 22) {
                        ForEach(row, id: \.0) { k in
                            Button { typed += k.0; engine.sendDTMF(call, k.0) } label: {
                                VStack(spacing: -2) {
                                    Text(k.0).font(.system(size: 34))
                                    if !k.1.isEmpty { Text(k.1).font(.system(size: 11, weight: .bold)).tracking(2.5).foregroundStyle(Theme.muted) }
                                }
                                .foregroundStyle(Theme.text)
                                .frame(width: 82, height: 82)
                                .background(Theme.surface, in: Circle()).overlay(Circle().stroke(Theme.border, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 24)

            Button { engine.hangup(call); dismiss() } label: {
                Image(systemName: "phone.down.fill").font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: 78, height: 78).background(Theme.danger, in: Circle())
            }
            .buttonStyle(.plain).padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
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
