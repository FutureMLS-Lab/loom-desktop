import Combine
import Foundation
import SwiftUI

/// Projects, their tasks, and which of them are working — the iPhone's
/// `WorkspaceStore`, reshaped for a wrist: it reads ahead the conversations
/// of the tasks worth a look, so a row can say what the agent said without
/// being opened, and it tells the supervisor about every snapshot.
@MainActor
final class WatchStore: ObservableObject {
    @Published private(set) var connection: ConnectionState = .connecting
    @Published private(set) var projects: [LoomProject] = []
    @Published private(set) var tasksByProject: [String: [LoomTaskMeta]] = [:]
    @Published private(set) var activity: [String: TaskActivity] = [:]
    @Published private(set) var previews: [TaskRef: TaskPreview] = [:]
    @Published private(set) var servers: [LoomServer] = []
    @Published private(set) var activeServerID = ""
    /// False until the iPhone has handed over a server; until then there is
    /// nothing to poll.
    @Published private(set) var hasServer = false

    let api = LoomAPI()

    private var acked: [String: Double] = [:]
    private var finishByTask: [String: Double] = [:]
    private var previewLoads: Set<TaskRef> = []
    private var previewFailures: [TaskRef: Date] = [:]
    private var labelsFetchedAt: Date = .distantPast
    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0
    /// On screen and lit. Decides the polling pace, and whether news is a tap
    /// on the wrist or a notification.
    private var foreground = true
    /// The first snapshot after polling starts is what was already there when
    /// you looked; only what changes after it is news.
    private var announcing = false

    private static let foregroundInterval: TimeInterval = 4
    /// Wrist down with the app still frontmost. Slower, but still watching,
    /// so a finish raises a notification.
    private static let backgroundInterval: TimeInterval = 20
    private static let labelsInterval: TimeInterval = 60
    private static let unknownLabelsInterval: TimeInterval = 15
    private static let maxBackoff: TimeInterval = 60
    /// Conversations read ahead, most urgent first, and how many at once —
    /// each is up to twenty messages over the phone's Bluetooth link.
    private static let previewLimit = 8
    private static let previewsPerTick = 3

