import Combine
import Foundation
import SwiftUI

enum ConnectionState: Equatable {
    case connecting
    case online
    case offline(String)

    var dotColor: Color {
        switch self {
        case .connecting: return LoomColors.amber
        case .online: return LoomColors.green
        case .offline: return LoomColors.red
        }
    }
}

/// What a task's pane is doing, from the host-wide activity snapshot. A task
/// with no entry has no live pane.
enum TaskActivity: Equatable {
    case working
    case finished
    case idle
}

struct TaskRef: Hashable, Identifiable {
    let projectId: String
    let slug: String
    var id: String { "\(projectId)/\(slug)" }
}

/// The agent's latest words in a task, for a row opened up in the list.
struct TaskPreview: Equatable {
    var text: String
    /// What it is running right now, when that came after its last words.
    var running: String?
    var fetchedAt: Date
}

/// Projects, their tasks, and which of them are working — the desktop's
/// `TaskStore` without the dock. Polls only while the app is in front.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var connection: ConnectionState = .connecting
    @Published private(set) var projects: [LoomProject] = []
    @Published private(set) var tasksByProject: [String: [LoomTaskMeta]] = [:]
    @Published private(set) var activity: [String: TaskActivity] = [:]
    @Published private(set) var servers: [LoomServer] = []
    @Published private(set) var activeServerID = ""
    /// False until a server has been added; until then there is nothing to poll.
    @Published private(set) var hasServer = false
    @Published private(set) var previews: [TaskRef: TaskPreview] = [:]

    let api = LoomAPI()

    private var acked: [String: Double] = [:]
    private var finishByTask: [String: Double] = [:]
    private var previewLoads: Set<TaskRef> = []
    private var labelsFetchedAt: Date = .distantPast
    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0

    private static let activityInterval: TimeInterval = 4
    private static let labelsInterval: TimeInterval = 30
    private static let maxBackoff: TimeInterval = 60

    init() {
        reloadServers()
        NotificationCenter.default.addObserver(
            forName: LoomSettings.serverDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.serverChanged() }
        }
    }

    var activeServerName: String {
        servers.first { $0.id == activeServerID }.map {
            $0.name.isEmpty ? LoomServer.suggestedName(for: $0.baseURL) : $0.name
        } ?? "Loom"
    }

    /// `LoomSettings.servers` invents a localhost server when none is stored,
    /// which on a phone is the phone itself; only a stored list counts.
    private static var storedServers: Bool {
        UserDefaults.standard.data(forKey: LoomSettings.serversKey) != nil
    }

    /// Re-reads the list after an edit that leaves the current server as it was.
    func reloadServers() {
        hasServer = Self.storedServers
        servers = hasServer ? LoomSettings.servers : []
        activeServerID = hasServer ? LoomSettings.activeServerID : ""
    }

    func serverChanged() {
        reloadServers()
        stop()
        projects = []
        tasksByProject = [:]
        activity = [:]
        acked = [:]
        finishByTask = [:]
        previews = [:]
        labelsFetchedAt = .distantPast
        failureStreak = 0
        connection = .connecting
        start()
    }

    // MARK: Polling

    func start() {
        guard pollTask == nil, hasServer else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let delay = self?.nextDelay ?? Self.activityInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        labelsFetchedAt = .distantPast
        failureStreak = 0
        Task { await tick() }
    }

    /// For pull to refresh, which wants to know when it is done.
    func refresh() async {
        labelsFetchedAt = .distantPast
        failureStreak = 0
        await tick()
    }

    private var nextDelay: TimeInterval {
        guard failureStreak > 0 else { return Self.activityInterval }
        return min(Self.activityInterval * pow(2, Double(min(failureStreak, 5))), Self.maxBackoff)
    }

    private func tick() async {
        guard hasServer else { return }
        let serverID = activeServerID
        do {
            let snapshot = try await api.activity()
            guard serverID == activeServerID else { return }
            let entries = snapshot.tasks ?? [:]
            let unknown = entries.values.contains { entry in
                !(tasksByProject[entry.project]?.contains { $0.slug == entry.slug } ?? false)
            }
            if unknown || projects.isEmpty || Date().timeIntervalSince(labelsFetchedAt) > Self.labelsInterval {
                await refreshLabels()
            }
            guard serverID == activeServerID else { return }
            finishByTask = entries.mapValues { $0.finished_at ?? 0 }
            var next: [String: TaskActivity] = [:]
            for (key, entry) in entries {
                let finished = (entry.finished_at ?? 0) > (acked[key] ?? 0)
                next[key] = entry.working ? .working : (finished ? .finished : .idle)
            }
            if next != activity { activity = next }
            if connection != .online { connection = .online }
            failureStreak = 0
        } catch {
            guard serverID == activeServerID else { return }
            failureStreak += 1
            let offline = ConnectionState.offline(error.localizedDescription)
            if connection != offline { connection = offline }
        }
    }

    private func refreshLabels() async {
        do {
            let all = try await api.projects()
            if all != projects { projects = all }
            let api = self.api
            // A project whose list fails to come back keeps the one it had. Read
            // as empty, its tasks vanished for a refresh, and the task open on
            // screen closed and reopened with them.
            let previous = tasksByProject
            let fetched = await withTaskGroup(of: (String, [LoomTaskMeta]?).self) { group in
                for project in all {
                    group.addTask {
                        (project.id, try? await api.tasks(projectId: project.id))
                    }
                }
                var result: [String: [LoomTaskMeta]] = [:]
                for await (id, metas) in group { result[id] = metas ?? previous[id] ?? [] }
                return result
            }
            if fetched != tasksByProject { tasksByProject = fetched }
            labelsFetchedAt = Date()
        } catch {
            // Names are cosmetic; the next tick tries again.
        }
    }

    // MARK: Lookups

    func meta(for ref: TaskRef) -> (LoomProject, LoomTaskMeta)? {
        guard let project = projects.first(where: { $0.id == ref.projectId }),
              let meta = tasksByProject[ref.projectId]?.first(where: { $0.slug == ref.slug })
        else { return nil }
        return (project, meta)
    }

    func state(_ ref: TaskRef) -> TaskActivity? { activity[ref.id] }

    var workingCount: Int { activity.values.filter { $0 == .working }.count }
    var finishedCount: Int { activity.values.filter { $0 == .finished }.count }
    var taskCount: Int { tasksByProject.values.reduce(0) { $0 + $1.count } }

    /// When a finish nobody has looked at yet happened.
    func finishedAt(_ ref: TaskRef) -> Date? {
        guard activity[ref.id] == .finished, let finish = finishByTask[ref.id], finish > 0 else { return nil }
        return Date(timeIntervalSince1970: finish)
    }

    /// Reads the tail of the conversation for a row being opened up. Held for
    /// a little while, so folding a row and opening it again does not refetch.
    func loadPreview(_ ref: TaskRef, force: Bool = false) {
        if !force, let cached = previews[ref], Date().timeIntervalSince(cached.fetchedAt) < 20 { return }
        guard !previewLoads.contains(ref) else { return }
        previewLoads.insert(ref)
        let serverID = activeServerID
        Task {
            defer { previewLoads.remove(ref) }
            guard let feed = try? await api.conversation(projectId: ref.projectId, slug: ref.slug, limit: 20),
                  serverID == activeServerID
            else { return }
            previews[ref] = Self.preview(of: feed)
        }
    }

    private static func preview(of feed: ConversationFeed) -> TaskPreview {
        let messages = feed.messages ?? []
        let lastWords = messages.lastIndex { $0.kind == "assistant" && !($0.text ?? "").isEmpty }
        let lastTool = messages.lastIndex { $0.kind == "tool" }
        var running: String?
        if feed.working == true, let lastTool, lastTool > (lastWords ?? -1), let tool = messages[lastTool].tool {
            running = tool.summary.flatMap { $0.isEmpty ? nil : $0 } ?? tool.name
        }
        let text = lastWords.map { Self.plain(messages[$0].text ?? "") } ?? ""
        return TaskPreview(text: text, running: running, fetchedAt: Date())
    }

    /// Markdown structure read as prose: headings, fences and table rules
    /// would only take up the few lines a preview has.
    private static func plain(_ markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                while text.hasPrefix("#") { text.removeFirst() }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("```") && !line.hasPrefix("|")
            }
            .joined(separator: "\n")
    }

    /// Opening a finished task means it has been seen: stop flagging it here at
    /// once, and tell the server so every other client stops too.
    func markSeen(_ ref: TaskRef) {
        let key = ref.id
        guard let finish = finishByTask[key], finish > (acked[key] ?? 0),
              activity[key] == .finished
        else { return }
        acked[key] = finish
        activity[key] = .idle
        let serverID = activeServerID
        Task {
            do {
                try await api.ackActivity(projectId: ref.projectId, slug: ref.slug)
            } catch {
                guard serverID == activeServerID, acked[key] == finish else { return }
                acked.removeValue(forKey: key)
                refreshNow()
            }
        }
    }
}
