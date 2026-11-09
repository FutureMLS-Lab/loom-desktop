import Foundation
import WidgetKit

/// What the watch face shows: how many agents are working, how many have
/// finished and wait to be looked at, and the one most worth a look.
///
/// Compiled into both the watch app and its widget extension. The app writes
/// one after every poll and every background check; the widget reads it, and
/// fetches a fresh one itself when its timeline is due.
struct Glance: Codable, Equatable {
    var server: String
    var working: Int
    var review: Int
    /// Tasks with a live pane, whatever they are doing.
    var live: Int
    var headline: String?
    var headlineFinished: Bool
    var reachable: Bool
    /// When this was last confirmed against the server — later than when it
    /// last changed, since an unchanged glance is not rewritten.
    var checkedAt: Date

    /// Everything a complication draws except the time.
    func looksLike(_ other: Glance?) -> Bool {
        guard var other else { return false }
        other.checkedAt = checkedAt
        return other == self
    }

    /// The finishes nobody has acknowledged yet, by `project/slug` key.
    static func finishes(in entries: [String: ActivityTask]) -> [String: Double] {
        entries.compactMapValues { entry in
            guard !entry.working, let at = entry.finished_at, at > 0 else { return nil }
            return at
        }
    }

    static func make(
        entries: [String: ActivityTask],
        titles: [String: String],
        server: String,
        checkedAt: Date = Date()
    ) -> Glance {
        func title(_ key: String) -> String {
            if let title = titles[key], !title.isEmpty { return title }
            return entries[key]?.slug ?? key
        }
        let finishes = Self.finishes(in: entries)
        let working = entries.filter { $0.value.working }.keys.sorted { title($0) < title($1) }
        let newest = finishes.max { $0.value < $1.value }?.key
        return Glance(
            server: server,
            working: working.count,
            review: finishes.count,
            live: entries.count,
            headline: (newest ?? working.first).map(title),
            headlineFinished: newest != nil,
            reachable: true,
            checkedAt: checkedAt
        )
    }

    static let sample = Glance(
        server: "Loom",
        working: 2,
        review: 1,
        live: 4,
        headline: "quant eval harness",
        headlineFinished: true,
        reachable: true,
        checkedAt: Date()
    )
}

enum GlanceStore {
    static let appGroup = "group.engineering.loom"
    static let widgetKind = "LoomFleet"

    private static let glanceKey = "loom.glance"
    private static let serverKey = "loom.glance.server"
    private static let titlesKey = "loom.glance.titles"

    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load() -> Glance? {
        guard let data = defaults.data(forKey: glanceKey) else { return nil }
        return try? JSONDecoder().decode(Glance.self, from: data)
    }

    /// Stores the glance, and asks the watch face to redraw only when what it
    /// draws has changed: the app saves after every four-second poll.
    static func save(_ glance: Glance?, reloadingWidgets: Bool) {
        let previous = load()
        if let glance {
            guard let data = try? JSONEncoder().encode(glance) else { return }
            defaults.set(data, forKey: glanceKey)
        } else {
            defaults.removeObject(forKey: glanceKey)
        }
        let changed = glance.map { !$0.looksLike(previous) } ?? (previous != nil)
        if reloadingWidgets, changed {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }

    static func markUnreachable(reloadingWidgets: Bool) {
        guard var glance = load(), glance.reachable else { return }
        glance.reachable = false
        save(glance, reloadingWidgets: reloadingWidgets)
    }

    /// The server the watch app is using, for the widget's own fetch.
    static var server: LoomServer? {
        get {
            guard let data = defaults.data(forKey: serverKey) else { return nil }
            return try? JSONDecoder().decode(LoomServer.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: serverKey)
            } else {
                defaults.removeObject(forKey: serverKey)
            }
        }
    }

    /// Task titles by `project/slug`, which the activity snapshot does not carry.
    static var titles: [String: String] {
        get { defaults.dictionary(forKey: titlesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: titlesKey) }
    }

    /// One read of `/api/activity` with the server the watch app last used.
    /// What the widget does when its timeline is due, so the face moves on
    /// even while the app is not running.
    static func fetch(timeout: TimeInterval = 8) async -> Glance? {
        guard let server, let url = URL(string: trimmed(server.baseURL) + "/api/activity") else { return load() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw URLError(.badServerResponse)
            }
            let snapshot = try JSONDecoder().decode(ActivitySnapshot.self, from: data)
            let name = server.name.isEmpty ? LoomServer.suggestedName(for: server.baseURL) : server.name
            let glance = Glance.make(entries: snapshot.tasks ?? [:], titles: titles, server: name)
            save(glance, reloadingWidgets: false)
            return glance
        } catch {
            markUnreachable(reloadingWidgets: false)
            return load()
        }
    }

    private static func trimmed(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
