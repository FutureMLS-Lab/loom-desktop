import AppKit
import SwiftUI

/// The web console's palette (`app.css` `:root`), so the desktop app and the
/// browser read as the same product. Each colour carries a dark-mode variant
/// resolved against the system appearance: the light side is the console's
/// warm cream, the dark side is a warm near-black keyed to the terminal
/// screen's `#1E2320` so the two surfaces sit together without a seam.
enum LoomColors {
    private static func nsHex(_ value: UInt32) -> NSColor {
        NSColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// An `NSColor` that re-resolves whenever the effective appearance
    /// changes, so a running window restyles live when the system flips.
    ///
    /// The two sides are built once, up here. Built inside the closure they
    /// were rebuilt on every resolution, and a colour that is a new object
    /// each time it is read is a colour SwiftUI cannot cache: as a `.tint` it
    /// made every hosted `NSView` rebuild its `NSAppearance` — CoreUI theme
    /// work — on every pass of the view graph, which climbed to a core of CPU
    /// and would not come down.
    static func dynamicNSColor(light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = nsHex(light)
        let darkColor = nsHex(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? darkColor
                : lightColor
        }
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    /// `--accent`. Lifted in dark mode so it still reads as a tint against
    /// the near-black surfaces, while staying deep enough to carry white
    /// text when used as a fill (chat bubbles, buttons).
    static let accent = dynamic(light: 0x4F46E5, dark: 0x7B78F0)
    /// The green the rings resolve to.
    static let green = dynamic(light: 0x22C55E, dark: 0x34D274)
    /// `--accent-soft`
    static let accentSoft = dynamic(light: 0xEEF2FF, dark: 0x2A2B45)
    /// `--bg-base` — the warm cream the whole console sits on.
    static let bgBase = dynamic(light: 0xF7F5EF, dark: 0x1D1C17)
    /// `--bg-elev-1`
    static let bgElev1 = dynamic(light: 0xFFFFFF, dark: 0x26251F)
    /// `--bg-elev-2`
    static let bgElev2 = dynamic(light: 0xF4F2EC, dark: 0x22211B)
    /// `--border`
    static let border = dynamic(light: 0xE8E4DA, dark: 0x3A382E)
    /// `--border-strong`
    static let borderStrong = dynamic(light: 0xD6D1C3, dark: 0x4D4A3D)
    /// Warnings that want acting on: unsaved text, a dropped pane, no gateway.
    static let amber = dynamic(light: 0xF59E0B, dark: 0xFBBF24)
    /// A finished task waiting to be looked at.
    ///
    /// Its own colour rather than the warning amber: a dozen of these can be
    /// on screen at once and nothing is wrong with any of them, so they are
    /// asked to be noticeable without being alarming. Muted enough not to be
    /// mistaken for the vivid green of a task that is running.
    static let attention = dynamic(light: 0x6F8C74, dark: 0x8CAB92)
    static let red = dynamic(light: 0xEF4444, dark: 0xF26D6D)

    /// The sidebar's backing wash, top and bottom.
    ///
    /// Here rather than inline in the gradient that uses them: built in a
    /// view body, each pass made two more colours, and a colour that is a
    /// new object every render is one SwiftUI redraws for.
    static let sidebarWashTop = dynamic(light: 0xF8F6F0, dark: 0x22211B)
    static let sidebarWashBottom = dynamic(light: 0xEBE7DC, dark: 0x1B1A15)
}

extension ConnectionState {
    /// One colour for "can Loom be reached", so the server bar, the sidebar
    /// footer and the dock cannot disagree about what amber means. Lives here
    /// rather than on the state itself, which is model code and holds no view.
    var dotColor: Color {
        switch self {
        case .connecting: return LoomColors.amber
        case .online: return LoomColors.green
        case .offline: return LoomColors.red
        }
    }
}
