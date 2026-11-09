import Foundation
import WatchConnectivity

/// The server list, as Loom on the iPhone hands it over.
///
/// The watch follows the phone's choice of server whenever the phone changes
/// it, and otherwise keeps the one picked here — so switching on the watch
/// sticks until the phone switches.
@MainActor
final class PhoneSync: NSObject, ObservableObject {
    static let shared = PhoneSync()

    /// Posted when the list changed but the server in use did not, which
    /// needs the list re-read rather than everything dropped.
    static let listDidChange = Notification.Name("engineering.loom.watch.server-list-changed")

    @Published private(set) var lastSync: Date?
    @Published private(set) var requesting = false
    @Published private(set) var phoneReachable = false

    private static let phoneActiveKey = "loom.watch.phoneActiveServer"
    private static let syncedAtKey = "loom.watch.serversSyncedAt"

    func start() {
        lastSync = UserDefaults.standard.object(forKey: Self.syncedAtKey) as? Date
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// Asks the phone for its list now. The phone app need not be running:
    /// a message from the watch wakes it in the background.
    func requestServers() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable, !requesting else { return }
        requesting = true
        session.sendMessage(["request": "servers"]) { reply in
            Task { @MainActor in
                self.requesting = false
                self.apply(reply)
            }
        } errorHandler: { _ in
            Task { @MainActor in self.requesting = false }
        }
    }

    /// For a background wake that carries a context: done once it has landed.
    func settle() async {
        for _ in 0..<16 {
            let session = WCSession.default
            if session.activationState == .activated, !session.hasContentPending { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func apply(_ context: [String: Any]) {
        guard let data = context["servers"] as? Data,
              let servers = try? JSONDecoder().decode([LoomServer].self, from: data)
        else { return }
        let phoneActive = context["active"] as? String ?? ""
        let defaults = UserDefaults.standard
        let before = Self.connection

        if servers.isEmpty {
            defaults.removeObject(forKey: LoomSettings.serversKey)
            defaults.removeObject(forKey: LoomSettings.activeServerKey)
        } else {
            let current = defaults.string(forKey: LoomSettings.activeServerKey)
            let phoneSwitched = phoneActive != defaults.string(forKey: Self.phoneActiveKey)
            LoomSettings.servers = servers
            if phoneSwitched || !servers.contains(where: { $0.id == current }) {
                LoomSettings.activeServerID = servers.contains { $0.id == phoneActive } ? phoneActive : servers[0].id
            }
        }
        defaults.set(phoneActive, forKey: Self.phoneActiveKey)
        let now = Date()
        defaults.set(now, forKey: Self.syncedAtKey)
        lastSync = now

        if Self.connection != before {
            LoomSettings.reload()
        } else {
            NotificationCenter.default.post(name: Self.listDidChange, object: nil)
        }
    }

    /// What the store's connection hangs on — which server, where, with which
    /// token. A rename alone is not worth dropping everything for.
    private static var connection: [String]? {
        guard UserDefaults.standard.data(forKey: LoomSettings.serversKey) != nil,
              let active = LoomSettings.active
        else { return nil }
        return [active.id, active.baseURL, active.token]
    }
}

extension PhoneSync: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            if !context.isEmpty { self.apply(context) }
            if UserDefaults.standard.data(forKey: LoomSettings.serversKey) == nil { self.requestServers() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            if reachable, UserDefaults.standard.data(forKey: LoomSettings.serversKey) == nil {
                self.requestServers()
            }
        }
    }
}
