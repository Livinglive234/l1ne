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
    @State private var number = ""
    @State private var plusTyped = false

    private let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]
    private let size: CGFloat = 76

    private var account: Account? { store.selected }

    private var suggestions: [Contact] {
        Array(contacts.contacts.filter { T9.matches(number, name: $0.name, address: $0.address) }.prefix(2))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottom) {
                    Color.clear                       // always reserves the space, so the keys never move
                    suggestionList
                }
                .frame(height: 112)
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
            .mainBackground()
            .task(id: router.pendingDial) { if let d = router.pendingDial { number = d; router.pendingDial = nil } }
            .toolbar {
                ProfileToolbar()
                ToolbarItem(placement: .principal) { lineMenu }      // the line picker sits in the top bar
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Which line the call goes out on: a menu in the top bar, only when there is more than one account.
    @ViewBuilder private var lineMenu: some View {
        if store.accounts.count > 1 {
            Menu {
                ForEach(store.accounts) { a in
                    Button { store.select(a.id) } label: {
                        if store.selected?.id == a.id { Label(a.title, systemImage: "checkmark") } else { Text(a.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.selected?.title ?? "Line").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            }
        }       // with one account there is nothing to choose, so nothing is shown
    }

    /// Contacts whose name (typed on the letters of the keys) or extension matches what has been dialled so far.
    @ViewBuilder private var suggestionList: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(suggestions) { c in
                    Button {
                        if let a = c.accountID.flatMap({ store.account($0) }) ?? account, engine.call(dialString(for: c), from: a.id) { number = "" }
                    } label: {
                        HStack(spacing: 12) {
                            Text(String(c.name.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased())
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.brand)
                                .frame(width: 36, height: 36).background(Theme.brand.opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(c.address).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "phone.fill").font(.body).foregroundStyle(Theme.brand)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if c.id != suggestions.last?.id { Divider().overlay(Theme.border).padding(.leading, 62) }
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
