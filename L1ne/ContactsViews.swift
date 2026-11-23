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

    enum Sheet: String, Identifiable { case url, add; var id: String { rawValue } }

    private var shown: [Contact] {
        search.isEmpty ? contacts.contacts : contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { c in
                    Button {
                        if let a = (c.accountID.flatMap { store.account($0) } ?? store.selected) {
                            engine.call("sip:" + c.address, from: a.id)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                            Text(c.address).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in contacts.remove(idx.map { shown[$0].id }) }

                Section {} footer: {
                    Text("These contacts live only in L1ne. L1ne has no access to your phone's contacts: a contact is copied only when you pick it from the system picker or import a file or link. It never fetches a list by itself.")
                }
                .listRowBackground(Theme.surface)
            }
            .searchable(text: $search)
            .overlay { if contacts.contacts.isEmpty { ContentUnavailableView("No contacts", systemImage: "person.2", description: Text("Pick contacts that have a SIP address, import a vCard, or add one by hand.")) } }
            .l1neBackground()
            .navigationTitle("Contacts")
            .toolbar {
                ProfileToolbar()
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
    var initialURL = ""
    var done: (String) -> Void
    @State private var text = ""
    @State private var account: UUID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/contacts.vcf", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } footer: { Text("L1ne fetches this once, now. It does not check again unless you do this again.") }
                .listRowBackground(Theme.surface)
                if store.accounts.count > 1 {
                    Picker("Dial with", selection: Binding(get: { account ?? store.accounts[0].id }, set: { account = $0 })) {
                        ForEach(store.accounts) { Text($0.title).tag($0.id) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .l1neBackground()
            .navigationTitle("Import from a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Fetching…" : "Fetch") { fetch() }.disabled(busy || text.isEmpty)
                }
            }
            .onAppear { if text.isEmpty { text = initialURL } }
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
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("SIP address (user@domain)", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                if failed { Text("Enter a SIP address like 7201@pbx.example.com.").foregroundStyle(.red) }
            }
            .l1neBackground()
            .navigationTitle("Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if contacts.add(name: name, address: address, account: store.selected?.id) { dismiss() } else { failed = true }
                    }.disabled(address.isEmpty)
                }
            }
        }
    }
}
