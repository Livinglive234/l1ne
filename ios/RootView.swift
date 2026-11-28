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
    @Environment(\.colorScheme) private var scheme
    private var callGray: Bool { settings.appearance == .light || (settings.appearance == .system && scheme == .light) }
    @State private var setupLink: SetupLink?
    @State private var signingIn = false        // the welcome screen stays up while a first login is being checked

    private var showWelcome: Bool { store.accounts.isEmpty || signingIn }

    struct SetupLink: Identifiable { let id = UUID(); let text: String }

    var body: some View {
        Group {
            if showWelcome {
                WelcomeView(signingIn: $signingIn)
                    .environmentObject(engine).environmentObject(store).environmentObject(contacts)
                    .environmentObject(dirs)
                    .transition(.opacity.combined(with: .scale(scale: 1.06)))      // the welcome screen eases away, the app fades in
            } else { mainTabs.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.5), value: showWelcome)
        .environmentObject(engine)
        .environmentObject(store)
        .environmentObject(contacts)
        .environmentObject(messages)
        .environmentObject(settings)
        .environmentObject(dirs)
        .environmentObject(callLog)
        .environmentObject(router)
        .overlay(alignment: .top) {
            if let n = engine.notice {
                Text(n).font(.footnote).multilineTextAlignment(.center).padding(12).frame(maxWidth: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.6)))
                    .padding(.horizontal, 16).padding(.top, 8).onTapGesture { engine.notice = nil }.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.notice)
        .onOpenURL { url in
            if let s = url.scheme?.lowercased(), s == "sip" || s == "sips" {
                router.pendingDial = AppRouter.dialTarget(fromSIP: url); router.tab = .keypad; router.callMinimized = true
            } else { setupLink = SetupLink(text: url.absoluteString) }
        }
        .sheet(item: $setupLink) {
            ProvisionSheet(initialLink: $0.text).environmentObject(engine).environmentObject(store).environmentObject(contacts).environmentObject(dirs)
        }
        .onChangeCompat(of: engine.calls.count) { old, new in
            if new > old || new == 0 { router.callMinimized = false }          // a new call, or none left: back to normal
        }
        .task {
            #if DEBUG
            if UITestSeed.requested { UITestSeed.apply() }        // the screen tests start from sample data
            #endif
            engine.start()
            for a in store.accounts { engine.register(a, secret: store.secret(a.id)) }
            #if DEBUG
            // tests/mock: place a call a few seconds after launch
            if let n = ProcessInfo.processInfo.environment["L1NE_CALLBACK"] { PhoneAppCallBack.place(n) }     // as if tapped in the Phone app
            if let n = ProcessInfo.processInfo.environment["L1NE_AUTODIAL"], let a = store.selected {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                engine.call(n, from: a.id)
                // tests/mock: as if the network changed this many seconds into the call
                if let s = ProcessInfo.processInfo.environment["L1NE_TESTSWITCH"], let secs = Double(s) {
                    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    engine.networkChanged()
                }
            }
            #endif
        }
        .fullScreenCover(isPresented: Binding(get: { !engine.calls.isEmpty && !router.callMinimized }, set: { if !$0 { router.callMinimized = true } })) {
            CallScreen().environmentObject(engine).environmentObject(store).environmentObject(contacts).environmentObject(router)
                .preferredColorScheme(.dark)       // text and icons stay light; the background turns gray in light mode
                .environment(\.callGray, callGray)
        }
    }

    private var mainTabs: some View {
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

    @Environment(\.isWide) private var wide

    var body: some View {
        ListAndDetail { listStack } detail: { PersonPane(person: detail) }
    }

    private var listStack: some View {
        let rows = shown                                 // filtered once per redraw (the empty-state check below reuses it)
        return AppNavStack {
            List {
                ForEach(rows) { r in
                    let n = name(r)                      // looked up once per row, not once for the button, the title and the picture
                    HStack(spacing: 14) {
                        Button { detail = PersonTarget(name: n, address: r.peer, accountID: r.accountID) } label: {
                            HStack(spacing: 14) {
                                avatar(r, name: n)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(n).font(.body.weight(.medium))
                                            .foregroundStyle(r.direction == .missed ? Theme.danger : Theme.text).lineLimit(1)
                                        if let s = r.security, !s.isEmpty {         // encrypted; a seal when the code was compared with this person
                                            Image(systemName: s.hasSuffix("verified") ? "checkmark.seal.fill" : "lock.fill").font(.caption).foregroundStyle(Theme.brand)
                                                .accessibilityLabel(s.hasSuffix("verified") ? "Encrypted, code verified" : "Encrypted")
                                        }
                                    }
                                    if let num = numberUnder(r, title: n) { Text(num).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1) }
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
            .listStyle(.plain).hideScrollBackground()
            .navDestination(item: $detail, unless: wide) { ContactDetailView(person: $0) }
            .searchable(text: $search)
            .confirmationDialog("Delete all recent calls?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { callLog.removeAll() }
            }
            .overlay {
                if rows.isEmpty {
                    EmptyState(missedOnly ? "No missed calls" : "No recent calls", systemImage: "clock")
                }
            }
            .mainBackground()
            .navigationTitle("Recents")
            .profileToolbar()
            .toolbar {
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

    private func avatar(_ r: CallRecord, name n: String) -> some View {
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

    /// A contact's name, else the name the caller sent (caller ID), else the number. The number goes underneath whenever the title is a name.
    private func name(_ r: CallRecord) -> String {
        let parts = r.peer.split(separator: "@", maxSplits: 1).map(String.init), user = parts.first ?? r.peer
        if let c = contacts.name(forUser: user, domain: parts.count == 2 ? parts[1] : nil) { return c }
        if let n = r.callerName, !n.isEmpty { return PhoneFormat.pretty(n) }
        return PhoneFormat.pretty(user)
    }
    private func numberUnder(_ r: CallRecord, title: String) -> String? {
        let p = PhoneFormat.pretty(r.peer.split(separator: "@", maxSplits: 1).first.map(String.init) ?? r.peer)
        return p == title ? nil : p
    }

    private func callBack(_ r: CallRecord) {
        guard let acc = store.dialAccount(r.accountID) else { return }
        engine.call(r.peer, from: acc.id)
    }
}

// MARK: In a call

struct CallScreen: View {
    @Environment(\.callGray) private var gray
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var router: AppRouter
    @State private var showKeypad = false
    @State private var showTransfer = false
    @State private var showCalls = false
    @State private var showMore = false

    var body: some View {
        if let c = engine.currentCall { screen(c) } else { CallColors.bg(gray).ignoresSafeArea() }
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
                if let mic = engine.autoAnswered[c.id] {
                    Label(mic ? "Answered automatically · your microphone is ON" : "Answered automatically · your microphone is off", systemImage: "ear")
                        .font(.footnote).foregroundStyle(mic ? Theme.danger : Theme.brand)
                }
                if engine.encryption[c.id] == .zrtp, let z = engine.zrtp[c.id] {             // the code to read out loud, compared with the other person
                    Text("Code: \(z.code)" + (z.verified ? "  ·  verified" : "")).font(.callout.monospaced())
                    if z.cacheMismatch {
                        Text("This is not the same secret as in earlier calls with this person. Read the code to each other; if it differs, hang up.")
                            .font(.caption).multilineTextAlignment(.center).foregroundStyle(Theme.danger)
                    }
                    if !z.verified {
                        HStack(spacing: 12) {
                            Button("Code matches") { engine.zrtpVerified(c.id, matched: true) }.buttonStyle(.bordered)
                            Button("Doesn't match") { engine.zrtpVerified(c.id, matched: false) }.buttonStyle(.bordered).tint(Theme.danger)
                        }
                    }
                }
                if let original = engine.consults[c.id] {            // an attended transfer: this call asks the new person, the caller is on hold
                    Text("\(engine.calls.first { $0.id == original }?.remote ?? "The caller") is on hold").font(.footnote).foregroundStyle(Theme.muted)
                    HStack(spacing: 12) {
                        Button("Complete transfer") { engine.completeTransfer(consult: c.id) }.buttonStyle(.borderedProminent).disabled(!c.connected || engine.transferNote[c.id] != nil)
                        Button("Cancel") { engine.cancelConsult(c.id) }.buttonStyle(.bordered).tint(Theme.danger)
                    }
                }
                if let note = engine.transferNote[c.id] { Label(note, systemImage: "arrow.turn.up.right").font(.footnote).foregroundStyle(note.hasPrefix("Transfer failed") ? Theme.danger : Theme.brand) }
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
        .background(CallColors.bg(gray).ignoresSafeArea())
        .fullScreenCover(isPresented: $showKeypad) { DTMFScreen(call: c.id).environmentObject(engine).preferredColorScheme(.dark) }
        .sheet(isPresented: $showTransfer) { TransferSheet(call: c).environmentObject(engine).environmentObject(store).environmentObject(ContactsStore.shared) }
        .sheet(isPresented: $showCalls) { CallsListSheet().environmentObject(engine) }
        .sheet(isPresented: $showMore) { moreSheet(c).sheetCard(.height(300)).preferredColorScheme(.dark) }
    }

    private func securityLine(_ c: SIPEngine.CallInfo) -> (text: String, icon: String, color: Color)? {
        guard c.connected else { return nil }
        switch engine.encryption[c.id] ?? .unknown {
        case .srtp: return ("Encrypted by SRTP (point to point)", "lock.fill", Theme.brand)
        case .dtls: return ("Encrypted by DTLS-SRTP (point to point)", "lock.fill", Theme.brand)
        case .zrtp: return ("Encrypted by ZRTP (end to end)", "lock.fill", Theme.brand)
        case .none:
            let a = c.accountID.flatMap { store.account($0) }
            return (a?.media == .zrtp ? "Not encrypted: the other side has no ZRTP" : "Not encrypted", "lock.open.fill", Theme.danger)
        case .unknown:
            let a = c.accountID.flatMap { store.account($0) }
            return a?.media == .zrtp ? ("Securing the call (ZRTP)…", "lock.rotation", Theme.muted) : nil
        }
    }

    // MARK: the six buttons

    private func buttons(_ c: SIPEngine.CallInfo) -> some View {
        let live = c.connected
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 26) {
            roundButton("mic.slash.fill", "mute", on: engine.muted.contains(c.id), enabled: live) { engine.toggleMute(c.id) }
            roundButton("circle.grid.3x3.fill", "keypad", enabled: live) { showKeypad = true }
            audioButton()
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
                    .background(CallColors.surface(gray), in: Circle()).overlay(Circle().stroke(CallColors.border(gray))).foregroundStyle(Theme.text)
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

    /// Speaker, or, when a Bluetooth device is connected, a menu of where the audio can go (the phone, the speaker, each device by name).
    @ViewBuilder private func audioButton() -> some View {
        let r = engine.route
        if r.bluetooth.isEmpty && r.kind != .bluetooth {
            roundButton("speaker.wave.3.fill", "speaker", on: engine.speaker) { engine.toggleSpeaker() }
        } else {
            Menu {
                Button { engine.selectPhone() } label: { Label("Phone" + (r.kind == .phone ? "  ✓" : ""), systemImage: "iphone") }
                Button { engine.selectSpeaker() } label: { Label("Speaker" + (r.kind == .speaker ? "  ✓" : ""), systemImage: "speaker.wave.3.fill") }
                ForEach(r.bluetooth, id: \.self) { n in
                    Button { engine.selectBluetooth(n) } label: { Label(n + (r.kind == .bluetooth && r.output == n ? "  ✓" : ""), systemImage: "headphones") }
                }
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: r.kind == .bluetooth ? "headphones" : r.kind == .speaker ? "speaker.wave.3.fill" : "ellipsis.circle.fill").font(.title2).frame(width: 78, height: 78)
                        .background(r.kind == .bluetooth || r.kind == .speaker ? Theme.brand : CallColors.surface(gray), in: Circle())
                        .overlay(Circle().stroke(CallColors.border(gray), lineWidth: r.kind == .bluetooth || r.kind == .speaker ? 0 : 1))
                        .foregroundStyle(r.kind == .bluetooth || r.kind == .speaker ? Theme.onBrand : Theme.text)
                    Text(r.kind == .bluetooth ? r.output : r.kind == .speaker ? "speaker" : "audio").font(.footnote).foregroundStyle(Theme.text).lineLimit(1)
                }
            }
        }
    }

    private func roundButton(_ icon: String, _ label: String, on: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).frame(width: 78, height: 78)
                    .background(on ? Theme.brand : CallColors.surface(gray), in: Circle())
                    .overlay(Circle().stroke(CallColors.border(gray), lineWidth: on ? 0 : 1))
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
    @Environment(\.callGray) private var gray
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
        .background(CallColors.surface(gray), in: Capsule())
        .overlay(Capsule().stroke(CallColors.border(gray), lineWidth: 1))
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
                    .compactPopover()
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
        AppNavStack {
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
            .sheetPage("Calls", close: .done)
        }
        .sheetCard(.medium, handle: false)
    }

    private func status(_ c: SIPEngine.CallInfo) -> String {
        if !c.connected { return c.incoming ? "Incoming" : c.state }
        return engine.held.contains(c.id) ? "On hold" : "Active"
    }
}

/// The in-call keypad, full screen like the iPhone's: a back button, the digits you have sent, the keys and the end button.
struct DTMFScreen: View {
    @Environment(\.callGray) private var gray
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
                                .background(CallColors.surface(gray), in: Circle()).overlay(Circle().stroke(CallColors.border(gray), lineWidth: 1))
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
        .background(CallColors.bg(gray).ignoresSafeArea())
    }
}

struct TransferSheet: View {
    let call: SIPEngine.CallInfo
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var askFirst = false

    /// Same list as Android: the first five contacts matching what is typed (all of them while nothing is typed).
    private var matches: [Contact] {
        let t = number.trimmingCharacters(in: .whitespaces)
        return Array(contacts.contacts.filter { t.isEmpty || $0.name.localizedCaseInsensitiveContains(t) || $0.address.localizedCaseInsensitiveContains(t) }.prefix(5))
    }
    private func initials(_ name: String) -> String {
        let p = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return p.isEmpty ? "#" : String(p).uppercased()
    }

    var body: some View {
        AppNavStack {
            List {
                Section {
                    Picker("Kind", selection: $askFirst) { Text("Transfer now").tag(false); Text("Ask first").tag(true) }.pickerStyle(.segmented)
                } footer: {
                    Text(askFirst ? "Calls the new person with this caller on hold. Once they answer, you choose Complete transfer, or Cancel to go back to this caller."
                                  : "Sends this caller to the new person straight away. If nobody answers there, you are not on the line any more.")
                }
                .listRowBackground(Theme.surface)
                Section {
                    TextField("Extension or address", text: $number).plainInput()
                    Button(askFirst ? "Call to ask" : "Transfer") { go(number) }.disabled(number.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Theme.surface)
                if !matches.isEmpty {
                    Section("Contacts") {
                        ForEach(matches) { c in
                            Button { go(c.address) } label: {
                                HStack(spacing: 10) {
                                    Text(initials(c.name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.brand)
                                        .frame(width: 32, height: 32).background(Theme.brand.opacity(0.14), in: Circle())
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.name).foregroundStyle(Theme.text)
                                        Text(c.address).font(.caption).foregroundStyle(Theme.muted)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .sheetPage("Transfer to…")
        }
        .sheetCard(.mediumLarge, handle: false)
    }

    private func go(_ dest: String) {
        guard let acc = call.accountID ?? store.selected?.id else { return }
        if askFirst ? engine.startConsult(from: call.id, to: dest, account: acc) : engine.transfer(call.id, to: dest, account: acc) { dismiss() }
    }
}
