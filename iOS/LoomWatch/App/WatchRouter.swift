import Foundation

enum WatchRoute: Hashable {
    case task(TaskRef)
    case allTasks
    case servers
}

/// Where the watch is, so a notification can take you to its task from
/// anywhere — including from a notification about another Loom.
@MainActor
final class WatchRouter: ObservableObject {
    static let shared = WatchRouter()

    @Published var path: [WatchRoute] = []
    /// A task to open once the server it belongs to has been switched to.
    /// Switching clears the path, so it cannot simply be pushed first.
    private(set) var pendingTask: TaskRef?

    func open(_ ref: TaskRef, server: String?) {
        if let server, server != LoomSettings.activeServerID,
           let target = LoomSettings.servers.first(where: { $0.id == server }) {
            pendingTask = ref
            LoomSettings.activate(target)
            return
        }
        path = [.task(ref)]
    }

    func serverDidSwitch() {
        path = pendingTask.map { [.task($0)] } ?? []
        pendingTask = nil
    }
}
