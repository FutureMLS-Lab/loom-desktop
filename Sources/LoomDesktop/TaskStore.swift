import Foundation
import Combine

/// One pill on the dock: a Loom task with a live agent pane.
struct TaskPill: Identifiable, Equatable {
    enum State: Equatable {
        /// The agent is generating right now → the rotating Loom ring.
        case working
        /// The agent stopped while you were looking elsewhere → blink.
        case finished
        /// Pane alive, agent waiting, nothing unseen.
        case idle
    }

    let id: String // "<projectId>/<slug>"
    let projectId: String
    let slug: String
    var title: String
    var projectLabel: String
    var agent: String
    var state: State

    var displayTitle: String { title.isEmpty ? slug : title }

    /// SF Symbol per agent CLI, following session-dock's source icons.
    var symbolName: String {
        switch agent.lowercased() {
        case "cursor": return "cursorarrow.rays"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "claude": return "terminal.fill"
        default: return "sparkles"
        }
    }
}

enum ConnectionState: Equatable {
    case connecting
    case online
    case offline(String)
}

/// Polls the Loom server and turns its host-wide activity snapshot into dock
/// pills. Activity is cheap and frequent (matching the server watcher's own
/// 4s cadence); task titles and project names change rarely and are refreshed
/// on a slower cycle or when an unknown task appears.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var pills: [TaskPill] = []
    @Published private(set) var connection: ConnectionState = .connecting
    @Published private(set) var projects: [LoomProject] = []
    @Published private(set) var tasksByProject: [String: [LoomTaskMeta]] = [:]
    /// "projectId/slug" of the task shown in the main window. Shared state so
    /// a dock pill and the sidebar drive the same single view rather than
    /// spawning windows.
    ///
    /// Opening a task counts as having seen it, so the blink stops here rather
    /// than at each call site. There are six ways in — a dock pill, a sidebar
    /// row, the fleet menu, the menu-bar item, ⌘P, a notification — and only
    /// two of them used to acknowledge, so opening a finished task from the
    /// sidebar left it flashing for something you were already looking at.
    @Published var selection: String? {
        didSet {
            guard let selection, selection != oldValue else { return }
            markSeen(selection)
        }
    }

    let api = LoomAPI()

    /// Finishes acknowledged locally, so the blink stops immediately instead
    /// of waiting for the next poll round-trip (mirrors the iOS app).
    private var acked: Set<String> = []
    private var labelsFetchedAt: Date = .distantPast
    private var pollTask: Task<Void, Never>?

    static let activityInterval: TimeInterval = 4
    static let labelsInterval: TimeInterval = 30
    /// How far apart to space attempts once the server stops answering.
    private static let maxBackoff: TimeInterval = 60
    private var failureStreak = 0

    /// Polling a server that is down does not help it come back. Each attempt
    /// also ties up a connection for the length of its timeout, so a client
    /// that keeps its cadence through an outage is adding load to something
    /// already struggling — and with several clients doing it, keeping it
    /// down. Attempts spread out until it answers, then snap back.
    private var nextDelay: TimeInterval {
        guard failureStreak > 0 else { return Self.activityInterval }
        let backoff = Self.activityInterval * pow(2, Double(min(failureStreak, 5)))
        return min(backoff, Self.maxBackoff)
    }

    func start() {
        guard pollTask == nil else { return }
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

    /// Force a full refresh (settings changed, user asked). Asking by hand
    /// also clears the backoff — the wait exists to spare a struggling server,
    /// not to make someone who is watching it wait a minute.
    func refreshNow() {
        labelsFetchedAt = .distantPast
        failureStreak = 0
        Task { await tick() }
    }

    private func tick() async {
        do {
            let snapshot = try await api.activity()
            let entries = snapshot.tasks ?? [:]

            let unknown = entries.keys.contains { labelFor(key: $0) == nil }
            if unknown || Date().timeIntervalSince(labelsFetchedAt) > Self.labelsInterval {
                await refreshLabels(projectIds: Set(entries.values.map(\.project)))
            }

            var next: [TaskPill] = []
            for (key, entry) in entries {
                let finished = (entry.finished_at ?? 0) > 0 && !acked.contains(key)
                let state: TaskPill.State = entry.working
                    ? .working
                    : (finished ? .finished : .idle)
                // Working again supersedes a locally-acked finish; drop the
                // ack so the next real finish blinks again.
                if entry.working { acked.remove(key) }
                let label = labelFor(key: key)
                next.append(
                    TaskPill(
                        id: key,
                        projectId: entry.project,
                        slug: entry.slug,
                        title: label?.title ?? entry.slug,
                        projectLabel: label?.project ?? entry.project,
                        agent: label?.agent ?? "",
                        state: state
                    )
                )
            }
            // Loom's own order, not alphabetical: the web console lets you
            // drag projects and tasks into the order you think in, and the
            // API hands them back that way.
            let projectRank = Dictionary(
                uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) }
            )
            var taskRank: [String: Int] = [:]
            for (projectId, metas) in tasksByProject {
                for (index, meta) in metas.enumerated() {
                    taskRank["\(projectId)/\(meta.slug)"] = index
                }
            }
            next.sort { left, right in
                let lp = projectRank[left.projectId] ?? Int.max
                let rp = projectRank[right.projectId] ?? Int.max
                if lp != rp { return lp < rp }
                let lt = taskRank[left.id] ?? Int.max
                let rt = taskRank[right.id] ?? Int.max
                if lt != rt { return lt < rt }
                return left.id < right.id
            }
            pills = next
            connection = .online
            failureStreak = 0
            Notifier.shared.reconcile(pills: next)
        } catch {
            failureStreak += 1
            connection = .offline(error.localizedDescription)
        }
    }

    private func refreshLabels(projectIds: Set<String>) async {
        do {
            let all = try await api.projects()
            projects = all
            // In parallel: one sequential round trip per project against a
            // remote gateway added up to seconds of stalling every refresh.
            let api = self.api
            let fetched = await withTaskGroup(
                of: (String, [LoomTaskMeta]).self
            ) { group -> [String: [LoomTaskMeta]] in
                for project in all {
                    group.addTask {
                        let metas = (try? await api.tasks(projectId: project.id)) ?? []
                        return (project.id, metas)
                    }
                }
                var result: [String: [LoomTaskMeta]] = [:]
                for await (id, metas) in group { result[id] = metas }
                return result
            }
            tasksByProject = fetched
            labelsFetchedAt = Date()
        } catch {
            // Labels are cosmetic; pills fall back to slugs until this works.
        }
    }

    private func labelFor(key: String) -> (title: String, project: String, agent: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let projectId = String(key[key.startIndex..<slash])
        let slug = String(key[key.index(after: slash)...])
        guard let metas = tasksByProject[projectId],
              let meta = metas.first(where: { $0.slug == slug })
        else { return nil }
        let project = projects.first { $0.id == projectId }
        return (
            title: meta.title ?? slug,
            project: project?.label ?? projectId,
            agent: meta.agent ?? ""
        )
    }

    /// Clicking a blinking pill means "I've seen it": stop the blink locally
    /// and tell the server so other clients stop blinking too.
    func acknowledge(_ pill: TaskPill) {
        markSeen(pill.id)
    }

    /// How many tasks are waiting to be looked at.
    var unseenCount: Int {
        pills.filter { $0.state == .finished }.count
    }

    /// Clear the whole backlog. A dozen finishes accumulated over a day is a
    /// dozen things blinking, which stops reading as "these want you" and
    /// starts reading as noise.
    func markAllSeen() {
        for pill in pills where pill.state == .finished {
            markSeen(pill.id)
        }
    }

    private func markSeen(_ key: String) {
        guard let slash = key.firstIndex(of: "/") else { return }
        // Already seen: nothing to stop blinking, and no need to tell the
        // server twice. The ack is dropped again if the task starts working.
        guard acked.insert(key).inserted else { return }
        if let idx = pills.firstIndex(where: { $0.id == key }),
           pills[idx].state == .finished {
            pills[idx].state = .idle
        }
        let projectId = String(key[..<slash])
        let slug = String(key[key.index(after: slash)...])
        Task { try? await api.ackActivity(projectId: projectId, slug: slug) }
    }

    /// More than one project on the dock → prefix pills with the project so
    /// same-named tasks stay tellable-apart.
    var showsProjectPrefix: Bool {
        Set(pills.map(\.projectId)).count > 1
    }

    func select(projectId: String, slug: String) {
        selection = "\(projectId)/\(slug)"
    }

    func meta(forSelection selection: String) -> (LoomProject, LoomTaskMeta)? {
        guard let slash = selection.firstIndex(of: "/") else { return nil }
        let projectId = String(selection[..<slash])
        let slug = String(selection[selection.index(after: slash)...])
        guard let project = projects.first(where: { $0.id == projectId }),
              let meta = tasksByProject[projectId]?.first(where: { $0.slug == slug })
        else { return nil }
        return (project, meta)
    }

    /// Working / finished-unseen counts per project, for the picker header.
    func projectCounts(for projectId: String) -> (working: Int, finished: Int)? {
        let mine = pills.filter { $0.projectId == projectId }
        guard !mine.isEmpty else { return nil }
        return (
            working: mine.filter { $0.state == .working }.count,
            finished: mine.filter { $0.state == .finished }.count
        )
    }
}
