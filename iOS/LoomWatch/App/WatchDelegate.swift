import UserNotifications
import WatchKit

/// The parts of the app that run without a screen: launch, background
/// wakes, and answering notifications.
final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        Supervisor.configure()
        Task { @MainActor in PhoneSync.shared.start() }
        BackgroundCheck.schedule()
    }

    func applicationDidEnterBackground() {
        BackgroundCheck.schedule()
    }

    /// Every task handed over here has to be completed, or watchOS stops
    /// waking the app — or ends it.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    await BackgroundCheck.run()
                    BackgroundCheck.schedule()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
                Task { @MainActor in
                    PhoneSync.shared.start()
                    await PhoneSync.shared.settle()
                    connectivity.setTaskCompletedWithSnapshot(false)
                }
            case let snapshot as WKSnapshotRefreshBackgroundTask:
                snapshot.setTaskCompleted(
                    restoredDefaultState: true,
                    estimatedSnapshotExpiration: .distantFuture,
                    userInfo: nil
                )
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let key = info["task"] as? String, let ref = TaskRef(key: key) else { return }
        let server = (info["server"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let reply = response as? UNTextInputNotificationResponse {
            await Supervisor.deliverReply(reply.userText, to: ref, server: server)
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { WatchRouter.shared.open(ref, server: server) }
    }
}
