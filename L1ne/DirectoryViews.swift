import SwiftUI

struct DirectorySourcesView: View {
    @EnvironmentObject var dirs: DirectoryStore
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var accounts: AccountStore
    @ObservedObject private var sync = DirectorySync.shared
    @State private var editing: DirectorySource?
    @State private var pending: DirectorySource?        // waiting for "replace link imports?"
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Keeps your contacts in step with a vCard link (like the one in a Linphone-style setup file), a CardDAV address book or an LDAP directory. While a CardDAV or LDAP directory is on it replaces the vCard link, and contacts that came from the link are removed. Contacts you typed in, or picked from your phone, are never touched.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                ForEach(dirs.sources) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button { editing = s } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).foregroundStyle(Theme.text)
                                    Text("\(s.kind == .ldap ? "LDAP" : (s.kind == .carddav ? "CardDAV" : "vCard link")) · \(pbxName(s))").font(.footnote).foregroundStyle(Theme.muted)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Toggle("", isOn: Binding(get: { s.enabled }, set: { setEnabled(s, $0) })).labelsHidden()
                        }
                        HStack {
                            Text(status(s)).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                            Spacer()
                            if sync.running.contains(s.id) { ProgressView() }
                            else { Button("Sync now") { Task { message = await sync.sync(s.id) } }.font(.caption).disabled(!s.enabled) }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .onDelete { idx in
                    for i in idx {
                        let s = dirs.sources[i]
                        contacts.delete(source: s.tag)
                        dirs.remove(s.id)
                    }
                    DirectorySync.shared.scheduleBackground()
                }
            } header: { Text("Directories") }
            .listRowBackground(Theme.surface)

            Section {
                Menu {
                    Button("CardDAV address book…", systemImage: "book.closed") { editing = DirectorySource(kind: .carddav) }
                    Button("LDAP server…", systemImage: "server.rack") { editing = DirectorySource(kind: .ldap) }
                    Button("vCard link…", systemImage: "link") { var l = DirectorySource(kind: .vcardLink); l.interval = .onOpen; editing = l }
                } label: { Label("Add directory", systemImage: "plus.circle.fill") }
            }
            .listRowBackground(Theme.surface)
        }
        .l1nePage("Contacts sync")
        .sheet(item: $editing) { src in
            DirectoryEditor(source: src) { saved in editing = nil; if saved.enabled { activate(saved) } }
        }
        .confirmationDialog("Replace imported contacts?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Replace and sync", role: .destructive) {
                if let p = pending {
                    contacts.removeLinkImports()
                    for l in dirs.sources where !l.isDirectory { contacts.delete(source: l.tag); dirs.update(l.id) { $0.enabled = false } }
                    startSync(p)
                }
                pending = nil
            }
            Button("Cancel", role: .cancel) {
                if let p = pending { dirs.update(p.id) { $0.enabled = false } }
                pending = nil
            }
        } message: { Text("Turning on a directory replaces importing from a vCard link. The contacts you imported from a link are removed and the directory's contacts take their place.") }
        .alert("Sync", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    /// The PBX a directory belongs to: its account's name, else the host the link points at.
    private func pbxName(_ s: DirectorySource) -> String {
        if let id = s.accountID, let a = accounts.accounts.first(where: { $0.id == id }) { return a.title }
        return s.kind == .ldap ? s.host : (URL(string: s.url)?.host ?? s.url)
    }

    private func status(_ s: DirectorySource) -> String {
        guard s.enabled else { return "Off" }
        let every = s.interval.label
        if let r = s.lastResult { return "\(every) · \(s.lastSync.map { "Last sync \($0.formatted(date: .abbreviated, time: .shortened)): " } ?? "")\(r)" }
        return "\(every) · not synced yet"
    }

    private func setEnabled(_ s: DirectorySource, _ on: Bool) {
        if on && !s.isDirectory && dirs.directoryEnabled {
            message = "A CardDAV or LDAP directory is on, and it replaces the vCard link. Turn the directory off first."
            return
        }
        dirs.update(s.id) { $0.enabled = on }
        if on, let fresh = dirs.sources.first(where: { $0.id == s.id }) { activate(fresh) } else { DirectorySync.shared.scheduleBackground() }
    }

    /// Switching on a directory replaces the vCard link: ask before removing what the link brought.
    private func activate(_ s: DirectorySource) {
        guard s.isDirectory else { startSync(s); return }
        let linkSources = dirs.sources.filter { !$0.isDirectory && $0.enabled }
        if contacts.hasLinkImports || !linkSources.isEmpty { pending = s } else { startSync(s) }
    }

    private func startSync(_ s: DirectorySource) {
        DirectorySync.shared.scheduleBackground()
        Task { message = await sync.sync(s.id) }
    }
}

