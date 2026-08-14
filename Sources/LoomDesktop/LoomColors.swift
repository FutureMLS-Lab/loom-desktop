import SwiftUI

/// The web console's palette (`app.css` `:root`), so the desktop app and the
/// browser read as the same product.
enum LoomColors {
    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `--accent`
    static let accent = hex(0x4F46E5)
    /// The green the rings resolve to.
    static let green = hex(0x22C55E)
    /// `--accent-soft`
    static let accentSoft = hex(0xEEF2FF)
    /// `--bg-base` — the warm cream the whole console sits on.
    static let bgBase = hex(0xF7F5EF)
    /// `--bg-elev-1`
    static let bgElev1 = Color.white
    /// `--bg-elev-2`
    static let bgElev2 = hex(0xF4F2EC)
    /// `--border`
    static let border = hex(0xE8E4DA)
    /// `--border-strong`
    static let borderStrong = hex(0xD6D1C3)
    /// Warnings that want acting on: unsaved text, a dropped pane, no gateway.
    static let amber = hex(0xF59E0B)
    /// A finished task waiting to be looked at.
    ///
    /// Its own colour rather than the warning amber: a dozen of these can be
    /// on screen at once and nothing is wrong with any of them, so they are
    /// asked to be noticeable without being alarming. Muted enough not to be
    /// mistaken for the vivid green of a task that is running.
    static let attention = hex(0x6F8C74)
    static let red = hex(0xEF4444)
}
