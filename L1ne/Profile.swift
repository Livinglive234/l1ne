import SwiftUI

/// Round avatar: the initials of the selected account, or a person glyph until an account exists.
struct AvatarView: View {
    var size: CGFloat = 32
    @EnvironmentObject private var store: AccountStore

    var body: some View {
        ZStack {
            Circle().fill(Theme.brand.opacity(0.18))
            if let a = store.selected, !a.initials.isEmpty {
                Text(a.initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(Theme.brand)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(Theme.brand)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Theme.brand.opacity(0.6), lineWidth: 1))
    }
}

/// The avatar in the top-left of a navigation bar, without the system's glass capsule behind it (iOS 26 adds one by default).
struct ProfileToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { ProfileButton() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { ProfileButton() }
        }
    }
}

/// Top-left avatar. Tapping it pops up a small menu (like the profile menu in Messages):
/// "Accounts" with your picture, then "Settings".
struct ProfileButton: View {
    enum Destination: String, Identifiable { case accounts, settings; var id: String { rawValue } }
    @State private var menu = false
    @State private var destination: Destination?

    var body: some View {
        Button { menu = true } label: { AvatarView(size: 32) }
            .accessibilityLabel("Accounts and settings")
            .popover(isPresented: $menu, attachmentAnchor: .point(.bottomLeading), arrowEdge: .top) {
                ProfileMenu { picked in
                    menu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { destination = picked }
                }
                .presentationCompactAdaptation(.popover)
            }
            .sheet(item: $destination) { d in
                switch d {
                case .accounts: ProfileView()
                case .settings: SettingsView()
                }
            }
    }
}

struct ProfileMenu: View {
    var pick: (ProfileButton.Destination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { pick(.accounts) } label: {
                HStack(spacing: 14) {
                    AvatarView(size: 44)
                    Text("Accounts").font(.headline).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.border)

            Button { pick(.settings) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "gearshape").font(.title3).frame(width: 44)
                    Text("Settings").font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
        .presentationBackground(.regularMaterial)
    }
}

struct ProfileView: View {
    @EnvironmentObject var engine: SIPEngine
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Account?
    @State private var provisioning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.accounts) { a in
                        HStack(spacing: 12) {
                            Button { store.select(a.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: store.selected?.id == a.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(store.selected?.id == a.id ? Theme.brand : Theme.muted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.title).foregroundStyle(Theme.text)
                                        Text("\(a.username)@\(a.domain)").font(.footnote).foregroundStyle(Theme.muted)
                                        status(engine.registration[a.id])
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { editing = a } label: { Image(systemName: "info.circle").foregroundStyle(Theme.brand) }
                                .buttonStyle(.plain)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { engine.unregister(store.accounts[i].id); store.remove(store.accounts[i].id) }
                    }
                    Menu {
                        Button("Set up from QR code or link…", systemImage: "qrcode.viewfinder") { provisioning = true }
                        Button("Enter details by hand…", systemImage: "keyboard") { editing = Account() }
                    } label: { Label("Add account", systemImage: "plus.circle.fill") }
                }
                .listRowBackground(Theme.surface)
            }
            .l1neBackground()
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
            .sheet(item: $editing) { AccountEditor(account: $0) }
            .sheet(isPresented: $provisioning) { ProvisionSheet(initialLink: nil) }
        }
    }

    @ViewBuilder private func status(_ s: String?) -> some View {
        let ok = s == "Registered"
        HStack(spacing: 6) {
            Circle().fill(ok ? Theme.brand : (s == nil ? Theme.muted : Theme.danger)).frame(width: 8, height: 8)
            Text(s ?? "Not registered").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}