    init() {
        reloadServers()
        NotificationCenter.default.addObserver(
            forName: LoomSettings.serverDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.serverChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: PhoneSync.listDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadServers() }
        }
    }

    var activeServerName: String {
        servers.first { $0.id == activeServerID }.map {
            $0.name.isEmpty ? LoomServer.suggestedName(for: $0.baseURL) : $0.name
        } ?? "Loom"
    }

    /// `LoomSettings.servers` invents a localhost server when none is stored,
    /// which on a watch is the watch itself; only a stored list counts.
    private static var storedServers: Bool {
        UserDefaults.standard.data(forKey: LoomSettings.serversKey) != nil
    }

    func reloadServers() {
        hasServer = Self.storedServers
        servers = hasServer ? LoomSettings.servers : []
        activeServerID = hasServer ? LoomSettings.activeServerID : ""
        GlanceStore.server = hasServer ? LoomSettings.active : nil
        if !hasServer { GlanceStore.save(nil, reloadingWidgets: true) }
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
        previewFailures = [:]
        labelsFetchedAt = .distantPast
        failureStreak = 0
        connection = .connecting
        start()
    }

    // MARK: Polling

    func setForeground(_ value: Bool) {
        foreground = value
    }

    func start() {
        guard pollTask == nil, hasServer else { return }
        announcing = false
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let delay = self?.nextDelay ?? Self.foregroundInterval
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
        let base = foreground ? Self.foregroundInterval : Self.backgroundInterval
        guard failureStreak > 0 else { return base }
        return min(base * pow(2, Double(min(failureStreak, 4))), Self.maxBackoff)
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
            // An unknown pane asks for the names again, but not every tick: a
            // pane no project lists stays unknown, and each refresh is a read
            // per project.
            let age = Date().timeIntervalSince(labelsFetchedAt)
            if projects.isEmpty || age > Self.labelsInterval || (unknown && age > Self.unknownLabelsInterval) {
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
            await supervise(entries, serverID: serverID)
            guard serverID == activeServerID else { return }
            GlanceStore.save(
                Glance.make(entries: entries, titles: GlanceStore.titles, server: activeServerName),
                reloadingWidgets: true
            )
            readAhead()
        } catch {
            guard serverID == activeServerID, !error.isCancellation else { return }
            failureStreak += 1
            let offline = ConnectionState.offline(error.localizedDescription)
            if connection != offline { connection = offline }
            GlanceStore.markUnreachable(reloadingWidgets: true)
        }
    }

    private func refreshLabels() async {
        do {
            let all = try await api.projects()
            if all != projects { projects = all }
            let api = self.api
            // A project whose list fails to come back keeps the one it had,
            // rather than its tasks vanishing for a refresh.
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
            var titles: [String: String] = [:]
            for (projectId, metas) in fetched {
                for meta in metas {
                    titles["\(projectId)/\(meta.slug)"] = meta.title.flatMap { $0.isEmpty ? nil : $0 } ?? meta.slug
                }
            }
            GlanceStore.titles = titles
        } catch {
            // Names are cosmetic; the next tick tries again.
        }
    }

    // MARK: Supervision

    private func supervise(_ entries: [String: ActivityTask], serverID: String) async {
        let fresh = FinishLedger.record(Glance.finishes(in: entries), server: serverID, quiet: !announcing)
        announcing = true
        let refs = fresh.compactMap(TaskRef.init(key:))
        guard !refs.isEmpty else { return }
        if foreground {
            // Looking at the list already: a tap says something moved.
            Supervisor.announce(refs.map { announcement($0, serverID: serverID) }, foreground: true)
            return
        }
        // Wrist down: the notification has to say what the agent said, which
        // the preview read while it was still working does not.
        for ref in refs.prefix(Supervisor.maxPerCheck) {
            guard let feed = try? await api.conversation(projectId: ref.projectId, slug: ref.slug, limit: 20),
                  serverID == activeServerID
            else { continue }
            previews[ref] = TaskPreview(feed: feed, state: activity[ref.id])
        }
        Supervisor.announce(refs.map { announcement($0, serverID: serverID) }, foreground: false)
    }

    private func announcement(_ ref: TaskRef, serverID: String) -> Announcement {
        let item = item(for: ref)
        return Announcement(
            ref: ref,
            title: item?.title ?? ref.slug,
            project: item?.projectLabel ?? "",
            detail: item?.question?.questions?.first?.prompt ?? previews[ref]?.text,
            waiting: item?.question != nil,
            serverID: serverID
        )
    }

    // MARK: Reading ahead

    /// Live tasks, most urgent first: unseen finishes newest first, then the
    /// working ones, then those waiting at a prompt.
    var liveRefs: [TaskRef] {
        activity.keys.compactMap(TaskRef.init(key:)).sorted { a, b in
            let rank = { (ref: TaskRef) -> Int in
                switch self.activity[ref.id] {
                case .finished: return 0
                case .working: return 1
                default: return 2
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if rank(a) == 0 { return (finishByTask[a.id] ?? 0) > (finishByTask[b.id] ?? 0) }
            return title(a).localizedCaseInsensitiveCompare(title(b)) == .orderedAscending
        }
    }

    private func readAhead() {
        let now = Date()
        var started = 0
        for ref in liveRefs.prefix(Self.previewLimit) where started < Self.previewsPerTick {
            let state = activity[ref.id]
            if let preview = previews[ref] {
                let age = now.timeIntervalSince(preview.fetchedAt)
                let stale = preview.state != state || (state == .working && age > 30) || age > 300
                guard stale else { continue }
            }
            // A read that failed waits a minute before it is tried again.
            if let failed = previewFailures[ref], now.timeIntervalSince(failed) < 60 { continue }
            if loadPreview(ref) { started += 1 }
        }
    }

    @discardableResult
    func loadPreview(_ ref: TaskRef) -> Bool {
        guard !previewLoads.contains(ref) else { return false }
        previewLoads.insert(ref)
        let serverID = activeServerID
        let state = activity[ref.id]
        Task {
            defer { previewLoads.remove(ref) }
            let feed = try? await api.conversation(projectId: ref.projectId, slug: ref.slug, limit: 20)
            guard serverID == activeServerID else { return }
            guard let feed else {
                previewFailures[ref] = Date()
                return
            }
            previewFailures[ref] = nil
            let preview = TaskPreview(feed: feed, state: state)
            if previews[ref] != preview { previews[ref] = preview }
        }
        return true
    }

    /// The open task reads its own feed far more often than the list does;
    /// what it learns is handed back so the row is current on return.
    func updatePreview(_ ref: TaskRef, from feed: ConversationFeed) {
        var preview = TaskPreview(feed: feed, state: activity[ref.id])
        if let current = previews[ref] {
            preview.fetchedAt = current.fetchedAt
            guard preview != current else { return }
            preview.fetchedAt = Date()
        }
        previews[ref] = preview
    }

    // MARK: Lookups

    func meta(for ref: TaskRef) -> (LoomProject, LoomTaskMeta)? {
        guard let project = projects.first(where: { $0.id == ref.projectId }),
              let meta = tasksByProject[ref.projectId]?.first(where: { $0.slug == ref.slug })
        else { return nil }
        return (project, meta)
    }

    func state(_ ref: TaskRef) -> TaskActivity? { activity[ref.id] }

    func title(_ ref: TaskRef) -> String {
        guard let meta = meta(for: ref)?.1, let title = meta.title, !title.isEmpty else { return ref.slug }
        return title
    }

    /// When a finish nobody has looked at yet happened.
    func finishedAt(_ ref: TaskRef) -> Date? {
        guard activity[ref.id] == .finished, let finish = finishByTask[ref.id], finish > 0 else { return nil }
        return Date(timeIntervalSince1970: finish)
    }

    /// A row for any task the server has told us about, named or not yet:
    /// a pane can show up in the activity snapshot before its project's task
    /// list has been read.
    func item(for ref: TaskRef) -> TaskItem? {
        let known = meta(for: ref)
        guard known != nil || activity[ref.id] != nil else { return nil }
        return TaskItem(
            ref: ref,
            meta: known?.1 ?? LoomTaskMeta(
                slug: ref.slug, title: nil, general_goal: nil, kind: nil, agent: nil, tmux_interview_target: nil
            ),
            projectLabel: known?.0.label ?? projects.first { $0.id == ref.projectId }?.label ?? "",
            state: activity[ref.id],
            finishedAt: finishedAt(ref),
            preview: previews[ref]
        )
    }

    var liveItems: [TaskItem] { liveRefs.compactMap(item(for:)) }

    /// Every project with its tasks, in the order the server keeps them.
    var sections: [(project: LoomProject, items: [TaskItem])] {
        projects.compactMap { project in
            let items = (tasksByProject[project.id] ?? []).compactMap {
                item(for: TaskRef(projectId: project.id, slug: $0.slug))
            }
            return items.isEmpty ? nil : (project, items)
        }
    }

    var workingCount: Int { activity.values.filter { $0 == .working }.count }
    var taskCount: Int { tasksByProject.values.reduce(0) { $0 + $1.count } }

    // MARK: Acknowledging

    /// Opening a finished task means it has been seen: stop flagging it here
    /// at once, and tell the server so every other client stops too.
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
