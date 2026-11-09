import Foundation
import WatchKit

/// A look at the fleet while the app is not on screen.
///
/// watchOS wakes the app for this a few times an hour at most — up to four
/// when the complication is on the face, rarely without it — so this is what
/// keeps the face and the notifications honest between visits. It stands
/// alone: a background launch has no store and no screen.
enum BackgroundCheck {
    private static let interval: TimeInterval = 15 * 60

    static func schedule() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }

    @MainActor
    static func run() async {
        guard UserDefaults.standard.data(forKey: LoomSettings.serversKey) != nil,
              let server = LoomSettings.active
        else { return }
        let api = LoomAPI()
        let snapshot: ActivitySnapshot
        do {
            snapshot = try await withDeadline(10) { try await api.activity() }
        } catch {
            GlanceStore.markUnreachable(reloadingWidgets: true)
            return
        }
        let entries = snapshot.tasks ?? [:]
        let titles = GlanceStore.titles
        let name = server.name.isEmpty ? LoomServer.suggestedName(for: server.baseURL) : server.name
        GlanceStore.save(Glance.make(entries: entries, titles: titles, server: name), reloadingWidgets: true)

        let fresh = FinishLedger.record(Glance.finishes(in: entries), server: server.id, quiet: false)
        var news: [Announcement] = []
        for key in fresh.prefix(Supervisor.maxPerCheck) {
            guard let ref = TaskRef(key: key) else { continue }
            // The agent's last words make the notification worth reading;
            // only the first gets them, to stay inside the time allowed.
            var detail: String?
            var waiting = false
            if news.isEmpty,
               let feed = try? await withDeadline(5, {
                   try await api.conversation(projectId: ref.projectId, slug: ref.slug, limit: 20)
               }) {
                let preview = TaskPreview(feed: feed, state: .finished)
                waiting = preview.question != nil
                detail = preview.question?.questions?.first?.prompt ?? preview.text
            }
            news.append(Announcement(
                ref: ref,
                title: titles[key] ?? ref.slug,
                project: "",
                detail: detail,
                waiting: waiting,
                serverID: server.id
            ))
        }
        Supervisor.announce(news, foreground: false)
    }
}
