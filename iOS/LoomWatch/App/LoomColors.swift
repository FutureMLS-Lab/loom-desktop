import SwiftUI

/// The desktop and iPhone palette, by the same names. The watch is always
/// dark, so each colour is the dark variant the other two switch to.
enum LoomColors {
    static func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static let accent = color(0x7B78F0)
    static let green = color(0x34D274)
    static let attention = color(0x8CAB92)
    static let amber = color(0xFBBF24)
    static let red = color(0xF26D6D)
    static let idle = color(0x8E8E93)
    static let stopped = color(0x636366)

    /// The tint a task's state wears everywhere it is drawn — orb, header,
    /// the page behind its detail.
    static func tint(_ state: TaskActivity?, waiting: Bool = false) -> Color {
        if waiting { return amber }
        switch state {
        case .working: return accent
        case .finished: return attention
        case .idle: return idle
        case nil: return stopped
        }
    }

    static func agent(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "claude": return color(0xD97757)
        case "cursor": return color(0x5A9CF5)
        case "codex": return color(0x2DBE94)
        default: return idle
        }
    }

    static func agentName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": return "Claude"
        case "cursor": return "Cursor"
        case "codex": return "Codex"
        default: return agent.capitalized
        }
    }
}
