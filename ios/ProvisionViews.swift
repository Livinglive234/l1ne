import SwiftUI
import AVFoundation

/// Add accounts the way Linphone does: scan a QR code, open a link, or paste a configuration URL.
struct ProvisionSheet: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var dirs: DirectoryStore
    @Environment(\.dismiss) private var dismiss

    var initialLink: String?
    var autoScan = false                  // the welcome screen's "Scan QR code" goes straight to the camera
    @State private var link = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: Provisioning.Result?
    @State private var secrets: [UUID: String] = [:]
    @State private var picked: Set<UUID> = []
    @State private var importContacts = false
    @State private var importInterval = SyncInterval.onOpen
    @State private var checking = false                 // the PBX is being asked whether each account can sign in
    @State private var failures: [UUID: String] = [:]   // why an account couldn't, shown under it

    var body: some View {
        AppNavStack {
            Form {
                if let result {
                    review(result)
                } else {
                    Section {
                        Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                    } footer: { Text("Works with Linphone-style configuration QR codes and links (https, linphone-config: or l1ne-config:).") }
                    .listRowBackground(Theme.surface)
                    Section("Or paste a link") {
                        TextField("https://…", text: $link)
                            .plainInput(.URL)
                        Button(busy ? "Fetching…" : "Fetch configuration") { fetch(link) }.disabled(busy || link.isEmpty)
                    }
                    .listRowBackground(Theme.surface)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .sheetPage("Set up from a link")
            .fullScreenCover(isPresented: $scanning) {
                ZStack(alignment: .topTrailing) {
                    QRScanner { code in scanning = false; link = code; fetch(code) }.ignoresSafeArea()
                    Button("Close") { scanning = false }.padding().buttonStyle(.borderedProminent)
                }
            }
            .task {
                if let l = initialLink, result == nil { link = l; fetch(l) }
                else if autoScan, result == nil { scanning = true }
            }
        }
    }

    @ViewBuilder private func review(_ r: Provisioning.Result) -> some View {
        Section {
            ForEach(r.accounts, id: \.account.id) { p in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { picked.contains(p.account.id) }, set: { on in
                        if on { picked.insert(p.account.id) } else { picked.remove(p.account.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.account.title)
                            Text("\(p.account.username)@\(p.account.domain) · \(String(p.account.port)) · \(p.account.transport.rawValue.uppercased())")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    if picked.contains(p.account.id) && p.secret.isEmpty {
                        SecureField("Secret", text: Binding(get: { secrets[p.account.id] ?? "" }, set: { secrets[p.account.id] = $0 }))
                    }
                    if let why = failures[p.account.id] {
                        Label(why, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.danger)
                    }
                }
            }
        } header: { Text("Accounts to add") }
        .listRowBackground(Theme.surface)

        if let c = r.contactsURL, !dirs.directoryEnabled {
            Section {
                Toggle("Keep contacts in sync with this link", isOn: $importContacts)
                if importContacts {
                    Picker("Sync", selection: $importInterval) {
                        ForEach(SyncInterval.allCases) { Text($0.label).tag($0) }
                    }
                }
            } footer: {
                let host = URL(string: c)?.host ?? c
                Text(importContacts
                     ? "L1ne pulls the contact list at \(host) \(importInterval.label.lowercased()) and keeps your contacts in step with it. You can change this any time in Settings → Contacts sync."
                     : "L1ne won't pull contacts from this link. You can still import them later from Contacts, or add the link in Settings → Contacts sync.")
            }
            .listRowBackground(Theme.surface)
        }
        Section {
            Button { add(r) } label: {
                HStack(spacing: 10) {
                    if checking { ProgressView() }
                    Text(checking ? "Checking with the PBX…" : "Add")
                }
            }
                .disabled(checking || picked.isEmpty || r.accounts.contains { picked.contains($0.account.id) && $0.secret.isEmpty && (secrets[$0.account.id] ?? "").isEmpty })
        }
        .listRowBackground(Theme.surface)
    }

    private func fetch(_ text: String) {
        guard let url = Provisioning.configURL(from: text) else { error = "That isn't an https configuration link."; return }
        busy = true; error = nil
        Task {
            do {
                let r = try await Provisioning.fetch(url)
                picked = Set(r.accounts.map { $0.account.id })
                importContacts = r.contactsURL != nil && !dirs.directoryEnabled     // on by default when the file brings a contacts link
                result = r
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    /// Registers every chosen account with its PBX first and keeps them only if all of them sign in, the same rule the
    /// Welcome screen's own form follows. If one doesn't, nothing is added and the sheet says why under that account.
    private func add(_ r: Provisioning.Result) {
        let chosen = r.accounts.filter { picked.contains($0.account.id) }
        let secrets = self.secrets, importContacts = self.importContacts, importInterval = self.importInterval
        let store = self.store, engine = self.engine, dirs = self.dirs
        func secret(_ p: Provisioning.Parsed) -> String { p.secret.isEmpty ? (secrets[p.account.id] ?? "") : p.secret }
        checking = true; failures = [:]; error = nil
        Task { @MainActor in
            var failed: [UUID: String] = [:]
            await withTaskGroup(of: (UUID, String?).self) { group in
                for p in chosen {
                    let a = p.account, sec = secret(p)
                    group.addTask { @MainActor in (a.id, await LoginCheck.verify(a, secret: sec, engine: engine)) }
                }
                for await (id, why) in group { if let why { failed[id] = why } }
            }
            checking = false
            if !failed.isEmpty {
                for p in chosen { engine.unregister(p.account.id) }      // nothing is kept
                failures = failed
                return
            }
            dismiss()
            // The sheet slides away first and the accounts are added a moment later. Adding them right now would swap the
            // screen underneath the sheet (the first account replaces the welcome screen) and cut the sheet off with no animation.
            try? await Task.sleep(nanoseconds: 450_000_000)
            var first: Account?
            for p in chosen {
                var a = p.account
                if let c = r.contactsURL, importContacts { a.contactsURL = c }
                store.save(a, secret: secret(p))                        // already registered by the check above
                if first == nil { first = a }
            }
            if importContacts, !dirs.directoryEnabled, let c = r.contactsURL, let acc = first ?? store.selected {
                var link = DirectorySource(kind: .vcardLink)
                link.name = "PBX contacts"
                link.url = c
                link.interval = importInterval
                link.accountID = acc.id
                dirs.save(link, password: nil)
                DirectorySync.shared.scheduleBackground()
                await DirectorySync.shared.sync(link.id)
            }
        }
    }
}

/// Asks the PBX whether an account can sign in, without saving anything.
@MainActor enum LoginCheck {
    /// nil when it registered; otherwise plain words for what went wrong. The registration is dropped again on failure.
    static func verify(_ a: Account, secret: String, engine: SIPEngine, timeout: TimeInterval = 25) async -> String? {
        guard a.enabled else { return nil }                     // an account the setup file leaves off has nothing to check
        engine.register(a, secret: secret)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { engine.unregister(a.id); return "Cancelled" }
            if let s = engine.registration[a.id] {
                if s == "Registered" { return nil }
                if s != "Registering…" && !s.hasPrefix("Waiting") { engine.unregister(a.id); return WelcomeView.explain(s) }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        engine.unregister(a.id)
        return "\(a.domain) didn't answer. Check the server name and your connection."
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC { let v = ScannerVC(); v.onCode = onCode; return v }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
                  session.canAddInput(input) else {
                let l = UILabel(); l.text = "Camera unavailable"; l.textColor = .white; l.textAlignment = .center
                l.frame = view.bounds; l.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(l); return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            if session.canAddOutput(out) { session.addOutput(out); out.setMetadataObjectsDelegate(self, queue: .main); out.metadataObjectTypes = [.qr] }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global().async { [session] in session.startRunning() }
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); view.layer.sublayers?.first?.frame = view.bounds }
        override func viewWillDisappear(_ a: Bool) { super.viewWillDisappear(a); session.stopRunning() }

        func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from c: AVCaptureConnection) {
            guard !done, let s = (objs.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(s)
        }
    }
}
