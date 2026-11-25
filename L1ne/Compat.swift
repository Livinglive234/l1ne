import SwiftUI
import UIKit

/// L1ne runs on iOS 15 and up. A few SwiftUI features only arrived in iOS 16 or 17, so each one has a stand-in here:
/// on a new iOS the real thing is used, on iOS 15 the nearest older equivalent (or nothing, where it only polishes).
/// Keep every `#available` check in this file so the rest of the app reads the same on every version.
enum Compat {
    /// Called once at launch. On iOS 15 a Form or List sits on a UITableView with its own grey background; clearing it lets
    /// the app's own background show (what `scrollContentBackground(.hidden)` does on iOS 16 and up).
    static func prepare() {
        UITableView.appearance().backgroundColor = .clear
        UITableView.appearance().sectionHeaderTopPadding = 0
    }
}

extension View {
    /// iOS 16+: hide the system background behind a Form or List. iOS 15: handled by `Compat.prepare()`.
    @ViewBuilder func hideScrollBackground() -> some View {
        if #available(iOS 16.0, *) { self.scrollContentBackground(.hidden) } else { self }
    }

    /// iOS 16+: stop a ScrollView or List scrolling. iOS 15: it just keeps scrolling.
    @ViewBuilder func scrollDisabledCompat(_ disabled: Bool) -> some View {
        if #available(iOS 16.0, *) { self.scrollDisabled(disabled) } else { self }
    }

    /// iOS 16.4+: no rubber-banding when the content fits.
    @ViewBuilder func scrollBounceOnlyWhenNeeded() -> some View {
        if #available(iOS 16.4, *) { self.scrollBounceBehavior(.basedOnSize) } else { self }
    }

    /// iOS 16+: drag to dismiss the keyboard.
    @ViewBuilder func dismissKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) { self.scrollDismissesKeyboard(.interactively) } else { self }
    }

    /// iOS 17+: a chat starts at its newest message. Older: the view scrolls there itself (see ThreadView).
    @ViewBuilder func startAtBottom() -> some View {
        if #available(iOS 17.0, *) { self.defaultScrollAnchor(.bottom) } else { self }
    }

    /// Sheet heights. iOS 16+: a half-height or fixed-height card with a drag handle. iOS 15: a normal full sheet.
    @ViewBuilder func sheetCard(_ size: SheetSize, handle: Bool = true) -> some View {
        if #available(iOS 16.0, *) {
            switch size {
            case .height(let h): self.presentationDetents([.height(h)]).presentationDragIndicator(handle ? .visible : .hidden)
            case .heightLarge(let h): self.presentationDetents([.height(h), .large]).presentationDragIndicator(handle ? .visible : .hidden)
            case .medium: self.presentationDetents([.medium]).presentationDragIndicator(handle ? .visible : .hidden)
            case .mediumLarge: self.presentationDetents([.medium, .large]).presentationDragIndicator(handle ? .visible : .hidden)
            }
        } else { self }
    }

    /// iOS 16.4+: a popover stays a popover on iPhone instead of turning into a sheet.
    @ViewBuilder func compactPopover() -> some View {
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
    }

    /// `onChange` that hands you the old and the new value, on every iOS version.
    func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping (_ old: V, _ new: V) -> Void) -> some View {
        modifier(ChangeCompat(value: value, action: action))
    }

    /// Push a screen when an optional becomes non-nil (iOS 17: the real navigationDestination(item:); older: a hidden link).
    @ViewBuilder func navDestination<Item: Identifiable & Hashable, Destination: View>(item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
        if #available(iOS 17.0, *) {
            self.navigationDestination(item: item, destination: destination)
        } else {
            self.background(
                NavigationLink(isActive: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
                    if let i = item.wrappedValue { destination(i) }
                } label: { EmptyView() }.hidden()
            )
        }
    }
}

enum SheetSize { case height(CGFloat), heightLarge(CGFloat), medium, mediumLarge }

private struct ChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var previous: V
    init(value: V, action: @escaping (V, V) -> Void) { self.value = value; self.action = action; _previous = State(initialValue: value) }
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: value) { old, new in action(old, new) }
        } else {
            content.onChange(of: value) { new in let old = previous; previous = new; action(old, new) }
        }
    }
}

/// A NavigationStack on iOS 16+, a stacked NavigationView on iOS 15.
struct AppNavStack<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 16.0, *) { NavigationStack { content() } }
        else { NavigationView { content() }.navigationViewStyle(.stack) }
    }
}

/// "Nothing here yet" page. iOS 17+: the system ContentUnavailableView. Older: the same idea, drawn by hand.
struct EmptyState: View {
    var title: String
    var systemImage: String
    var description: Text?
    init(_ title: String, systemImage: String, description: Text? = nil) { self.title = title; self.systemImage = systemImage; self.description = description }
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView { Label(title, systemImage: systemImage) } description: { description }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(.secondary)
                Text(title).font(.title2.weight(.bold))
                description.font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The message box: grows up to five lines on iOS 16+, a single line (that scrolls sideways) on iOS 15.
struct MessageField: View {
    @Binding var text: String
    var body: some View {
        if #available(iOS 16.0, *) { TextField("Message", text: $text, axis: .vertical).lineLimit(1...5) }
        else { TextField("Message", text: $text) }
    }
}

/// A "title ... value" row (LabeledContent on iOS 16+).
struct ValueRow: View {
    var title: String
    var value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        if #available(iOS 16.0, *) { LabeledContent(title, value: value) }
        else { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) } }
    }
}

/// Share a file: the system ShareLink on iOS 16+, the classic share sheet on iOS 15.
struct ShareFileButton<Label: View>: View {
    var url: URL
    @ViewBuilder var label: () -> Label
    @State private var sharing = false
    var body: some View {
        if #available(iOS 16.0, *) { ShareLink(item: url, label: label) }
        else {
            Button { sharing = true } label: { label() }
                .buttonStyle(.plain)
                .sheet(isPresented: $sharing) { ActivitySheet(items: [url]) }
        }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
