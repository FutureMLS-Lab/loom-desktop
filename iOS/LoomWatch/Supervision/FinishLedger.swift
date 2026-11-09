import Foundation

/// The finishes the watch has already told you about, per server, so the
/// foreground poll and a background check never announce the same one twice.
enum FinishLedger {
    private static let key = "loom.watch.announcedFinishes"

    /// Records every finish in the snapshot and returns the keys not seen
    /// before. A server with no record yet is a baseline: what was already
    /// finished when the watch first looked is not news. Nor is anything
    /// when `quiet` — the first look after the app comes to the front.
    static func record(
        _ finishes: [String: Double],
        server: String,
        quiet: Bool,
        defaults: UserDefaults = .standard
    ) -> [String] {
        var all = defaults.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        let known = all[server]
        var fresh: [String] = []
        if let known, !quiet {
            fresh = finishes.filter { $0.value > (known[$0.key] ?? 0) }.keys.sorted()
        }
        // Only what is still unacknowledged is kept: once a finish has been
        // seen anywhere, the next one for that task is news again.
        all[server] = finishes.merging(known ?? [:]) { new, old in max(new, old) }
            .filter { finishes[$0.key] != nil }
        defaults.set(all, forKey: key)
        return fresh
    }
}
