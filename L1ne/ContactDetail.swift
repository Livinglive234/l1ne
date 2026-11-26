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
            EmptyState("Nobody selected", systemImage: "person.crop.circle", description: Text("Pick someone on the left."))
                .frame(maxWidth: .infinity, maxHeight: .infinity).mainBackground()
        }
    }
}

struct ContactDetailView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var router: AppRouter
    let person: PersonTarget
    @State private var added = false

    private var saved: Bool { contacts.contacts.contains { $0.address.lowercased() == person.address.lowercased() } }
    private var account: Account? { person.accountID.flatMap { store.account($0) } ?? store.selected }
    private var initials: String {
        let p = person.name.split(separator: " ").prefix(2).compactMap { $0.first }
        return person.name.first?.isLetter == true ? String(p).uppercased() : ""
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.14))
                if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: 44)).foregroundStyle(Theme.muted) }
                else { Text(initials).font(.system(size: 44, weight: .semibold)).foregroundStyle(Theme.brand) }
            }.frame(width: 120, height: 120).padding(.top, 24)
            Text(person.name).font(.title.weight(.semibold)).foregroundStyle(Theme.text)

            HStack(spacing: 28) {
                action("phone.fill", "call") { if let a = account { engine.call(person.address.contains("@") ? "sip:" + person.address : person.address, from: a.id) } }
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
                if let a = account, store.accounts.count > 1 { Text("via \(a.title)").font(.footnote).foregroundStyle(Theme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal)

            if person.address.contains("@") && !saved {
                Button(added ? "Added" : "Add to contacts") {
                    if contacts.add(name: person.name, address: person.address, account: person.accountID) { added = true }
                }.disabled(added).foregroundStyle(Theme.brand)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .mainBackground()
        .navigationBarTitleDisplayMode(.inline)
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
