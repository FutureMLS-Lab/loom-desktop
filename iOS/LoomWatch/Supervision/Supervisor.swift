import Foundation
import UserNotifications
import WatchKit

/// An agent that stopped, as the wrist hears about it.
struct Announcement {
    let ref: TaskRef
    let title: String
    let project: String
    let detail: String?
    /// It stopped on a question, which is worth saying in the title.
    let waiting: Bool
    let serverID: String
}

enum Supervisor {
    static let category = "loom.finished"
    static let replyAction = "reply"
    /// A burst of finishes is a few notifications, not a wall of them.
    static let maxPerCheck = 3

    static func configure() {
        let center = UNUserNotificationCenter.current()
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message the agent"
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [reply], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Looking at the app, a tap is enough — the list already shows what
    /// moved. Otherwise a notification, which a reply can answer.
    @MainActor
    static func announce(_ news: [Announcement], foreground: Bool) {
        guard !news.isEmpty else { return }
        if foreground {
            WKInterfaceDevice.current().play(.notification)
            return
        }
        for item in news.prefix(maxPerCheck) { post(item) }
    }

    private static func post(_ item: Announcement) {
        let content = UNMutableNotificationContent()
        content.title = item.waiting ? "\(item.title) needs you" : "\(item.title) finished"
        if !item.project.isEmpty { content.subtitle = item.project }
        if let detail = item.detail, !detail.isEmpty {
            content.body = WatchText.bare(detail, limit: 240)
        } else {
            content.body = "The agent stopped. Open Loom to see what it did."
        }
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = item.serverID
        content.userInfo = ["task": item.ref.id, "server": item.serverID]
        // One per task: a newer finish replaces the one before it.
        let request = UNNotificationRequest(
            identifier: "finish.\(item.serverID).\(item.ref.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// A reply typed or dictated on the notification itself. The app may have
    /// been woken just for this, so the send gets a deadline and a failure is
    /// said out loud rather than lost.
    static func deliverReply(_ text: String, to ref: TaskRef, server: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let failure: String?
        if let server, server != LoomSettings.activeServerID {
            failure = "Loom on the watch is using another server now."
        } else {
            do {
                let api = LoomAPI()
                try await withDeadline(12) {
                    try await api.send(projectId: ref.projectId, slug: ref.slug, text: trimmed)
                }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
        guard let failure else { return }
        let content = UNMutableNotificationContent()
        content.title = "Reply not sent"
        content.body = "“\(WatchText.clipped(trimmed, to: 80))” — \(failure)"
        content.userInfo = ["task": ref.id, "server": server ?? ""]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "reply-failed.\(ref.id)", content: content, trigger: nil)
        )
    }
}

struct DeadlineExceeded: LocalizedError {
    var errorDescription: String? { "Loom did not answer in time." }
}

/// Runs `work`, giving up after `seconds`. Background time on a watch is
/// counted in seconds, and a request left hanging past it is a killed app.
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        return first
    }
}
