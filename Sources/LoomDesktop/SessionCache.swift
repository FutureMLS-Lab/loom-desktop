import Foundation
import Combine

/// Keeps one `ChatSession` per task for the inline task pane. Only the visible
/// task polls: switching away stops the previous session, so browsing a fleet
/// of forty tasks does not leave forty pollers running. Sessions are kept (not
/// discarded) so returning to a task shows its transcript immediately.
@MainActor
final class SessionCache: ObservableObject {
    private var sessions: [String: ChatSession] = [:]
    private var activeKey: String?
    private let api = LoomAPI()

    /// Most recently used order; anything past the cap is dropped.
    private var order: [String] = []
    private static let capacity = 12

    func session(
        projectId: String,
        slug: String,
        title: String,
        projectLabel: String
    ) -> ChatSession {
        let key = "\(projectId)/\(slug)"

        if activeKey != key, let previous = activeKey, let session = sessions[previous] {
            session.stop()
        }
        activeKey = key

        order.removeAll { $0 == key }
        order.append(key)

        if let existing = sessions[key] {
            existing.title = title
            existing.start()
            return existing
        }

        let session = ChatSession(
            projectId: projectId,
            slug: slug,
            title: title,
            projectLabel: projectLabel,
            api: api
        )
        sessions[key] = session

        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            sessions[oldest]?.stop()
            sessions.removeValue(forKey: oldest)
        }
        return session
    }

    /// Nothing selected: stop the last poller rather than leaving it running
    /// against a task nobody is looking at.
    func deactivate() {
        if let activeKey, let session = sessions[activeKey] {
            session.stop()
        }
        activeKey = nil
    }
}
