import SwiftUI

/// New account: the short form (username, password, domain, display name, transport, advanced). Existing account:
/// "Manage account" with everything.
struct AccountEditor: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    /// For a new account: hand it to the welcome screen's login check instead of saving it directly (an account the PBX won't register is never kept).
    var onSubmit: ((Account, String) -> Void)? = nil
    @State private var secret = ""
    @State private var turnSecret = ""
    @State private var confirmRemove = false
    @State private var copied = false

    private var isNew: Bool { store.account(account.id) == nil }

    @ViewBuilder private var messagingStatus: some View {
        switch engine.messagingCheck[account.id] ?? .unknown {
        case .working: Label("Delivers texts", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.brand)
        case .notDelivered: Label("Doesn't deliver", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .checking: Text("Checking…").foregroundStyle(Theme.muted)
        case .unknown: Text(engine.messagingNote[account.id] != nil ? "Not supported" : "Not checked").foregroundStyle(Theme.muted)
        }
    }

    private func text(_ title: String, _ binding: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
    }
    private var transport: Binding<Account.Transport> {
        Binding(get: { account.transport }, set: { account.changeTransport(to: $0) })
    }
    private var canLogin: Bool { !account.username.isEmpty && !secret.isEmpty && !account.domain.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        AppNavStack {
            Group { if isNew { newAccountForm } else { editForm } }
                .l1neBackground()
                .navigationTitle(isNew ? "Use a SIP account" : (account.title.isEmpty ? "Account" : account.title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if !isNew { Button("Save") { save() }.disabled(account.domain.isEmpty || account.username.isEmpty) }
                    }
                }
                .confirmationDialog("Remove \(account.title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove account", role: .destructive) {
                        engine.unregister(account.id); MessageStore.shared.removeAccount(account.id)
                        CallLogStore.shared.removeAccount(account.id); store.remove(account.id); dismiss()
                    }
                } message: { Text("Its chats and call history on this phone are deleted too.") }
                .onAppear { secret = ""; turnSecret = "" }
        }
    }

    // MARK: new account: only what is needed to sign in

    private var newAccountForm: some View {
        Form {
            Section {
                text("Username / extension", $account.username)
                SecureField("Password", text: $secret)
                text("Domain (e.g. pbx.example.com)", $account.domain, keyboard: .URL)
                TextField("Display name", text: $account.displayName)
                Picker("Transport", selection: transport) {
                    ForEach(Account.Transport.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
            } footer: {
                Text("Add a port after the domain if your server doesn't use the standard one (5061 for TLS, 5060 for UDP and TCP), like pbx.example.com:5080.")
            }
            .listRowBackground(Theme.surface)
            Section("Advanced options") {
                text("Authentication ID (if different)", $account.authUser)
                text("Registrar URI", $account.registrarURI, keyboard: .URL)
                text("Outbound SIP proxy URI", $account.outboundProxy, keyboard: .URL)
            }
            .listRowBackground(Theme.surface)
            Section {
                Button { save() } label: { Text("Login").fontWeight(.semibold).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Theme.brand).foregroundStyle(Theme.onBrand)
                    .controlSize(.large).disabled(!canLogin)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: existing account: everything

    private var editForm: some View {
        Form {
            Section("Details") {
                if !account.username.isEmpty && !account.domain.isEmpty {
                    HStack {
                        Text("SIP address").foregroundStyle(Theme.muted)
                        Text(account.sipAddress).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        Button { UIPasteboard.general.string = account.sipAddress; copied = true } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(Theme.brand)
                        }.buttonStyle(.plain)
                    }
                }
                TextField("Label", text: $account.label)
                TextField("Display name (shown to people you call)", text: $account.displayName)
                Picker("International prefix", selection: $account.intlPrefix) {
                    Text("No country code").tag("")
                    ForEach(Countries.all, id: \.code) { Text("\($0.name) (+\($0.code))").tag($0.code) }
                    if !account.intlPrefix.isEmpty && Countries.name(for: account.intlPrefix) == nil {
                        Text("+\(account.intlPrefix)").tag(account.intlPrefix)
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("Connected", isOn: $account.enabled)
            } footer: {
                Text(account.enabled ? "This account is online, everybody can call you." : "This account is off. Calls to it won't ring here.")
            }
            .listRowBackground(Theme.surface)

            Section("Server") {
                text("Server (e.g. pbx.example.com)", $account.domain, keyboard: .URL)
                Picker("Transport", selection: transport) {
                    ForEach(Account.Transport.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                TextField("Port", value: $account.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                text("Registrar URI (optional)", $account.registrarURI, keyboard: .URL)
                text("Outbound SIP proxy URI (optional)", $account.outboundProxy, keyboard: .URL)
                HStack {
                    Text("Expire (seconds)")
                    Spacer()
                    TextField("3600", value: $account.expires, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                }
            }
            .listRowBackground(Theme.surface)

            Section("Login") {
                text("Username / extension", $account.username)
                SecureField("Secret (leave empty to keep)", text: $secret)
                text("Authentication ID (if different)", $account.authUser)
            }
            .listRowBackground(Theme.surface)

            Section {
                text("Strip prefix", $account.dialStripPrefix)
                text("Add prefix", $account.dialAddPrefix)
                Toggle("Format phone numbers using international prefix", isOn: $account.formatWithPrefix)
                Toggle("Replace + by 00 when formatting phone numbers", isOn: $account.plusTo00)
            } header: { Text("Dialling") } footer: {
                Text("Extensions and codes like *97 are never changed; only long phone numbers get the country code.")
            }
            .listRowBackground(Theme.surface)

            Section {
                HStack {
                    Text("Server")
                    Spacer()
                    messagingStatus
                }
                Button("Check messaging") { engine.messagingNote[account.id] = nil; engine.messagingCheck[account.id] = .unknown; engine.checkMessaging(account.id) }
                    .disabled(engine.registration[account.id] != "Registered" || engine.messagingCheck[account.id] == .checking)
            } header: { Text("Messaging") } footer: {
                Text("Sends one hidden test text to this line itself and sees whether the server delivers it back. Nothing goes to anyone else and it isn't shown as a message. Some servers treat a text to an extension as a call to it, so this line may ring once.")
            }
            .listRowBackground(Theme.surface)

            Section {
                text("Voicemail number or address", $account.voicemailURI)
                Toggle("Message waiting indicator (MWI)", isOn: $account.mwiEnabled)
            } header: { Text("Voicemail") } footer: {
                Text("What to dial to reach your voicemail. PBXes differ: *97 on FreePBX, 8500 or *86 on others, or a full address like sip:voicemail@example.com. Leave it empty to hide the voicemail button. The indicator shows how many new messages the server reports.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker("Media encryption", selection: $account.media) {
                    Text("None").tag(Account.Media.none)
                    Text("SRTP").tag(Account.Media.srtpSDES)
                    Text("DTLS-SRTP").tag(Account.Media.srtpDTLS)
                }
                Toggle("Media encryption mandatory", isOn: $account.mediaMandatory).disabled(account.media == .none)
            } header: { Text("Media") } footer: {
                Text(account.media == .srtpSDES && account.transport != .tls
                     ? "SRTP sends its keys inside the call setup, so it only works over TLS. With UDP or TCP choose DTLS-SRTP or None."
                     : "SRTP sends its keys inside the call setup, so it needs TLS. DTLS-SRTP negotiates keys in the media path.")
                    .foregroundStyle(account.media == .srtpSDES && account.transport != .tls ? Theme.danger : Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                text("STUN / TURN server (host:port)", $account.stunServer)
                Toggle("Enable ICE", isOn: $account.iceEnabled)
                Toggle("Enable TURN", isOn: $account.turnEnabled)
                if account.turnEnabled {
                    text("TURN username", $account.turnUser)
                    SecureField("TURN password", text: $turnSecret)
                }
            } header: { Text("NAT policy") } footer: {
                Text("L1ne uses one STUN server for all accounts: the first account that sets one.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Button("Remove account", role: .destructive) { confirmRemove = true }
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func save() {
        if isNew { account.finishNewAccount() }
        if isNew, let onSubmit { onSubmit(account, secret); dismiss(); return }
        store.save(account, secret: secret.isEmpty ? nil : secret, turnSecret: turnSecret.isEmpty ? nil : turnSecret)
        engine.register(account, secret: store.secret(account.id))
        dismiss()
    }
}