struct DirectoryEditor: View {
    @EnvironmentObject var dirs: DirectoryStore
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State var source: DirectorySource
    var onSave: (DirectorySource) -> Void
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?

    private var isNew: Bool { !dirs.sources.contains { $0.id == source.id } }
    private func field(_ title: String, _ b: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: b).plainInput(keyboard)
    }

    var body: some View {
        AppNavStack {
            Form {
                Section("Name") { TextField(source.kind == .ldap ? "e.g. Company directory" : "e.g. Contacts", text: $source.name) }
                .listRowBackground(Theme.surface)

                if source.kind == .vcardLink {
                    Section {
                        field("https://…/contacts.vcf", $source.url, keyboard: .URL)
                    } header: { Text("vCard link") } footer: {
                        Text("A link to a .vcf file with your contacts, like the contact link a PBX setup file brings. L1ne keeps your contacts in step with it. Only entries with a SIP address are kept.")
                    }
                    .listRowBackground(Theme.surface)
                } else if source.kind == .carddav {
                    Section {
                        field("Address book URL", $source.url, keyboard: .URL)
                        field("Username", $source.username)
                        SecureField(isNew ? "Password" : "Password (leave empty to keep)", text: $password)
                    } header: { Text("CardDAV") } footer: {
                        Text("Use the address book's own URL, for example https://server/user/contacts/. HTTPS is strongly recommended.")
                    }
                    .listRowBackground(Theme.surface)
                } else {
                    Section("Server") {
                        field("Host", $source.host, keyboard: .URL)
                        TextField("Port", value: $source.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                        Picker("Security", selection: $source.security) {
                            Text("LDAPS (encrypted)").tag(LDAPSettings.Security.ldaps)
                            Text("None (password in the clear)").tag(LDAPSettings.Security.none)
                        }
                        .onChangeCompat(of: source.security) { _, new in
                            if new == .ldaps && source.port == 389 { source.port = 636 }
                            if new == .none && source.port == 636 { source.port = 389 }
                        }
                    }
                    .listRowBackground(Theme.surface)
                    Section {
                        field("Bind DN (empty = anonymous)", $source.bindDN)
                        SecureField(isNew ? "Password" : "Password (leave empty to keep)", text: $password)
                    } header: { Text("Sign in") }
                    .listRowBackground(Theme.surface)
                    Section {
                        field("Base DN (e.g. ou=people,dc=example,dc=com)", $source.baseDN)
                        field("Filter", $source.filter)
                    } header: { Text("Search") }
                    .listRowBackground(Theme.surface)
                    Section {
                        field("Name attribute", $source.nameAttr)
                        field("SIP address attribute", $source.sipAttr)
                        Toggle("Use phone numbers as extensions", isOn: $source.phoneAsExtension)
                        if source.phoneAsExtension { field("Phone attribute", $source.phoneAttr) }
                    } header: { Text("Attributes") } footer: {
                        Text("Entries need a SIP address (sip:name@domain, name@domain, or a bare extension). With the switch on, entries without one use their phone number as an extension on the account's server.")
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    if store.accounts.count > 0 {
                        Picker("Dial with", selection: Binding(get: { source.accountID ?? store.selected?.id }, set: { source.accountID = $0 })) {
                            ForEach(store.accounts) { Text($0.titleWithUser).tag(Optional($0.id)) }
                        }
                    }
                    Picker("Sync", selection: $source.interval) {
                        ForEach(SyncInterval.allCases) { Text($0.label).tag($0) }
                    }
                } header: { Text("Sync") } footer: {
                    Text("L1ne syncs while it's open. In the background iOS decides when to allow it, often later than asked. \"Manual only\" never syncs by itself.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Button(testing ? "Testing…" : "Test connection") { runTest() }.disabled(testing || !canTest)
                    if let r = testResult { Text(r).font(.footnote).foregroundStyle(r.hasPrefix("Works") ? Theme.brand : Theme.danger) }
                }
                .listRowBackground(Theme.surface)
            }
            .sheetPage(isNew ? (source.kind == .vcardLink ? "Add vCard link" : "Add directory") : source.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if source.accountID == nil { source.accountID = store.selected?.id }
                        dirs.save(source, password: password.isEmpty ? nil : password)
                        onSave(source)
                    }.disabled(!canTest)
                }
            }
        }
    }

    private var canTest: Bool { source.kind == .ldap ? (!source.host.isEmpty && !source.baseDN.isEmpty) : !source.url.isEmpty }

    private func runTest() {
        testing = true; testResult = nil
        let pw = password.isEmpty ? dirs.password(source.id) : password
        Task { testResult = await DirectorySync.shared.test(source, password: pw); testing = false }
    }
}
