import SwiftUI

/// The round green call button used in Recents, Contacts and the contact page.
struct CallCircleButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.fill").font(.body).foregroundStyle(Theme.brand)
                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
        }.buttonStyle(.plain)
    }
}

/// Who a contact page is about: a saved contact, or just a number from the call log.
struct PersonTarget: Hashable, Identifiable {
    var name: String
    var address: String          // user@domain, or what was dialled
    var accountID: UUID?
    var id: String { address.lowercased() }
}

/// The right-hand side of the wide Recents and Contacts layouts.
struct PersonPane: View {
    let person: PersonTarget?
    var body: some View {
        if let p = person {
            AppNavStack { ContactDetailView(person: p).id(p) }
        } else {
            NothingSelected(title: "Nobody selected", systemImage: "person.crop.circle", hint: "Pick someone on the left.")
        }
    }
}

struct ContactDetailView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var callLog: CallLogStore
    let person: PersonTarget
    @State private var added = false

    private var saved: Bool { contacts.contacts.contains { $0.address.lowercased() == person.address.lowercased() } }
    private var favorite: Bool { contacts.contacts.contains { $0.favorite == true && $0.address.lowercased() == person.address.lowercased() } }
    private var account: Account? { store.dialAccount(person.accountID) }
    private var initials: String {
        let p = person.name.split(separator: " ").prefix(2).compactMap { $0.first }
        return person.name.first?.isLetter == true ? String(p).uppercased() : ""
    }

    var body: some View {
        ScrollView { VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.14))
                if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: 44)).foregroundStyle(Theme.muted) }
                else { Text(initials).font(.system(size: 44, weight: .semibold)).foregroundStyle(Theme.brand) }
            }.frame(width: 120, height: 120).padding(.top, 24)
            Text(person.name).font(.title.weight(.semibold)).foregroundStyle(Theme.text)

            HStack(spacing: 28) {
                action("phone.fill", "call") { if let a = account { engine.call(person.address, from: a.id) } }
                if person.address.contains("@") { action(favorite ? "star.fill" : "star", "favorite") { contacts.setFavorite(address: person.address, name: person.name, account: person.accountID, !favorite) } }
                if person.address.contains("@") {
                    action("message.fill", "message") {
                        guard let a = account else { return }
                        router.pendingThread = ThreadTarget(accountID: a.id, peer: person.address)
                        router.tab = .conversations
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SIP address").font(.footnote).foregroundStyle(Theme.muted)
                Text(person.address).foregroundStyle(Theme.text).textSelection(.enabled)
                if let a = account, store.accounts.count > 1 { Text("via \(a.titleWithUser)").font(.footnote).foregroundStyle(Theme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal)

            history

            if person.address.contains("@") && !saved {
                Button(added ? "Added" : "Add to contacts") {
                    if contacts.add(name: person.name, address: person.address, account: person.accountID) { added = true }
                }.disabled(added).foregroundStyle(Theme.brand)
            }
            Spacer(minLength: 20)
        }
        }
        .frame(maxWidth: .infinity)
        .mainBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Every call with this person, newest first, each with how it went and how it was encrypted.
    @ViewBuilder private var history: some View {
        let records = Array(callLog.records.filter { $0.isWith(person.address) }.prefix(60))
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Call history").font(.footnote).foregroundStyle(Theme.muted).padding(.bottom, 6)
                ForEach(records) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: r.direction == .outgoing ? "arrow.up.right" : "arrow.down.left").font(.caption2.weight(.semibold))
                            Text(r.whenText).font(.subheadline)
                            if r.security?.isEmpty == false { Image(systemName: r.security?.hasSuffix("verified") == true ? "checkmark.seal.fill" : "lock.fill").font(.caption).foregroundStyle(Theme.brand) }
                        }
                        .foregroundStyle(r.direction == .missed ? Theme.danger : Theme.text)
                        Text(historyStatus(r)).font(.caption).foregroundStyle(r.direction == .missed ? Theme.danger.opacity(0.85) : Theme.muted)
                        if let s = r.securityDescription { Text(s).font(.caption).foregroundStyle(Theme.muted) }
                    }
                    .padding(.vertical, 8)
                    if r.id != records.last?.id { Divider().overlay(Theme.border) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
        }
    }

    private func historyStatus(_ r: CallRecord) -> String {
        var parts: [String] = []
        if r.direction == .missed { parts.append("Missed") }
        else if r.duration > 0 { parts.append(String(format: "%d:%02d", r.duration / 60, r.duration % 60)) }
        else { parts.append(r.direction == .outgoing ? "Not answered" : "Declined") }
        if store.accounts.count > 1, let a = r.accountID.flatMap({ store.account($0) }) { parts.append(a.title) }
        return parts.joined(separator: " · ")
    }

    private func action(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.brand)
                    .frame(width: 58, height: 58).background(Theme.surface, in: Circle())
                Text(label).font(.footnote).foregroundStyle(Theme.text)
            }
        }.buttonStyle(.plain)
    }
}
