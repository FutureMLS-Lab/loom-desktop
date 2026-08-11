import Foundation

/// Persists in-progress text so switching Chat / Terminal / Files (or leaving
/// a task and coming back) does not throw away what you were typing.
enum ComposeDrafts {
    private static let defaults = UserDefaults.standard

    static func chatKey(_ sessionId: String) -> String { "loom.draft.chat.\(sessionId)" }
    static func terminalKey(_ sessionId: String) -> String { "loom.draft.term.\(sessionId)" }
    static func fileKey(_ sessionId: String, file: String) -> String {
        "loom.draft.file.\(sessionId).\(file)"
    }

    static func load(_ key: String) -> String {
        defaults.string(forKey: key) ?? ""
    }

    static func save(_ key: String, _ value: String) {
        let trimmedEmpty = value.isEmpty
        if trimmedEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }
}
