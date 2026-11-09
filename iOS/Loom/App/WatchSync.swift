import Foundation
import WatchConnectivity

/// Hands the server list to the watch app, which has no good way to type a
/// URL and a token.
///
/// Sent as application context, which the watch receives whenever it next
/// wakes, and on request for a watch that asks before any context arrived.
/// Watches the two defaults keys rather than the screens that edit them, so
/// every path that changes a server — adding, editing, switching, removing,
/// the legacy import — reaches the watch.
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    private var observations: [NSKeyValueObservation] = []

    func start() {
        guard WCSession.isSupported(), observations.isEmpty else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        let defaults = UserDefaults.standard
        observations = [
            defaults.observe(\.loomServers) { [weak self] _, _ in self?.push() },
            defaults.observe(\.loomActiveServer) { [weak self] _, _ in self?.push() },
        ]
    }

    /// Only a stored list counts: `LoomSettings.servers` invents a localhost
    /// server when there is none, which would be the phone itself.
    static var payload: [String: Any] {
        let stored = UserDefaults.standard.data(forKey: LoomSettings.serversKey) != nil
        let servers = stored ? LoomSettings.servers : []
        return [
            "servers": (try? JSONEncoder().encode(servers)) ?? Data(),
            "active": stored ? LoomSettings.activeServerID : "",
            // Always different, so a watch app installed afresh is sent the
            // list again rather than the system deciding it already has it.
            "sentAt": Date().timeIntervalSince1970,
        ]
    }

    func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(Self.payload)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        push()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another watch deactivates the session; the next one needs
    /// it active again, and its own copy of the list.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        push()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler(Self.payload)
    }
}

private extension UserDefaults {
    @objc dynamic var loomServers: Data? { data(forKey: LoomSettings.serversKey) }
    @objc dynamic var loomActiveServer: String? { string(forKey: LoomSettings.activeServerKey) }
}
