import SwiftUI

/// What you see before any account exists: sign in with the three things a PBX admin hands out, or scan their QR code
/// or open their setup link. Everything it does goes through the same Account / AccountStore / provisioning code as
/// Settings → Accounts, so there is only one way an account gets made.
struct WelcomeView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @Binding var signingIn: Bool

    @State private var server = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var reveal = false
    @State private var transport = Account.Transport.tls
    @State private var pending: UUID?
    @State private var error: String?
    @State private var showQR = false
    @State private var showLink = false
    @State private var showManual = false
    @State private var showHelp = false
    @FocusState private var focus: Field?
    private enum Field { case server, user, name, pass }

    private var canLogin: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        header
                        Spacer(minLength: 4)
                        VStack(alignment: .leading, spacing: 10) {
                            field("Server") {
                                TextField("pbx.example.com", text: $server)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    .focused($focus, equals: .server).submitLabel(.next).onSubmit { focus = .user }
                            }
                            field("Username or extension") {
                                TextField("Username", text: $username)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .name }
                            }
                            field("Display name (optional)") {
                                TextField("Shown to people you call", text: $displayName)
                                    .textInputAutocapitalization(.words)
                                    .focused($focus, equals: .name).submitLabel(.next).onSubmit { focus = .pass }
                            }
                            field("Password") {
                                HStack {
                                    Group {
                                        if reveal { TextField("Password", text: $password) } else { SecureField("Password", text: $password) }
                                    }
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($focus, equals: .pass).submitLabel(.go).onSubmit { if canLogin { login() } }
                                    Button { reveal.toggle() } label: {
                                        Image(systemName: reveal ? "eye" : "eye.slash").foregroundStyle(Theme.muted)
                                    }.buttonStyle(.plain).accessibilityLabel(reveal ? "Hide password" : "Show password")
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Transport").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                                Picker("Transport", selection: $transport) {
                                    ForEach(Account.Transport.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        Spacer(minLength: 4)
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                        }
                        Button(action: login) {
                            HStack(spacing: 10) {
                                if pending != nil { ProgressView().tint(Theme.onBrand) }
                                Text(pending != nil ? "Signing in…" : "Login").font(.headline)
                            }
                            .foregroundStyle(Theme.onBrand).frame(maxWidth: .infinity).frame(height: 46)
                            .background(Theme.brand.opacity(canLogin || pending != nil ? 1 : 0.4), in: Capsule())
                        }
                        .disabled(!canLogin || pending != nil)

                        if pending != nil {
                            Button("Cancel") { cancelLogin() }.font(.subheadline).foregroundStyle(Theme.muted)
                        } else {
                            Spacer(minLength: 4)
                            divider
                            outlined("Scan QR code", icon: "qrcode.viewfinder") { showQR = true }
                            HStack(spacing: 28) {
                                textButton("Open a setup link", icon: "link") { showLink = true }
                                textButton("More options", icon: "slider.horizontal.3") { showManual = true }
                            }
                            help
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, minHeight: max(geo.size.height - 64, 0), alignment: .top)     // fills the space above the hills; the spacers share out what is left
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { waves.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).ignoresSafeArea() }       // fixed to the bottom edge, behind the content
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showQR) { ProvisionSheet(initialLink: nil, autoScan: true) }
        .sheet(isPresented: $showLink) { ProvisionSheet(initialLink: nil) }
        .sheet(isPresented: $showManual) { AccountEditor(account: Account()) }
        .onChange(of: engine.registration) { _, new in
            guard let id = pending, let s = new[id] else { return }
            if s == "Registered" { pending = nil; signingIn = false }
            else if s != "Registering…" && !s.hasPrefix("Waiting") { fail(Self.explain(s)) }
        }
        .task(id: pending) {
            // a PBX that never answers: give up after 25 s rather than spin forever
            guard let id = pending else { return }
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if pending == id { fail("\(server.trimmingCharacters(in: .whitespaces)) didn't answer. Check the server name and your connection.") }
        }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 6) {
            Image("Logo").resizable().scaledToFit().frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Theme.brand.opacity(0.25), radius: 14, y: 6)
            Text("Welcome to L1ne").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
            Text("Sign in to your PBX, or scan its QR code.")
                .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
            content()
                .padding(.horizontal, 18).frame(height: 42)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        }
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text("or").font(.subheadline).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.border).frame(height: 1)
        }.padding(.vertical, 2)
    }

    private func outlined(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline)
                .foregroundStyle(Theme.brand).frame(maxWidth: .infinity).frame(height: 44)
                .overlay(Capsule().stroke(Theme.brand, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }

    private func textButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.subheadline.weight(.medium)).foregroundStyle(Theme.brand) }
            .buttonStyle(.plain)
    }

    private var help: some View {
        DisclosureGroup(isExpanded: $showHelp) {
            VStack(alignment: .leading, spacing: 8) {
                Text("**Server** is your PBX's address, like pbx.example.com. Add a port if it isn't the usual one: pbx.example.com:5080.")
                Text("**Username** is your extension number or SIP username, and **Password** is the SIP password, not your PBX web login.")
                Text("Your administrator may also have a QR code or a link that fills all of this in.")
                Text("L1ne has no sign-up of its own: it connects to a phone system someone runs. Your login stays on this phone.")
            }
            .font(.footnote).foregroundStyle(Theme.muted).padding(.top, 8)
        } label: {
            Text("Where do I find these?").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
        }
        .tint(Theme.muted)
    }

    /// Soft layered hills along the bottom edge, in the brand green.
    private var waves: some View {
        ZStack(alignment: .bottom) {
            Hills(a: 0.35, b: 0.15, c: 0.55).fill(Theme.brand.opacity(0.10)).frame(height: 150)
            Hills(a: 0.55, b: 0.30, c: 0.25).fill(Theme.brand.opacity(0.16)).frame(height: 110)
            Hills(a: 0.30, b: 0.45, c: 0.60).fill(Theme.brand.opacity(0.26)).frame(height: 70)
        }
        .allowsHitTesting(false)
    }

    private struct Hills: Shape {
        let a: Double, b: Double, c: Double      // heights (0...1) of three control points across the width
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: r.height))
            p.addLine(to: CGPoint(x: 0, y: r.height * (1 - a)))
            p.addCurve(to: CGPoint(x: r.width * 0.5, y: r.height * (1 - b)),
                       control1: CGPoint(x: r.width * 0.2, y: r.height * (1 - a - 0.25)),
                       control2: CGPoint(x: r.width * 0.35, y: r.height * (1 - b + 0.1)))
            p.addCurve(to: CGPoint(x: r.width, y: r.height * (1 - c)),
                       control1: CGPoint(x: r.width * 0.68, y: r.height * (1 - b - 0.2)),
                       control2: CGPoint(x: r.width * 0.85, y: r.height * (1 - c + 0.1)))
            p.addLine(to: CGPoint(x: r.width, y: r.height))
            p.closeSubpath()
            return p
        }
    }

    // MARK: sign in

    private func login() {
        focus = nil; error = nil
        var a = Account()
        a.domain = server
        a.username = username.trimmingCharacters(in: .whitespaces)
        a.displayName = displayName.trimmingCharacters(in: .whitespaces)
        a.changeTransport(to: transport)           // moves the port with it (5061 TLS, 5060 TCP/UDP) unless the server text names one
        a.finishNewAccount()                       // parses "host:port", keeps SRTP only on TLS, like the Settings form
        store.save(a, secret: password)
        pending = a.id
        signingIn = true                           // keeps this screen up while the PBX answers
        engine.register(a, secret: store.secret(a.id))
    }

    private func cancelLogin() { removePending(); error = nil; signingIn = false }

    private func fail(_ message: String) { removePending(); error = message; signingIn = false }

    private func removePending() {
        guard let id = pending else { return }
        engine.unregister(id); store.remove(id); pending = nil
    }

    /// Plain words for the usual ways a first login goes wrong.
    static func explain(_ status: String) -> String {
        let code = Int(status.prefix(3)) ?? 0
        switch code {
        case 401, 403: return "The PBX refused that username or password. Check them and try again."
        case 404: return "The PBX doesn't know that username or extension."
        case 408, 503, 504: return "Couldn't reach the PBX. Check the server name and your connection."
        default: return "Couldn't sign in: \(status)"
        }
    }
}
