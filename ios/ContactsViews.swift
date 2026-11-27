import SwiftUI
import UniformTypeIdentifiers

struct ContactsView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var dirs: DirectoryStore
    @State private var search = ""
    @State private var sheet: Sheet?
    @State private var importing = false
    @State private var picking = false
    @State private var message: String?
    @State private var detail: PersonTarget?

    enum Sheet: String, Identifiable { case url, add; var id: String { rawValue } }

    private var sections: [(String, [Contact])] {
        let g = Dictionary(grouping: shown) { c -> String in
            let f = c.name.first.map { String($0).uppercased() } ?? "#"
            return f.rangeOfCharacter(from: .letters) != nil ? f : "#"
        }
        return g.keys.sorted { $0 == "#" ? false : ($1 == "#" ? true : $0 < $1) }.map { ($0, g[$0]!) }
    }

    private func initials(_ name: String) -> String {
        let p = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return p.isEmpty ? "#" : String(p).uppercased()
    }

    private var shown: [Contact] {
        search.isEmpty ? contacts.contacts : contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search)
        }
    }

    @Environment(\.isWide) private var wide

    var body: some View {
        ListAndDetail { listStack } detail: { PersonPane(person: detail) }
    }

    private var listStack: some View {
        AppNavStack {
            List {
                ForEach(sections, id: \.0) { letter, items in
                    Section {
                        ForEach(items) { c in
                            HStack(spacing: 14) {
                                Button { detail = PersonTarget(name: c.name, address: c.address, accountID: c.accountID) } label: {
                                    HStack(spacing: 14) {
                                        Text(initials(c.name))
                                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.brand)
                                            .frame(width: 48, height: 48)
                                            .background(Theme.brand.opacity(0.14), in: Circle())
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.name).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                                            Text(c.address).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                    }
                                }.buttonStyle(.plain)
                                CallCircleButton {
                                    if let a = store.dialAccount(c.accountID) {
                                        engine.call(c.address, from: a.id)
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.border)
                        }
                        .onDelete { idx in contacts.remove(idx.map { items[$0].id }) }
                    } header: {
                        Text(letter).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.brand)
                    }
                }
            }
            .listStyle(.plain).hideScrollBackground()
            .navDestination(item: $detail, unless: wide) { ContactDetailView(person: $0) }
            .searchable(text: $search)
            .overlay { if contacts.contacts.isEmpty { EmptyState("No contacts", systemImage: "person.2", description: Text("Pick contacts that have a SIP address, import a vCard, or add one by hand.")) } }
            .mainBackground()
            .navigationTitle("Contacts")
            .profileToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Menu {
                    Button("Import from Contacts…", systemImage: "person.crop.circle.badge.plus") { picking = true }
                    Button("Import vCard file…", systemImage: "doc") { importing = true }
                    if dirs.directoryEnabled {
                        Text("Import from a link is replaced by directory sync")
                    } else {
                        Button("Import from a link…", systemImage: "link") { sheet = .url }
                    }
                    Button("Add contact…", systemImage: "person.badge.plus") { sheet = .add }
                    if !contacts.contacts.isEmpty {
                        Button("Remove all", systemImage: "trash", role: .destructive) { contacts.removeAll() }
                    }
                } label: { Image(systemName: "plus") } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.vCard, .plainText]) { r in
                guard case .success(let url) = r else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    message = summary(contacts.merge(VCard.parse(text), account: store.selected?.id, source: "file"))
                } else { message = "Couldn't read that file." }
            }
            .sheet(isPresented: $picking) {
                SystemContactPicker { r in
                    picking = false
                    message = summary(contacts.merge(r, account: store.selected?.id, source: "picker"))
                }.ignoresSafeArea()
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .url: ImportURLSheet(done: { message = $0 })
                case .add: AddContactSheet()
                }
            }
            .alert("Import", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
        }
    }

    private func summary(_ s: ContactsStore.ImportSummary) -> String {
        "\(s.added) added, \(s.updated) renamed, \(s.kept) already there, \(s.skipped) skipped (no SIP address)."
    }
}

struct ImportURLSheet: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    var done: (String) -> Void
    @State private var text = ""
    @State private var account: UUID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        AppNavStack {
            Form {
                Section {
                    TextField("https://…/contacts.vcf", text: $text)
                        .plainInput(.URL)
                } footer: { Text("L1ne fetches this once, now. It does not check again unless you do this again.") }
                .listRowBackground(Theme.surface)
                if store.accounts.count > 1 {
                    Picker("Dial with", selection: Binding(get: { account ?? store.accounts[0].id }, set: { account = $0 })) {
                        ForEach(store.accounts) { Text($0.titleWithUser).tag($0.id) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .sheetPage("Import from a link")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Fetching…" : "Fetch") { fetch() }.disabled(busy || text.isEmpty)
                }
            }
        }
    }

    private func fetch() {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { error = "That isn't a link."; return }
        busy = true; error = nil
        Task {
            do {
                let r = try await ContactsStore.fetchVCard(from: url)
                let s = contacts.merge(r, account: account ?? store.selected?.id)
                done("\(s.added) added, \(s.updated) renamed, \(s.kept) already there, \(s.skipped) skipped (no SIP address).")
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct AddContactSheet: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var failed = false

    var body: some View {
        AppNavStack {
            Form {
                TextField("Name", text: $name)
                TextField("SIP address (user@domain)", text: $address)
                    .plainInput(.emailAddress)
                if failed { Text("Enter a SIP address like 7201@pbx.example.com.").foregroundStyle(.red) }
            }
            .sheetPage("Add contact")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if contacts.add(name: name, address: address, account: store.selected?.id) { dismiss() } else { failed = true }
                    }.disabled(address.isEmpty)
                }
            }
        }
    }
}
