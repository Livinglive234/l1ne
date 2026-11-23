import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var applying = false

    private var recordingCount: Int { RecordingsView.files().count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
                    }
                } header: { Text("Look") } footer: { Text("System follows your phone. The call screen is always dark, like the iPhone's.") }
                .listRowBackground(Theme.surface)

                Section("Calls") {
                    Toggle("Automatically start recording calls", isOn: $settings.autoRecord)
                    Toggle("Show calls in the Phone app", isOn: $settings.callsInPhoneApp)
                    NavigationLink("Advanced calls settings") { AdvancedCallsView() }
                    NavigationLink { RecordingsView() } label: {
                        LabeledContent("Recordings", value: recordingCount == 0 ? "None" : "\(recordingCount)")
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Use only Wi-Fi networks", isOn: $settings.wifiOnly)
                        .onChange(of: settings.wifiOnly) { _, _ in engine.reregisterAll() }
                    Toggle("Allow IPv6", isOn: $settings.allowIPv6)
                } header: { Text("Network") } footer: {
                    Text("IPv6 changes apply the next time L1ne starts.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    TextField("Remote provisioning URL", text: $settings.provisioningURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Download & apply") { applying = true }
                        .disabled(Provisioning.configURL(from: settings.provisioningURL) == nil)
                } header: { Text("Advanced") } footer: {
                    Text("Fetches a Linphone-style configuration file once, shows you what it contains, and adds the accounts you confirm.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Voicemail tab", isOn: $settings.showVoicemailTab)
                    Toggle("Voicemail button on keypad", isOn: $settings.showKeypadVoicemail)
                    Toggle("Notify me of new voicemail", isOn: $settings.voicemailNotify).disabled(true)
                } header: { Text("Voicemail") } footer: {
                    Text("Notifications for new voicemail are planned for later. They need push, which L1ne doesn't have yet.")
                }
                .listRowBackground(Theme.surface)

                Section("Contacts") {
                    NavigationLink("Contacts sync") { DirectorySourcesView() }
                    LabeledContent("In L1ne", value: "\(contacts.contacts.count)")
                    Button("Remove all contacts from L1ne", role: .destructive) { confirmRemove = true }
                        .disabled(contacts.contacts.isEmpty)
                }
                .listRowBackground(Theme.surface)

                Section("Privacy") {
                    Label("L1ne has no access to your phone's contacts. Contacts arrive only through the imports and syncs you set up.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")
                    LabeledContent("SIP engine", value: "PJSIP \(SIPEngine.version)")
                }
                .listRowBackground(Theme.surface)
            }
            .l1neBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
            .sheet(isPresented: $applying) { ProvisionSheet(initialLink: settings.provisioningURL) }
            .confirmationDialog("Remove all contacts from L1ne?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove all", role: .destructive) { contacts.removeAll() }
            } message: { Text("This only affects L1ne's own list, not your phone's contacts.") }
        }
    }
}

struct AdvancedCallsView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var settings: AppSettings
    @State private var codecs: [SIPEngine.Codec] = []

    var body: some View {
        List {
            Section {
                Toggle("Accept early media", isOn: $settings.acceptEarlyMedia)
                Toggle("Allow outgoing early media", isOn: $settings.allowOutgoingEarlyMedia)
            } header: { Text("Early media") } footer: {
                Text("Early media is audio the other side sends before the call is answered, such as a ringback tone or an announcement.")
            }
            .listRowBackground(Theme.surface)

            Section {
                ForEach(codecs) { c in
                    Toggle(isOn: Binding(get: { !settings.codecsOff.contains(c.id) }, set: { on in
                        settings.codecsOff.removeAll { $0 == c.id }
                        if !on { settings.codecsOff.append(c.id) }
                        engine.applyCodecs()
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.headline)
                            Text(c.detail).font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .onMove { from, to in
                    codecs.move(fromOffsets: from, toOffset: to)
                    settings.codecOrder = codecs.map(\.id)
                    engine.applyCodecs()
                }
            } header: { Text("Audio codecs") } footer: {
                Text("Drag to reorder: the codec at the top is offered first. Switch off any you don't want. Wideband G722 sounds best on most PBXes.")
            }
            .listRowBackground(Theme.surface)
        }
        .environment(\.editMode, .constant(.active))
        .l1neBackground()
        .navigationTitle("Advanced calls settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { codecs = engine.availableCodecs() }
    }
}

struct RecordingsView: View {
    @State private var files = Self.files()
    @State private var player: AVAudioPlayer?
    @State private var playing: URL?

    static func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: SIPEngine.recordingsFolder, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []
        return all.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var body: some View {
        List {
            ForEach(files, id: \.self) { url in
                HStack {
                    Button { toggle(url) } label: {
                        Image(systemName: playing == url ? "pause.circle.fill" : "play.circle.fill").font(.title2).foregroundStyle(Theme.brand)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(url)).foregroundStyle(Theme.text)
                        Text(size(url)).font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.brand) }
                }
                .listRowBackground(Theme.surface)
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                files = Self.files()
            }
        }
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("No recordings", systemImage: "waveform",
                                       description: Text("Record a call with the Record button while you're on it, or turn on automatic recording in Settings. Check your local laws about telling people you record."))
            }
        }
        .l1neBackground()
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player?.stop() }
    }

    private func title(_ url: URL) -> String {
        let n = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2).map(String.init)
        guard n.count == 3 else { return url.lastPathComponent }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let when = f.date(from: n[0] + "-" + n[1]).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? n[0]
        return "\(n[2]) · \(when)"
    }

    private func size(_ url: URL) -> String {
        let b = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    private func toggle(_ url: URL) {
        if playing == url { player?.stop(); playing = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playing = player == nil ? nil : url
    }
}
