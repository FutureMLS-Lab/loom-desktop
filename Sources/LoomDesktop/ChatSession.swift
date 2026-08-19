import Foundation
import Combine

/// Everything the open task knows about itself, shared by all four of its
/// tabs: the conversation feed, polling, sending, answering structured
/// questions, the run monitor, and the pane target for interrupts. Mirrors
/// the iOS app's feed behavior: full read on open, tail
/// polls merged by message id, and a staggered refresh burst after a send so
/// the reply lands quickly.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let projectId: String
    let slug: String
    let projectLabel: String
    @Published var title: String

    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var available = true
    @Published private(set) var online = false
    @Published private(set) var working = false
    @Published private(set) var agent = ""
    @Published private(set) var hasMore = false
    @Published private(set) var total = 0
    @Published private(set) var loading = true
    @Published private(set) var error = ""

    /// Optimistic echo of a message the server hasn't reflected back yet.
    @Published private(set) var pendingSend: String?
    @Published private(set) var sending = false
    @Published private(set) var answering = false
    @Published private(set) var answerFeedback = ""
    @Published private(set) var starting = false

    private(set) var paneTarget = ""
    /// Bumped whenever a flow step that rewrites PLAN.md completes, so an open
    /// plan view knows to re-read it.
    @Published private(set) var planRevision = 0

    /// Composer text lives on the session (not the view) so switching tabs or
    /// briefly leaving the task does not wipe what you were typing. Also
    /// mirrored into `UserDefaults` via `ComposeDrafts`.
    @Published var chatDraft: String = ""
    @Published var terminalDraft: String = ""
    /// Unsaved Files-tab edits, keyed by relative markdown path.
    @Published var fileDrafts: [String: String] = [:]

    nonisolated var id: String { "\(projectId)/\(slug)" }

    /// Exposed for the tabbed task window (diff/terminal fetch through it).
    let api: LoomAPI
    private var pollTask: Task<Void, Never>?
    private var sessionId: String?
    private var limit = 60
    /// Poll hard while the agent is producing output, back off when it is
    /// waiting on you: an idle task asked a remote gateway 30 times a minute
    /// for a transcript that had not changed.
    private static let workingInterval: TimeInterval = 1.5
    private static let idleInterval: TimeInterval = 5
    private static let maxLimit = 500
    /// Staggered re-reads that catch an agent reply landing right after a send.
    private static let burstDelaysMs: [UInt64] = [0, 250, 500, 1000]
    /// Consecutive failed reads, used to back away from a server that is not
    /// answering rather than keep a full-rate poll pointed at it.
    private var failureStreak = 0
    private static let maxBackoff: TimeInterval = 60

    private var pollDelay: TimeInterval {
        if failureStreak > 0 {
            return min(Self.idleInterval * pow(2, Double(min(failureStreak, 4))), Self.maxBackoff)
        }
        return working ? Self.workingInterval : Self.idleInterval
    }

    init(projectId: String, slug: String, title: String, projectLabel: String, api: LoomAPI) {
        self.projectId = projectId
        self.slug = slug
        self.title = title
        self.projectLabel = projectLabel
        self.api = api
        let sid = "\(projectId)/\(slug)"
        self.chatDraft = ComposeDrafts.load(ComposeDrafts.chatKey(sid))
        self.terminalDraft = ComposeDrafts.load(ComposeDrafts.terminalKey(sid))
    }

    func persistChatDraft() {
        ComposeDrafts.save(ComposeDrafts.chatKey(id), chatDraft)
    }

    func persistTerminalDraft() {
        ComposeDrafts.save(ComposeDrafts.terminalKey(id), terminalDraft)
    }

    func loadFileDraft(_ file: String) -> String? {
        if let memory = fileDrafts[file], !memory.isEmpty { return memory }
        let disk = ComposeDrafts.load(ComposeDrafts.fileKey(id, file: file))
        if !disk.isEmpty {
            fileDrafts[file] = disk
            return disk
        }
        return nil
    }

    func persistFileDraft(_ file: String, text: String, baseline: String) {
        if text == baseline {
            fileDrafts.removeValue(forKey: file)
            ComposeDrafts.save(ComposeDrafts.fileKey(id, file: file), "")
        } else {
            fileDrafts[file] = text
            ComposeDrafts.save(ComposeDrafts.fileKey(id, file: file), text)
        }
    }

    func clearFileDraft(_ file: String) {
        fileDrafts.removeValue(forKey: file)
        ComposeDrafts.save(ComposeDrafts.fileKey(id, file: file), "")
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.loadDetail()
            await self?.load(full: true)
            while !Task.isCancelled {
                let interval = self?.pollDelay ?? Self.idleInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.load(full: false)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadDetail() async {
        guard let detail = try? await api.taskDetail(projectId: projectId, slug: slug) else { return }
        paneTarget = detail.paneTarget
        serverPlanPath = detail.plan_path
        if let t = detail.meta.title, !t.isEmpty { title = t }
    }

    private var serverPlanPath: String?

    private func load(full: Bool) async {
        do {
            let feed = try await api.conversation(
                projectId: projectId,
                slug: slug,
                limit: full ? limit : 20
            )
            apply(feed, updateOnly: !full)
            error = ""
            failureStreak = 0
        } catch {
            failureStreak += 1
            // Only surface errors while there is nothing on screen; a dropped
            // poll on a live feed is not worth a banner.
            if messages.isEmpty { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func apply(_ feed: ConversationFeed, updateOnly: Bool) {
        available = feed.available ?? true
        online = feed.online ?? false
        working = feed.working ?? false
        agent = feed.agent ?? agent
        total = feed.total ?? total

        let incoming = feed.messages ?? []

        if !updateOnly || sessionId != feed.session_id {
            sessionId = feed.session_id
            messages = incoming
            hasMore = feed.has_more ?? false
        } else {
            // Merge the tail poll: update rows in place, append unseen ones.
            var merged = messages
            var index = [String: Int]()
            for (i, m) in merged.enumerated() { index[m.id] = i }
            for item in incoming {
                if let i = index[item.id] {
                    if merged[i] != item { merged[i] = item }
                } else {
                    merged.append(item)
                }
            }
            messages = merged
            hasMore = hasMore || (feed.has_more ?? false)
        }

        // Drop the optimistic echo once the server shows the message.
        if let pending = pendingSend,
           incoming.contains(where: { $0.kind == "user" && $0.text == pending }) {
            pendingSend = nil
        }
    }

    func loadOlder() {
        let next = min(limit * 2, Self.maxLimit)
        guard next != limit else { return }
        limit = next
        Task { await load(full: true) }
    }

    private func refreshBurst() {
        Task {
            for delay in Self.burstDelaysMs {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                await load(full: false)
            }
        }
    }

    // MARK: Actions

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        pendingSend = trimmed
        Task {
            do {
                try await api.send(projectId: projectId, slug: slug, text: trimmed)
                refreshBurst()
            } catch {
                pendingSend = nil
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    func answer(question: ConversationQuestion, selected: [String: [String]], custom: String) {
        guard let questionId = question.id, !answering else { return }
        answering = true
        answerFeedback = ""
        let ids = question.questions?.flatMap { selected[$0.id] ?? [] } ?? []
        Task {
            do {
                try await api.answer(
                    projectId: projectId,
                    slug: slug,
                    questionId: questionId,
                    selectedIds: ids,
                    customText: custom
                )
                refreshBurst()
            } catch {
                answerFeedback = error.localizedDescription
            }
            answering = false
        }
    }

    // MARK: The Loom flow

    /// The three prompts the web console's toolbar pastes. Same wording, so a
    /// task driven from the desktop and one driven from the browser leave the
    /// same trail in `PLAN.md`.
    enum FlowStep: String, CaseIterable, Identifiable {
        case interview, goal, result

        var id: String { rawValue }

        var label: String {
            switch self {
            case .interview: return "Deep Interview"
            case .goal: return "Run /goal"
            case .result: return "Write result"
            }
        }

        var symbol: String {
            switch self {
            case .interview: return "text.bubble"
            case .goal: return "play"
            case .result: return "square.and.pencil"
            }
        }

        var help: String {
            switch self {
            case .interview:
                return "Paste the deep-interview prompt (goal + skills) into the pane"
            case .goal:
                return "Paste /goal, which runs the agent against PLAN.md"
            case .result:
                return "Ask the agent to write progress and results back into PLAN.md"
            }
        }
    }

    /// Where the agent should keep the plan: the server's own answer when it
    /// has one, so the flow writes to the file the Plan tab reads.
    private var planPath: String { serverPlanPath ?? ".RUD/\(slug)/PLAN.md" }

    func run(_ step: FlowStep) {
        guard !sending else { return }
        sending = true
        Task {
            do {
                switch step {
                case .interview:
                    try await api.pasteInterviewPrompt(projectId: projectId, slug: slug)
                case .goal:
                    try await api.send(
                        projectId: projectId,
                        slug: slug,
                        text: """
                        /goal Execute the task plan in \(planPath). Keep \(planPath) \
                        updated with useful progress, blockers, decisions, and final \
                        results. Do not create separate status files.
                        """
                    )
                case .result:
                    try await api.send(
                        projectId: projectId,
                        slug: slug,
                        text: """
                        Please summarize the current execution result back into \(planPath).

                        Update only useful information:
                        - what was done
                        - important decisions
                        - test/eval results
                        - blockers or follow-up work
                        - final status

                        Remove obsolete noisy details, but preserve unrelated prior \
                        sections. Do not create separate status files.
                        """
                    )
                }
                refreshBurst()
                planRevision += 1
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    /// Sends Escape into the agent's pane — the "stop what you're doing" nudge.
    func interrupt() {
        guard !paneTarget.isEmpty else { return }
        Task {
            try? await api.sendKey(target: paneTarget, key: "Escape")
            refreshBurst()
        }
    }

    func startAgent() {
        guard !starting else { return }
        starting = true
        Task {
            do {
                _ = try await api.startAgent(projectId: projectId, slug: slug)
                await loadDetail()
                refreshBurst()
            } catch {
                self.error = error.localizedDescription
            }
            starting = false
        }
    }

    func stopAgent() {
        guard !starting else { return }
        starting = true
        Task {
            do {
                try await api.stopAgent(projectId: projectId, slug: slug)
                await loadDetail()
            } catch {
                self.error = error.localizedDescription
            }
            starting = false
        }
    }

    // MARK: Sessions

    @Published private(set) var sessions: [SessionInfo] = []

    func loadSessions() {
        Task {
            guard let list = try? await api.sessions(projectId: projectId, slug: slug) else { return }
            // Newest first: resuming almost always means "the one I was just
            // in", and on-disk transcripts arrive in no useful order.
            sessions = (list.sessions ?? []).sorted { ($0.mtime ?? 0) > ($1.mtime ?? 0) }
        }
    }

    // MARK: Run monitor

    /// Whether Loom watches this task's pane for a phrase meaning it finished
    /// or got stuck, and says so even when no one is looking at the pane.
    @Published private(set) var monitorOn = false
    @Published private(set) var monitorBusy = false

    /// Read once when the menu that shows it first opens, rather than on every
    /// detail poll: it changes only when someone changes it.
    func loadMonitor() {
        Task {
            guard let status = try? await api.monitor(projectId: projectId, slug: slug)
            else { return }
            monitorOn = status.isOn
        }
    }

    func setMonitor(_ on: Bool) {
        guard !monitorBusy else { return }
        monitorBusy = true
        Task {
            if let status = try? await api.setMonitor(
                projectId: projectId, slug: slug, on: on
            ) {
                monitorOn = status.isOn
            }
            monitorBusy = false
        }
    }

    /// Reopens a past session in a fresh pane, even if its tmux was killed.
    func resume(_ session: SessionInfo) {
        guard !starting else { return }
        starting = true
        Task {
            do {
                _ = try await api.resumeSession(
                    projectId: projectId, slug: slug, sessionId: session.id
                )
                await loadDetail()
                refreshBurst()
            } catch {
                self.error = error.localizedDescription
            }
            starting = false
        }
    }
}
