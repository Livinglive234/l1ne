import SwiftUI

/// Colours taken from the LiveNet website (dark theme in livenet-web/src): green brand on a green-tinted near-black.
enum Theme {
    static let brand    = Color(hex: 0x22C03C)   // --brand: buttons, tint, selected tab
    static let brandDim = Color(hex: 0x178A2B)   // --brand-dim: pressed / disabled
    static let onBrand  = Color(hex: 0x04120A)   // --on-brand: text and icons on green
    static let bg       = Color(hex: 0x000000)   // main screens: pure black
    static let sheet    = Color(hex: 0x0B0F0C)   // --bg of the website: the green-tinted black, kept for sheets and forms
    static let surface  = Color(hex: 0x121814)   // --surface: keys, cards
    static let border   = Color(hex: 0x223024)
    static let text     = Color(hex: 0xE8EFE9)   // --text
    static let muted    = Color(hex: 0x94A398)
    static let danger   = Color(hex: 0xE04646)   // hang up, errors
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Green-tinted page background for sheets, forms and settings.
    func l1neBackground() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Theme.sheet.ignoresSafeArea())
    }

    /// Pure black background for the main screens (Recents, Contacts, Conversations, Keypad, a thread, the call).
    func mainBackground() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }
}
