import SwiftUI

/// What you see before any account exists: sign in with the three things a PBX admin hands out, or scan their QR code
/// or open their setup link. Everything it does goes through the same Account / AccountStore / provisioning code as
/// Settings → Accounts, so there is only one way an account gets made.
struct WelcomeView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @Binding var signingIn: Bool
    /// Set when this is "Add account" shown over the tabs: it gets a close button and closes itself once an account was added.
    var onClose: (() -> Void)? = nil
    @State private var startCount = 0

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
    @State private var contentHeight: CGFloat = 0     // measured, so the page only scrolls when it has to (a small phone, or the keyboard is up)
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    private var roomy: Bool { hSize == .regular && vSize == .regular }     // an iPad: keep the content together in the middle instead of spreading it over the tall screen
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
                        Spacer(minLength: 4).frame(maxHeight: roomy ? 24 : .infinity)
                        VStack(alignment: .leading, spacing: 12) {
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
                            field("Password (Secret)") {
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
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Transport").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                                Picker("Transport", selection: $transport) {
                                    ForEach(Account.Transport.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        Spacer(minLength: 4).frame(maxHeight: roomy ? 24 : .infinity)
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
                            divider
                            outlined("Scan QR code", icon: "qrcode.viewfinder") { showQR = true }
                            HStack(spacing: 28) {
                                textButton("Open a setup link", icon: "link") { showLink = true }
                                textButton("More options", icon: "slider.horizontal.3") { showManual = true }
                            }
                            help
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, minHeight: max(geo.size.height - 64, 0), alignment: roomy ? .center : .top)     // fills the space above the hills; the spacers share out what is left
                .background(GeometryReader { g in Color.clear.preference(key: WelcomeHeightKey.self, value: g.size.height) })
            }
            .onPreferenceChange(WelcomeHeightKey.self) { contentHeight = $0 }
            .scrollDisabledCompat(contentHeight <= geo.size.height + 1 && focus == nil)
            .dismissKeyboardOnScroll()
            .scrollBounceOnlyWhenNeeded()
        }
        .background { waves.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).ignoresSafeArea() }       // fixed to the bottom edge, behind the content
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            if onClose != nil {
                Button { close() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Theme.text).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close").padding(.leading, 8)
            }
        }
        .onAppear { startCount = store.accounts.count }
        .onChangeCompat(of: store.accounts.count) { _, n in      // an account came in through the QR or link sheet
            if onClose != nil, pending == nil, n > startCount { signingIn = false; onClose?() }
        }
        .sheet(isPresented: $showQR) { ProvisionSheet(initialLink: nil, autoScan: true) }
        .sheet(isPresented: $showLink) { ProvisionSheet(initialLink: nil) }
        .sheet(isPresented: $showManual) { AccountEditor(account: Account(), onSubmit: { submit($0, secret: $1) }) }
        .sheet(isPresented: $showHelp) { HelpCard().sheetCard(.heightLarge(400)) }
        .onChangeCompat(of: engine.registration) { _, new in
            guard let id = pending, let s = new[id] else { return }
            if s == "Registered" { pending = nil; signingIn = false; onClose?() }
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
        VStack(alignment: .leading, spacing: 8) {
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
        Button { showHelp = true } label: {
            Text("Where do I find these?").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The little card that slides up from the bottom.
    private struct HelpCard: View {
        private func row(_ icon: String, _ title: String, _ text: String) -> some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.brand).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(text).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where do I find these?").font(.headline).foregroundStyle(Theme.text)
                row("server.rack", "Server", "Your PBX's address, like pbx.example.com. Add a port if it isn't the usual one: pbx.example.com:5080.")
                row("person", "Username or extension", "Your extension number or SIP username.")
                row("key", "Password (Secret)", "The SIP password for that extension, not your PBX web login.")
                row("qrcode", "QR code or link", "Your administrator may have one that fills all of this in.")
                Text("L1ne has no sign-up of its own: it connects to a phone system someone runs. Your login stays on this phone.")
                    .font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            .padding(.horizontal, 24).padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.sheet.ignoresSafeArea())
        }
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
        var a = Account()
        a.domain = server
        a.username = username.trimmingCharacters(in: .whitespaces)
        a.displayName = displayName.trimmingCharacters(in: .whitespaces)
        a.changeTransport(to: transport)           // moves the port with it (5061 TLS, 5060 TCP/UDP) unless the server text names one
        a.finishNewAccount()                       // parses "host:port", keeps SRTP only on TLS, like the Settings form
        submit(a, secret: password)
    }

    /// The one way an account gets in: saved, registered, and taken out again if the PBX refuses or doesn't answer.
    /// The fields above and the "More options" form both end up here.
    private func submit(_ a: Account, secret: String) {
        focus = nil; error = nil
        store.save(a, secret: secret)
        pending = a.id
        signingIn = true                           // keeps this screen up while the PBX answers
        engine.register(a, secret: store.secret(a.id))
    }

    private func close() { if pending != nil { removePending(); error = nil; signingIn = false }; onClose?() }

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

private struct WelcomeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
