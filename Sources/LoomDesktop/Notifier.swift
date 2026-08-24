import AppKit
import UserNotifications

/// Tells you an agent finished while you were in another app — the thing a
/// browser tab cannot do. A banner names the task, and clicking it opens that
/// task; the Dock icon carries a count of everything still unseen.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// nil when running as a bare executable (swift run, .build/debug): the
    /// notification center demands a real bundle and throws an ObjC exception
    /// without one, which took the whole dev binary down at launch. The
    /// bundled app always has one, so nothing changes for it.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? .current() : nil
    private var authorized = false
    /// Tasks already announced, so a finish is not re-announced on every poll.
    private var announced: Set<String> = []
    private weak var store: TaskStore?

    nonisolated static let taskKey = "loom.task"

    func start(store: TaskStore) {
        self.store = store
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Called after every activity poll with the current fleet.
    func reconcile(pills: [TaskPill]) {
        let finished = pills.filter { $0.state == .finished }
        let finishedIDs = Set(finished.map(\.id))

        for pill in finished where !announced.contains(pill.id) {
            announced.insert(pill.id)
            post(pill)
        }
        // Anything acknowledged or working again may announce itself afresh
        // the next time it finishes.
        announced.formIntersection(finishedIDs)

        NSApp.dockTile.badgeLabel = finished.isEmpty ? nil : String(finished.count)
    }

    private func post(_ pill: TaskPill) {
        guard authorized, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = pill.displayTitle
        content.subtitle = pill.projectLabel
        content.body = "Finished and waiting for you."
        content.sound = .default
        content.userInfo = [Self.taskKey: pill.id]

        center.add(
            UNNotificationRequest(
                identifier: "loom.finished.\(pill.id)",
                content: content,
                trigger: nil
            )
        )
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show it even when Loom is frontmost: the point is that you were
        // looking at some *other* task.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let key = info[Self.taskKey] as? String else { return }
        await MainActor.run {
            guard let store = self.store else { return }
            store.selection = key
            MainWindowController.shared.show(store: store)
        }
    }
}
