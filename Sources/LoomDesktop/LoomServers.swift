import Foundation

/// One Loom to talk to: a gateway or a `loom web` instance, with the token it
/// wants. Several can be configured and one is current.
struct LoomServer: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var token: String

    init(id: String = UUID().uuidString, name: String, baseURL: String, token: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
    }

    /// A readable default when the name field is left empty — the host is what
    /// tells two of these apart at a glance.
    static func suggestedName(for baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host, !host.isEmpty else { return "Loom" }
        return host
    }
}

/// Where the dock's connection settings live.
///
/// The same base URL + token pair works against either the loom-app gateway
/// (which injects the Loom token itself) or a `loom web --auth-token …`
/// instance directly — the API paths are identical.
enum LoomSettings {
    /// Kept for the single-server layout this grew out of: an install that
    /// predates the server list still has its URL and token here, and is
    /// carried over the first time the list is read.
    static let baseURLKey = "loomBaseURL"
    static let tokenKey = "loomAuthToken"
    static let serversKey = "loomServers"
    static let activeServerKey = "loomActiveServer"
    static let defaultBaseURL = "http://127.0.0.1:8787"

    /// Posted after the current server changes. Everything holding state from
    /// the old one — pills, transcripts, the terminal's stream — listens for
    /// this and lets go, rather than showing one Loom's work under another's
    /// name.
    static let serverDidChange = Notification.Name("com.loom.desktop.server-changed")

    static var servers: [LoomServer] {
        get {
            let defaults = UserDefaults.standard
            if let data = defaults.data(forKey: serversKey),
               let list = try? JSONDecoder().decode([LoomServer].self, from: data),
               !list.isEmpty {
                return list
            }
            // A fixed id, not a fresh UUID per read: this getter runs once for
            // the Settings list and again for the active-server check, and two
            // random ids never match — so a fresh install opened Settings to
            // "Select a server" with a server plainly on the list, and the
            // active dot never lit.
            let migrated = LoomServer(
                id: "migrated-legacy",
                name: LoomServer.suggestedName(for: legacyBaseURL),
                baseURL: legacyBaseURL,
                token: defaults.string(forKey: tokenKey) ?? ""
            )
            return [migrated]
        }
        set {
            let defaults = UserDefaults.standard
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: serversKey)
            // Mirrored back for anything still reading the old keys, and so an
            // older build of the app keeps working against the same server.
            if let current = newValue.first(where: { $0.id == activeServerID }) ?? newValue.first {
                defaults.set(current.baseURL, forKey: baseURLKey)
                defaults.set(current.token, forKey: tokenKey)
            }
        }
    }

    static var activeServerID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: activeServerKey) ?? ""
            let list = servers
            if list.contains(where: { $0.id == stored }) { return stored }
            return list.first?.id ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: activeServerKey) }
    }

    static var active: LoomServer? {
        let list = servers
        return list.first { $0.id == activeServerID } ?? list.first
    }

    /// Switch, and tell the app to drop what belonged to the last one.
    static func activate(_ server: LoomServer) {
        guard server.id != activeServerID else { return }
        activeServerID = server.id
        let defaults = UserDefaults.standard
        defaults.set(server.baseURL, forKey: baseURLKey)
        defaults.set(server.token, forKey: tokenKey)
        NotificationCenter.default.post(name: serverDidChange, object: nil)
    }

    /// Re-read the current server's own settings after they were edited.
    static func reload() {
        NotificationCenter.default.post(name: serverDidChange, object: nil)
    }

    private static var legacyBaseURL: String {
        let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultBaseURL : trimmed
    }

    static var baseURL: String {
        let raw = active?.baseURL ?? legacyBaseURL
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? defaultBaseURL : trimmed
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    static var token: String {
        (active?.token ?? UserDefaults.standard.string(forKey: tokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The current server's name, for anywhere that has to say which Loom this
    /// is — with several configured, "Connected" alone is not an answer.
    static var activeName: String {
        active?.name.isEmpty == false ? active!.name : LoomServer.suggestedName(for: baseURL)
    }
}
