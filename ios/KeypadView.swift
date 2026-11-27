import SwiftUI

/// Phone-keypad letters, so "5673" finds "Jordan": each letter maps to the digit it sits on.
enum T9 {
    static let letters: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (d, ls) in ["2": "abc", "3": "def", "4": "ghi", "5": "jkl", "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"] {
            for l in ls { m[l] = Character(d) }
        }
        return m
    }()

    static func digits(_ text: String) -> String {
        String(text.lowercased().folding(options: .diacriticInsensitive, locale: nil).compactMap { c -> Character? in
            if c.isNumber { return c }
            return letters[c]
        })
    }

    /// True when the typed digits start a word of the name, start the whole name, or start the extension.
    static func matches(_ typed: String, name: String, address: String) -> Bool {
        guard !typed.isEmpty, typed.allSatisfy({ $0.isNumber }) else { return false }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { digits(String($0)) }
        if words.contains(where: { $0.hasPrefix(typed) }) { return true }
        if digits(name.filter { $0.isLetter || $0.isNumber }).hasPrefix(typed) { return true }
        let user = address.split(separator: "@").first.map(String.init) ?? address
        return user.hasPrefix(typed)
    }
}

private struct KeyPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.brand.opacity(0.35) : Theme.surface, in: Circle())
            .overlay(Circle().stroke(configuration.isPressed ? Theme.brand : Theme.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct KeypadView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var callLog: CallLogStore
    @Environment(\.isWide) private var wide       // an iPad, or the iPhone Duo opened: keypad on the left, matches and recent calls on the right
    @State private var number = ""
    @State private var plusTyped = false

    private let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]
    @State private var size: CGFloat = 76        // shrinks when the screen is short (the iPhone Duo's wide inner screen), so the keypad always fits
    private func fitKeys(to height: CGFloat) {
        guard height > 0 else { return }
        let s = min(height > 900 ? 92 : 76, max(52, ((height - (wide ? 144 : 256)) / 5).rounded(.down)))      // 256 = number box, suggestions, gaps (144 without the suggestions, which move to the side)
        if s != size { size = s }
    }

    private var account: Account? { store.selected }

    /// Contacts whose name (as letters on the keys) or extension starts with what is typed.
    private var matches: [Contact] { contacts.contacts.filter { T9.matches(number, name: $0.name, address: $0.address) } }
    private var suggestions: [Contact] { Array(matches.prefix(2)) }

    var body: some View {
        AppNavStack {
            Group {
                if wide {
                    HStack(spacing: 0) {
                        pad.frame(maxWidth: 480)
                        Divider()
                        sidePanel
                    }
                } else { pad }
            }
            .mainBackground()
            .task(id: router.pendingDial) { if let d = router.pendingDial { number = d; router.pendingDial = nil } }
            .profileToolbar()
            .toolbar {
                ToolbarItem(placement: .principal) { lineMenu }      // the line picker sits in the top bar
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var pad: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottom) {
                    Color.clear                       // always reserves the space, so the keys never move
                    if !wide { suggestionList }
                }
                .frame(height: wide ? 0 : 112)
                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(height: 52).padding(.horizontal, 24)
                Spacer(minLength: 8)
                VStack(spacing: 14) {
                    ForEach(keys, id: \.self.first!.0) { row in
                        HStack(spacing: 20) { ForEach(row, id: \.0) { key($0.0, $0.1) } }
                    }
                    HStack(spacing: 22) {
                        voicemailButton
                        Button {
                            if let a = account, engine.call(number, from: a.id) { number = "" }
                        } label: {
                            Image(systemName: "phone.fill").font(.system(size: 30))
                                .frame(width: size, height: size)
                                .background(number.isEmpty || account == nil ? Theme.brandDim.opacity(0.45) : Theme.brand, in: Circle())
                                .foregroundStyle(Theme.onBrand)
                        }.buttonStyle(.plain).disabled(number.isEmpty || account == nil)
                        Image(systemName: "delete.left").font(.title2).foregroundStyle(Theme.muted)
                            .frame(width: size, height: size).contentShape(Circle())
                            .opacity(number.isEmpty ? 0 : 1)
                            .onTapGesture { if !number.isEmpty { number.removeLast() } }
                            .onLongPressGesture(minimumDuration: 0.5) { number = "" }
                    }
                }
                if store.accounts.isEmpty {
                    Text("Add an account first").font(.footnote).foregroundStyle(Theme.muted).padding(.top, 8)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in
                Color.clear.onAppear { fitKeys(to: g.size.height) }.onChangeCompat(of: g.size.height) { _, h in fitKeys(to: h) }
            })
    }

    /// The wide layout's right side: contacts matching what is typed, or recent calls while the number is empty.
    private var sidePanel: some View {
        List {
            if number.isEmpty {
                Section("Recent calls") {
                    ForEach(callLog.records.prefix(20)) { r in
                        sideRow(name: contacts.displayName(forPeer: r.peer), detail: r.peer, fill: dialString(address: r.peer)) {
                            dial(dialString(address: r.peer), accountID: r.accountID)
                        }
                    }
                }
            } else {
                Section("Matching contacts") {
                    ForEach(matches) { c in
                        sideRow(name: c.name, detail: c.address, fill: dialString(for: c)) {
                            dial(dialString(for: c), accountID: c.accountID)
                        }
                    }
                }
            }
        }
        .listStyle(.plain).hideScrollBackground()
        .overlay {
            if number.isEmpty ? callLog.records.isEmpty : matches.isEmpty {
                EmptyState(number.isEmpty ? "No recent calls" : "No matches", systemImage: number.isEmpty ? "clock" : "person.crop.circle.badge.questionmark",
                           description: Text(number.isEmpty ? "Calls you make or receive show up here." : "Keep typing, or press call."))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sideRow(name: String, detail: String, fill: String, call: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button { number = fill } label: {         // tapping fills the number in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            CallCircleButton(action: call)
        }
        .listRowBackground(Color.clear).listRowSeparatorTint(Theme.border)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
    }

    /// Calls `s` from the account tied to `accountID` (or the selected one) and clears the number once the call is placed.
    private func dial(_ s: String, accountID: UUID?) {
        if let a = store.dialAccount(accountID), engine.call(s, from: a.id) { number = "" }
    }

    private func dialString(address: String) -> String {
        if let a = account, address.lowercased().hasSuffix("@" + a.domain.lowercased()) { return String(address.split(separator: "@").first ?? "") }
        return address.contains("@") ? "sip:" + address : address
    }

    /// Which line the call goes out on: a menu in the top bar, only when there is more than one account.
    @ViewBuilder private var lineMenu: some View {
        if store.accounts.count > 1 {
            Menu {
                ForEach(store.accounts) { a in
                    Button { store.select(a.id) } label: {
                        if store.selected?.id == a.id { Label(a.titleWithUser, systemImage: "checkmark") } else { Text(a.titleWithUser) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.selected?.titleWithUser ?? "Line").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            }
        }       // with one account there is nothing to choose, so nothing is shown
    }

    /// Contacts whose name (typed on the letters of the keys) or extension matches what has been dialled so far.
    @ViewBuilder private var suggestionList: some View {
        let list = suggestions
        if !list.isEmpty {
            VStack(spacing: 0) {
                ForEach(list) { c in
                    HStack(spacing: 0) {
                        Button { number = dialString(for: c) } label: {        // the name fills in the number
                            HStack(spacing: 12) {
                                Text(String(c.name.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased())
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.brand)
                                    .frame(width: 36, height: 36).background(Theme.brand.opacity(0.14), in: Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(c.address).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 14).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button {                                                  // the phone glyph calls right away
                            dial(dialString(for: c), accountID: c.accountID)
                        } label: {
                            Image(systemName: "phone.fill").font(.body).foregroundStyle(Theme.brand)
                                .frame(width: 52, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if c.id != list.last?.id { Divider().overlay(Theme.border).padding(.leading, 62) }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20).padding(.bottom, 6)
        }
    }

    /// The extension when the contact is on the selected account's server, otherwise the full address.
    private func dialString(for c: Contact) -> String {
        if let a = account, c.address.lowercased().hasSuffix("@" + a.domain.lowercased()) { return c.user }
        return "sip:" + c.address
    }

    private func key(_ digit: String, _ sub: String) -> some View {
        Button {
            if digit == "0", plusTyped { plusTyped = false } else { number += digit }
        } label: {
            VStack(spacing: -2) {
                Text(digit).font(.system(size: 34, weight: .regular))
                if !sub.isEmpty { Text(sub).font(.system(size: 11, weight: .bold)).tracking(2.5).foregroundStyle(Theme.muted) }
            }
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(KeyPress())
        .simultaneousGesture(digit == "0" ? LongPressGesture(minimumDuration: 0.45).onEnded { _ in plusTyped = true; number += "+" } : nil)
    }

    @ViewBuilder private var voicemailButton: some View {
        if settings.showKeypadVoicemail, let a = account, !a.voicemailURI.isEmpty {
            Button { engine.callVoicemail(a.id) } label: {
                Image(systemName: "recordingtape").font(.title2)
                    .frame(width: size, height: size).foregroundStyle(Theme.brand)
                    .overlay(alignment: .topTrailing) {
                        if let n = engine.voicemail[a.id], n > 0 {
                            Text("\(n)").font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.danger, in: Capsule())
                                .offset(x: -8, y: 8)
                        }
                    }
            }.buttonStyle(.plain)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}
