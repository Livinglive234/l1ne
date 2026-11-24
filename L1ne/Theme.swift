import SwiftUI

/// Colours from the LiveNet website. Each one has a dark and a light value and follows the system appearance
/// (or the Appearance setting). Brand green stays recognisable in both; light mode uses a slightly deeper green
/// so text and icons in it stay readable on white.
enum Theme {
    static let brand    = Color(light: 0x1A9E31, dark: 0x22C03C)   // buttons, tint, selected tab
    static let brandDim = Color(light: 0x127A24, dark: 0x178A2B)   // pressed / disabled
    static let onBrand  = Color(light: 0xFFFFFF, dark: 0x04120A)   // text and icons on green
    static let bg       = Color(light: 0xFFFFFF, dark: 0x000000)   // main screens: pure black / white
    static let sheet    = Color(light: 0xF2F6F3, dark: 0x0B0F0C)   // sheets and forms: green-tinted
    static let surface  = Color(light: 0xE8EFE9, dark: 0x121814)   // keys, cards, rows
    static let border   = Color(light: 0xCFDAD2, dark: 0x223024)
    static let text     = Color(light: 0x0E1A11, dark: 0xE8EFE9)
    static let muted    = Color(light: 0x5A6B5F, dark: 0x94A398)
    static let danger   = Color(light: 0xD23A3A, dark: 0xE04646)   // hang up, errors
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that switches with light and dark mode.
    init(light: UInt32, dark: UInt32) {
        func ui(_ h: UInt32) -> UIColor {
            UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
        self.init(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension View {
    /// Green-tinted page background for sheets, forms and settings.
    func l1neBackground() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Theme.sheet.ignoresSafeArea())
    }

    /// Black (light mode: white) background for the main screens (Recents, Contacts, Conversations, Keypad, a thread, the call).
    func mainBackground() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }
}

/// In light mode the call screen is a gray rather than black (its buttons turn translucent white on top of it).
private struct CallGrayKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var callGray: Bool { get { self[CallGrayKey.self] } set { self[CallGrayKey.self] = newValue } } }
enum CallColors {
    static func bg(_ gray: Bool) -> Color { gray ? Color(red: 0.36, green: 0.38, blue: 0.40) : Theme.bg }
    static func surface(_ gray: Bool) -> Color { gray ? Color.white.opacity(0.20) : Theme.surface }
    static func border(_ gray: Bool) -> Color { gray ? Color.white.opacity(0.28) : Theme.border }
}
