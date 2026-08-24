import AppKit
import Combine
import Foundation

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

    /// The cadence to keep while nobody can see the screen.
    ///
    /// Four seconds is the watcher's own cadence and the right one for a dock
    /// somebody is watching; kept up overnight it is nine hundred requests an
    /// hour asking whether anything changed on a display that is switched off.
    /// Slowed rather than stopped, because a task that finishes at 3am should
    /// still raise its notification then — a minute late is not a thing anyone
    /// can measure, and being silent until the screen wakes is.
    private static let asleepInterval: TimeInterval = 60

    /// Asked of the system each time rather than tracked from the sleep and
    /// wake notifications. A flag set by a notification is a flag that can be
    /// left set — launch while the display is already off and no sleep
    /// notification is ever coming — and the way that fails is a dock that
    /// quietly stays a minute out of date for the rest of the session.
    private var screensAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Polling a server that is down does not help it come back. Each attempt
    /// also ties up a connection for the length of its timeout, so a client
    /// that keeps its cadence through an outage is adding load to something
    /// already struggling — and with several clients doing it, keeping it
    /// down. Attempts spread out until it answers, then snap back.
    private var nextDelay: TimeInterval {
        let base = screensAsleep ? Self.asleepInterval : Self.activityInterval
        guard failureStreak > 0 else { return base }
        let backoff = base * pow(2, Double(min(failureStreak, 5)))
        return min(backoff, max(Self.maxBackoff, base))
    }

    /// The current server, republished here because `LoomSettings` is plain
    /// storage: SwiftUI cannot see it change, so a switch left the old name
    /// and the old checkmark on screen until something else forced a redraw.
    @Published private(set) var servers: [LoomServer] = LoomSettings.servers
    @Published private(set) var activeServerID: String = LoomSettings.activeServerID
    @Published private(set) var activeServerName: String = LoomSettings.activeName

    init() {
        NotificationCenter.default.addObserver(
            forName: LoomSettings.serverDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.serverChanged() }
        }
        // Waking is the moment the dock is looked at hardest, and the poll it
        // is waiting on could be most of a minute away. The slow cadence needs
        // no notification of its own — `screensAsleep` asks the display.
        let workspace = NSWorkspace.shared.notificationCenter
        let awake: [NSNotification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in awake {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshNow() }
            }
        }
    }

    /// Drops a project the server no longer knows, so the sidebar empties on
    /// the click rather than at the next poll — and so a task inside it cannot
    /// stay selected in a pane that has nothing left to show.
    func forget(projectId: String) {
        projects.removeAll { $0.id == projectId }
        tasksByProject.removeValue(forKey: projectId)
        pills.removeAll { $0.projectId == projectId }
        if let selection, selection.hasPrefix("\(projectId)/") {
            self.selection = nil
        }
    }

    /// A different Loom has nothing to do with this one's tasks: drop them
    /// rather than let one server's pills sit under another's name until the
    /// next poll replaces them.
    func serverChanged() {
        servers = LoomSettings.servers
        activeServerID = LoomSettings.activeServerID
        activeServerName = LoomSettings.activeName
        stop()
        pills = []
        projects = []
        tasksByProject = [:]
        acked = []
        labelsFetchedAt = .distantPast
        failureStreak = 0
        selection = nil
        connection = .connecting
        start()
        refreshNow()
    }

    func start() {
        guard pollTask == nil else { return }
        if loadMockPills() { return }
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

    /// `LOOM_DESKTOP_MOCK_PILLS=1` fills the dock with one pill in each state
    /// and polls nothing, so the dock's appearance can be worked on and
    /// photographed without a reachable server and without creating real tasks
    /// on someone's machine to look at.
    ///
    /// `=idle` gives the same dock with nothing animating. The two together
    /// are how the dock's cost is measured: this machine's WindowServer load
    /// swings by twenty points on its own, so an absolute reading says
    /// nothing, and the honest question — what does the animation add? — is
    /// answered by alternating between these two and comparing.
    private func loadMockPills() -> Bool {
        let mock = ProcessInfo.processInfo.environment["LOOM_DESKTOP_MOCK_PILLS"]
        guard mock == "1" || mock == "idle" else { return false }
        var states: [(String, String, TaskPill.State)] = [
            ("codegptq-paper", "quant-eval", .working),
            ("1bit-trials", "quant-eval", .working),
            ("branch-mos-training", "tquark", .finished),
            ("tunekv", "tquark", .idle),
        ]
        if mock == "idle" {
            states = states.map { ($0.0, $0.1, .idle) }
        }
        pills = states.map { slug, project, state in
            TaskPill(
                id: "\(project)/\(slug)",
                projectId: project,
                slug: slug,
                title: slug,
                projectLabel: project,
                agent: "claude",
                state: state
            )
        }
        connection = .online
        return true
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
            sortByConsoleOrder(&next)
            // Publish only movement. An `@Published` fires on every
            // assignment, same value or not, and this runs every four
            // seconds — the dock was re-wrapping its pills and the sidebar
            // re-rendering on every poll of a fleet where nothing changed.
            if next != pills { pills = next }
            // The task already open in front of you is not one you need to be
            // called back to. Acknowledging only when the selection *changes*
            // missed the case that matters most: a task that finishes again
            // while you are watching it went on blinking, and was still
            // blinking after you moved to another task, because nothing ever
            // marked that finish as seen.
            if let selection,
               MainWindowController.shared.isVisible,
               next.first(where: { $0.id == selection })?.state == .finished {
                markSeen(selection)
            }
            if connection != .online { connection = .online }
            failureStreak = 0
            Notifier.shared.reconcile(pills: pills)
        } catch {
            failureStreak += 1
            let offline = ConnectionState.offline(error.localizedDescription)
            if connection != offline { connection = offline }
        }
    }

    private func refreshLabels(projectIds: Set<String>) async {
        do {
            let all = try await api.projects()
            if all != projects { projects = all }
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
            if fetched != tasksByProject { tasksByProject = fetched }
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

    /// Drag a task above another in the same project.
    ///
    /// Applied here first and sent afterwards: the list is the thing being
    /// dragged, and waiting a round trip to see it move makes the drag feel
    /// like it failed. The next poll carries the server's own order, which
    /// is the same one unless the write failed.
    func moveTask(projectId: String, slug: String, above target: String) {
        guard slug != target, var metas = tasksByProject[projectId] else { return }
        guard let from = metas.firstIndex(where: { $0.slug == slug }) else { return }
        let moved = metas.remove(at: from)
        let to = metas.firstIndex(where: { $0.slug == target }) ?? metas.count
        metas.insert(moved, at: to)
        tasksByProject[projectId] = metas
        let slugs = metas.map(\.slug)
        Task { [api] in try? await api.reorderTasks(projectId: projectId, slugs: slugs) }
        reorderPills()
    }

    func moveProject(_ id: String, above target: String) {
        guard id != target, let from = projects.firstIndex(where: { $0.id == id }) else { return }
        var next = projects
        let moved = next.remove(at: from)
        let to = next.firstIndex(where: { $0.id == target }) ?? next.count
        next.insert(moved, at: to)
        projects = next
        let ids = next.map(\.id)
        Task { [api] in try? await api.reorderProjects(ids: ids) }
        reorderPills()
    }

    /// Re-sort the published pills after a sidebar drag, publishing only if
    /// the order actually moved.
    private func reorderPills() {
        var sorted = pills
        sortByConsoleOrder(&sorted)
        if sorted != pills { pills = sorted }
    }

    /// Loom's own order, not alphabetical: the console lets you drag projects
    /// and tasks into the order you think in, and the API hands them back that
    /// way. Applied both when a poll rebuilds the pills and after a sidebar
    /// drag, so the dock never waits for the next poll to agree.
    private func sortByConsoleOrder(_ list: inout [TaskPill]) {
        let projectRank = Dictionary(
            uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) }
        )
        var taskRank: [String: Int] = [:]
        for (projectId, metas) in tasksByProject {
            for (index, meta) in metas.enumerated() {
                taskRank["\(projectId)/\(meta.slug)"] = index
            }
        }
        list.sort { left, right in
            let lp = projectRank[left.projectId] ?? Int.max
            let rp = projectRank[right.projectId] ?? Int.max
            if lp != rp { return lp < rp }
            let lt = taskRank[left.id] ?? Int.max
            let rt = taskRank[right.id] ?? Int.max
            if lt != rt { return lt < rt }
            return left.id < right.id
        }
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
