import Foundation
import WatchKit

/// One open task on the watch: the tail of its conversation, and the few
/// things worth doing about it from a wrist — answer, reply, interrupt,
/// start or stop the agent.
///
/// `ChatSession` does this for the iPhone and the Mac, but it opens a task by
/// reading its full detail, which inlines every markdown file under it — tens
/// of megabytes for some worktrees, far past what a watch should download.
/// The pane target comes from the sessions list instead, a few hundred bytes.
@MainActor
final class TaskSession: ObservableObject {
    let ref: TaskRef

    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var loaded = false
    @Published private(set) var error = ""
    @Published private(set) var available = true
    @Published private(set) var online = false
    @Published private(set) var working = false
    @Published private(set) var paneTarget: String
    /// Optimistic echo of a message the server has not shown back yet.
    @Published private(set) var pendingSend: String?
    @Published private(set) var sending = false
    @Published private(set) var answering = false
    /// Starting or stopping the agent.
    @Published private(set) var controlling = false
    @Published var failure: Failure?

    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let action: String
        let reason: String
    }

    /// Hands each read back to the list, so its row is current on return.
    var onFeed: (@MainActor (ConversationFeed) -> Void)?

    private let api = LoomAPI()
    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0

    /// Slower than the iPhone's 1.5 s: each read is twenty messages over the
    /// phone's Bluetooth link, and a wrist is glanced at, not read.
    private static let workingInterval: TimeInterval = 3
    private static let idleInterval: TimeInterval = 8
    private static let maxBackoff: TimeInterval = 60
    private static let burstDelaysMs: [UInt64] = [0, 400, 1000, 2000]

    init(ref: TaskRef, paneTarget: String) {
        self.ref = ref
        self.paneTarget = paneTarget
    }

    func start() {
        guard pollTask == nil else { return }
        Task { await loadSessionInfo() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                let delay = self?.pollDelay ?? Self.idleInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private var pollDelay: TimeInterval {
        if failureStreak > 0 {
            return min(Self.idleInterval * pow(2, Double(min(failureStreak, 3))), Self.maxBackoff)
        }
        return working ? Self.workingInterval : Self.idleInterval
    }

    private func load() async {
        do {
            let feed = try await api.conversation(projectId: ref.projectId, slug: ref.slug, limit: 20)
            apply(feed)
            publish(\.error, "")
            failureStreak = 0
        } catch {
            if error.isCancellation { return }
            failureStreak += 1
            if messages.isEmpty { publish(\.error, error.localizedDescription) }
        }
        publish(\.loaded, true)
    }

    /// The pane the agent runs in, and whether it is alive. Read on open and
    /// after starting or stopping, not on every poll: it changes only then.
    private func loadSessionInfo() async {
        guard let info = try? await api.sessions(projectId: ref.projectId, slug: ref.slug) else { return }
        if let target = info.tmux_target, !target.isEmpty { publish(\.paneTarget, target) }
    }

    /// Assign only movement: every `@Published` assignment redraws, equal
    /// value or not, and this runs on every poll.
    private func publish<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TaskSession, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func apply(_ feed: ConversationFeed) {
        publish(\.available, feed.available ?? true)
        publish(\.online, feed.online ?? false)
        publish(\.working, feed.working ?? false)
        publish(\.messages, feed.messages ?? [])
        if let pending = pendingSend,
           messages.contains(where: { $0.kind == "user" && $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) == pending }) {
            pendingSend = nil
        }
        onFeed?(feed)
    }

    private func refreshBurst() {
        Task {
            for delay in Self.burstDelaysMs {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                await load()
            }
        }
    }

    private func report(_ action: String, _ error: Error) {
        WKInterfaceDevice.current().play(.failure)
        failure = Failure(action: action, reason: error.localizedDescription)
    }

    // MARK: Reading the feed

    private var lastUserIndex: Int? { messages.lastIndex { $0.kind == "user" } }

    /// The agent's latest words.
    var latestWords: String? {
        messages.last {
            $0.kind == "assistant" && !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text
    }

    /// What you last said to it, for the context its answer is in.
    var lastAsked: String? {
        guard let index = lastUserIndex else { return nil }
        let text = messages[index].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// A question still open, asked after your last message. Hidden while a
    /// reply is on its way, so the same question is not answered twice.
    var pendingQuestion: ConversationQuestion? {
        guard pendingSend == nil,
              let index = messages.lastIndex(where: { $0.kind == "question" }),
              index > (lastUserIndex ?? -1),
              let question = messages[index].question,
              question.status == "pending"
        else { return nil }
        return question
    }

    var runningTool: ConversationTool? {
        guard working else { return nil }
        return messages.last { $0.kind == "tool" && $0.tool?.status == "running" }?.tool
    }

    /// The tool calls since your last message, newest last.
    var recentSteps: [ConversationMessage] {
        let start = (lastUserIndex ?? -1) + 1
        guard start < messages.count else { return [] }
        return Array(messages[start...].filter { $0.kind == "tool" && $0.tool != nil }.suffix(5))
    }

    // MARK: Actions

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        pendingSend = trimmed
        Task {
            do {
                try await api.send(projectId: ref.projectId, slug: ref.slug, text: trimmed)
                WKInterfaceDevice.current().play(.success)
                refreshBurst()
            } catch {
                pendingSend = nil
                report("Message not sent", error)
            }
            sending = false
        }
    }

    /// A menu open in the pane is answered with its keys; any other question
    /// is answered the way a person would, by replying with the choice —
    /// the same split the iPhone's question card makes.
    func answer(_ question: ConversationQuestion, selected: [String: [String]], custom: String) {
        let prompts = question.questions ?? []
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.source == "terminal", let questionId = question.id {
            guard !answering else { return }
            answering = true
            let ids = prompts.flatMap { selected[$0.id] ?? [] }
            Task {
                do {
                    try await api.answer(
                        projectId: ref.projectId,
                        slug: ref.slug,
                        questionId: questionId,
                        selectedIds: ids,
                        customText: typed
                    )
                    WKInterfaceDevice.current().play(.success)
                    refreshBurst()
                } catch {
                    report("Answer not sent", error)
                }
                answering = false
            }
            return
        }
        let answers = prompts.map { prompt -> (prompt: String, values: [String]) in
            let values = (selected[prompt.id] ?? []).map { value -> String in
                let option = prompt.options.first { $0.value == value }
                if let option, Self.isOther(option), !typed.isEmpty { return typed }
                return value
            }
            return (prompt.prompt, values)
        }
        let text = answers.count == 1
            ? answers[0].values.joined(separator: ", ")
            : answers.map { "\($0.prompt)\n\($0.values.joined(separator: ", "))" }.joined(separator: "\n\n")
        send(text)
    }

    static func isOther(_ option: ConversationOption) -> Bool {
        option.label.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("other")
    }

    /// Escape into the pane — "stop what you're doing", short of stopping it.
    func interrupt() {
        guard !paneTarget.isEmpty else { return }
        Task {
            do {
                try await api.sendKey(target: paneTarget, key: "Escape")
                WKInterfaceDevice.current().play(.stop)
                refreshBurst()
            } catch {
                report("Esc didn't reach the agent", error)
            }
        }
    }

    func startAgent() {
        guard !controlling else { return }
        controlling = true
        Task {
            do {
                let result = try await api.startAgent(projectId: ref.projectId, slug: ref.slug)
                if let target = result.target, !target.isEmpty { publish(\.paneTarget, target) }
                await loadSessionInfo()
                WKInterfaceDevice.current().play(.start)
                refreshBurst()
            } catch {
                report("Couldn't start the agent", error)
            }
            controlling = false
        }
    }

    func stopAgent() {
        guard !controlling else { return }
        controlling = true
        Task {
            do {
                try await api.stopAgent(projectId: ref.projectId, slug: ref.slug)
                WKInterfaceDevice.current().play(.stop)
                refreshBurst()
            } catch {
                report("Couldn't stop the agent", error)
            }
            controlling = false
        }
    }
}
