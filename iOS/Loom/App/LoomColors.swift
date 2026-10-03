import SwiftUI
import UIKit

/// The desktop palette, by the same names: the shared markdown layout draws
/// with these, and the two apps should read as one product.
enum LoomColors {
    static func uiColor(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func dynamicUIColor(light: UInt32, dark: UInt32) -> UIColor {
        let lightColor = uiColor(light)
        let darkColor = uiColor(dark)
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: dynamicUIColor(light: light, dark: dark))
    }

    static let accent = dynamic(light: 0x4F46E5, dark: 0x7B78F0)
    static let green = dynamic(light: 0x22C55E, dark: 0x34D274)
    static let accentSoft = dynamic(light: 0xEEF2FF, dark: 0x2A2B45)
    static let bgBase = dynamic(light: 0xF7F5EF, dark: 0x1D1C17)
    static let bgElev1 = dynamic(light: 0xFFFFFF, dark: 0x26251F)
    static let bgElev2 = dynamic(light: 0xF4F2EC, dark: 0x22211B)
    static let border = dynamic(light: 0xE8E4DA, dark: 0x3A382E)
    static let borderStrong = dynamic(light: 0xD6D1C3, dark: 0x4D4A3D)
    static let amber = dynamic(light: 0xF59E0B, dark: 0xFBBF24)
    static let attention = dynamic(light: 0x6F8C74, dark: 0x8CAB92)
    static let red = dynamic(light: 0xEF4444, dark: 0xF26D6D)
}

enum LoomShape {
    static var control: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }
    static var field: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }
    static var bubble: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
}

/// The agent's pane is always dark: its TUIs assume a dark terminal. Same
/// colours as the desktop's xterm theme.
enum TerminalTheme {
    static let background: UInt32 = 0x1E2320
    static let foreground: UInt32 = 0xDFE6DD
    static let caret: UInt32 = 0x8FC3A2
    static let palette: [UInt32] = [
        0x2B2620, 0xE06C5A, 0x9EC46A, 0xE0AF68, 0x7AA2F7, 0xC79BF0, 0x79C7C7, 0xD8CFC2,
        0x7A6F60, 0xF08A7A, 0xB6D98A, 0xF0C987, 0x9BB8FA, 0xD4B3F5, 0x9BD9D9, 0xFDF6EA,
    ]
    static let screen = Color(uiColor: LoomColors.uiColor(background))
    static let chrome = Color(uiColor: LoomColors.uiColor(0x272C28))
    static let field = Color(uiColor: LoomColors.uiColor(0x2F3530))
    static let text = Color(uiColor: LoomColors.uiColor(foreground))
    static let dimText = Color(uiColor: LoomColors.uiColor(0x8D9C8F))
}
