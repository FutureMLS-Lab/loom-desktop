import Foundation

struct LoomAPIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

/// Thin async client for the Loom HTTP API. Reads the base URL and token from
/// `LoomSettings` on every call, so switching server or editing one applies
/// without a restart.
struct LoomAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// How long a call is allowed to take. Most of Loom answers in under a
    /// second; two kinds do not, for reasons the app cannot shorten, and each
    /// gets exactly as much rope as its reason justifies.
    enum Patience {
        /// Loom answering about itself.
        case standard
        /// A read whose size the server decides. The task detail inlines every
        /// markdown file under the task, which is kilobytes for most and tens
        /// of megabytes for a worktree full of documentation. Bounded on
        /// purpose: past this the answer is not worth the connection it would
        /// hold, and giving up says so.
        case large
        /// Waiting on git rather than on Loom — a clone, or a push across
        /// several worktrees, which genuinely runs for minutes.
        case git
    }

    private static let largeSession: URLSession = session(request: 60, resource: 90)
    private static let gitSession: URLSession = session(request: 120, resource: 900)

    private static func session(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request
        config.timeoutIntervalForResource = resource
        return URLSession(configuration: config)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        patience: Patience = .standard
    ) async throws -> T {
        guard let url = URL(string: LoomSettings.baseURL + path) else {
            throw LoomAPIError(message: "Invalid Loom URL", status: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = LoomSettings.token
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
        }

        let session: URLSession = {
            switch patience {
            case .standard: return Self.session
            case .large: return Self.largeSession
            case .git: return Self.gitSession
            }
        }()
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode(OkResponse.self, from: data))?.error
            throw LoomAPIError(
                message: detail ?? "Loom request failed (\(status))",
                status: status
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func scoped(_ path: String, _ projectId: String) -> String {
        let sep = path.contains("?") ? "&" : "?"
        let encoded = projectId.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? projectId
        return "\(path)\(sep)project=\(encoded)"
    }

    private func slugPath(_ slug: String) -> String {
        slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
    }

    // MARK: Fleet

    func projects() async throws -> [LoomProject] {
        let out: ProjectsResponse = try await request("/api/projects")
        return out.projects ?? []
    }

    /// The same call, kept whole for the Add sheet, which also needs the root
    /// new folders must live under and its children to offer as shortcuts.
    func workspace() async throws -> ProjectsResponse {
        try await request("/api/projects")
    }

    /// Registers a directory as a project. `source` decides how it is obtained
    /// first: an existing directory, one created now, or one cloned — the last
    /// two only inside the server's launch root, which the server enforces.
    func addProject(
        path: String,
        source: ProjectSource,
        repoURL: String = "",
        codeRoot: String = "."
    ) async throws {
        var body: [String: Any] = [
            "path": path,
            "mode": source.rawValue,
            "code_root_pattern": codeRoot.isEmpty ? "." : codeRoot,
        ]
        if source == .clone { body["repo_url"] = repoURL }
        let _: OkResponse = try await request(
            "/api/projects",
            method: "POST",
            body: body,
            patience: source == .clone ? .git : .standard
        )
    }

    /// Unregisters a project. The directory and everything in it stays.
    func removeProject(id: String) async throws {
        let _: OkResponse = try await request(
            "/api/projects/\(slugPath(id))",
            method: "DELETE"
        )
    }

    /// Where inside the project its code lives, as a path relative to the
    /// project root — this is what worktree candidates are searched under.
    func setCodeRoot(id: String, pattern: String) async throws {
        let _: OkResponse = try await request(
            "/api/projects/\(slugPath(id))/code-root",
            method: "POST",
            body: ["pattern": pattern.isEmpty ? "." : pattern]
        )
    }

    func tasks(projectId: String) async throws -> [LoomTaskMeta] {
        let out: TasksResponse = try await request(scoped("/api/tasks", projectId))
        return out.tasks ?? []
    }

    func activity() async throws -> ActivitySnapshot {
        try await request("/api/activity")
    }

    /// The order tasks are listed in, which Loom stores and every client
    /// reads back — drag one in the app and the browser agrees.
    func reorderTasks(projectId: String, slugs: [String]) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/reorder", projectId),
            method: "POST",
            body: ["slugs": slugs]
        )
    }

    func reorderProjects(ids: [String]) async throws {
        let _: OkResponse = try await request(
            "/api/projects/reorder",
            method: "POST",
            body: ["ids": ids]
        )
    }

    func ackActivity(projectId: String, slug: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/activity/ack", projectId),
            method: "POST",
            body: ["slug": slug]
        )
    }

    // MARK: Project notes

    /// `<project>/.RUD/NOTES.md` — one scratchpad per project, shared with the
    /// web console, which reads and writes the same file.
    func notes(projectId: String) async throws -> String {
        struct Notes: Decodable { var content: String? }
        let out: Notes = try await request(scoped("/api/notes", projectId))
        return out.content ?? ""
    }

    func saveNotes(projectId: String, content: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/notes", projectId),
            method: "PUT",
            body: ["content": content]
        )
    }

    // MARK: Per-task

    /// Given longer than the rest, because this one is not sized by anything
    /// the app controls: the server inlines every markdown file under the
    /// task, which for a worktree holding a JavaScript dependency tree has
    /// measured 655 MB. Longer, but still bounded — past a minute the answer
    /// costs more than the tmux target it carries is worth, and the caller
    /// says so rather than holding the connection open.
    func taskDetail(projectId: String, slug: String) async throws -> TaskDetail {
        try await request(scoped("/api/tasks/\(slugPath(slug))", projectId), patience: .large)
    }

    /// One level of the task directory, or one file's text. The Files tab
    /// asks per directory rather than for a tree, so opening a task with a
    /// large worktree costs a single listing.
    func taskFiles(
        projectId: String,
        slug: String,
        path: String = ""
    ) async throws -> TaskFileListing {
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? path
        let query = encoded.isEmpty ? "" : "?path=\(encoded)"
        return try await request(
            scoped("/api/tasks/\(slugPath(slug))/files\(query)", projectId)
        )
    }

    /// Writes an allowed task template (`PLAN.md` / `WIKI.md`) on the server.
    func writeTemplate(
        projectId: String,
        slug: String,
        name: String,
        content: String
    ) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/template", projectId),
            method: "PUT",
            body: ["name": name, "content": content]
        )
    }

    func conversation(
        projectId: String, slug: String, limit: Int
    ) async throws -> ConversationFeed {
        let clamped = max(20, min(500, limit))
        return try await request(
            scoped("/api/tasks/\(slugPath(slug))/conversation?limit=\(clamped)", projectId)
        )
    }

    func send(projectId: String, slug: String, text: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/claude/send", projectId),
            method: "POST",
            body: ["text": text, "submit": true]
        )
    }

    func answer(
        projectId: String,
        slug: String,
        questionId: String,
        selectedIds: [String],
        customText: String
    ) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/conversation/answer", projectId),
            method: "POST",
            body: [
                "question_id": questionId,
                "selected_ids": selectedIds,
                "custom_text": customText,
            ]
        )
    }

    /// Re-pastes the task's deep-interview prompt (goal + skills) into the pane.
    func pasteInterviewPrompt(projectId: String, slug: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/interview/paste-prompt", projectId),
            method: "POST"
        )
    }

    /// Creates a task. The server slugifies the title and lays out
    /// `.RUD/<slug>/`; the worktree is created on first agent start.
    func createTask(
        projectId: String,
        title: String,
        goal: String,
        agent: String
    ) async throws -> LoomTaskMeta {
        struct Created: Decodable {
            var meta: LoomTaskMeta?
            var slug: String?
            var title: String?
        }
        let created: Created = try await request(
            scoped("/api/tasks", projectId),
            method: "POST",
            body: ["title": title, "general_goal": goal, "agent": agent]
        )
        if let meta = created.meta { return meta }
        return LoomTaskMeta(
            slug: created.slug ?? "",
            title: created.title ?? title,
            general_goal: goal,
            kind: nil,
            agent: agent,
            tmux_interview_target: nil
        )
    }

    /// Past agent sessions for this task, plus the live pane's status.
    func sessions(projectId: String, slug: String) async throws -> SessionList {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/claude-sessions", projectId)
        )
    }

    /// Reopens a past session in a fresh pane (`--resume <id>`), which works
    /// even when the original tmux was killed.
    func resumeSession(
        projectId: String,
        slug: String,
        sessionId: String
    ) async throws -> AgentStartResult {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/claude/resume", projectId),
            method: "POST",
            body: ["session_id": sessionId]
        )
    }

    func stopAgent(projectId: String, slug: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/interview/stop", projectId),
            method: "POST"
        )
    }

    func startAgent(projectId: String, slug: String) async throws -> AgentStartResult {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/interview/start", projectId),
            method: "POST"
        )
    }

    func sendKey(target: String, key: String) async throws {
        let _: OkResponse = try await request(
            "/api/tmux/send-key",
            method: "POST",
            body: ["target": target, "key": key]
        )
    }

    func diff(projectId: String, slug: String) async throws -> TaskDiff {
        try await request(scoped("/api/tasks/\(slugPath(slug))/diff", projectId))
    }

    /// `git push -u origin <branch>` for one worktree.
    func pushWorktree(projectId: String, slug: String, path: String) async throws -> OkResponse {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktree/push", projectId),
            method: "POST",
            body: ["path": path],
            patience: .git
        )
    }

    /// Merge the worktree's branch into its base. Server-side this refuses on
    /// a dirty tree and aborts on conflicts, and never pushes.
    func mergeWorktree(projectId: String, slug: String, path: String) async throws -> OkResponse {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktree/merge", projectId),
            method: "POST",
            body: ["path": path],
            patience: .git
        )
    }

    /// The repositories this task could branch from. The server marks the one
    /// it considers the project's own, and which are already checked out.
    func worktreeCandidates(
        projectId: String, slug: String
    ) async throws -> WorktreeCandidates {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktree-candidates", projectId)
        )
    }

    /// Adds a worktree for `repoPath`, which the server will only accept if it
    /// is one of the candidates it just offered.
    func addWorktree(projectId: String, slug: String, repoPath: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktree", projectId),
            method: "POST",
            body: ["source_repo": repoPath],
            patience: .git
        )
    }

    /// Removes a worktree — this one does delete the checkout on disk, though
    /// the branch and its commits survive in the repository it came from.
    func removeWorktree(projectId: String, slug: String, path: String) async throws {
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? path
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktree?path=\(encoded)", projectId),
            method: "DELETE"
        )
    }

    /// Pushes every worktree the task has. This answers 200 even when a push
    /// failed, so the result has to be read row by row.
    func pushAllWorktrees(projectId: String, slug: String) async throws -> PushAllResult {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktrees/push-all", projectId),
            method: "POST",
            patience: .git
        )
    }

    // MARK: Run monitor

    func monitor(projectId: String, slug: String) async throws -> MonitorStatus {
        try await request(scoped("/api/tasks/\(slugPath(slug))/monitor", projectId))
    }

    /// Watches the pane for a phrase that means the agent is done or stuck.
    /// An empty pattern asks for the server's own, which is what the app sends.
    func setMonitor(
        projectId: String, slug: String, on: Bool
    ) async throws -> MonitorStatus {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/monitor", projectId),
            method: on ? "POST" : "DELETE",
            body: on ? ["pattern": ""] : nil
        )
    }

    /// A live attachment to the pane's pty, which is what the web terminal
    /// uses. Unlike `capture`, this carries the raw byte stream — colour,
    /// cursor motion, the lot — and tells tmux to size the pane to the client,
    /// so the output is laid out for the window it will be read in.
    func streamRequest(target: String, cols: Int, rows: Int) -> URLRequest? {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
        guard let url = URL(
            string: "\(LoomSettings.baseURL)/api/tmux/stream?target=\(encoded)&cols=\(cols)&rows=\(rows)"
        ) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let token = LoomSettings.token
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Browse the pane's history. The wheel cannot be left to the terminal:
    /// a full-screen app turns it into arrow keys, which Claude reads as
    /// "previous prompt" rather than "scroll up". tmux does the scrolling.
    func scroll(target: String, direction: String, lines: Int) async throws {
        let _: OkResponse = try await request(
            "/api/tmux/scroll",
            method: "POST",
            body: [
                "target": target,
                "dir": direction,
                "lines": max(1, min(80, lines)),
            ]
        )
    }

    /// Paste text into the pane, optionally pressing Enter afterwards.
    ///
    /// Not the same as writing the text and a `\r` to the stream: an agent
    /// reads bracketed paste asynchronously, and an Enter arriving in the same
    /// pty read as the paste-end marker gets absorbed — the text appears at the
    /// prompt and simply sits there. The server pastes, waits, then sends Enter
    /// as its own read.
    func sendText(target: String, text: String, submit: Bool) async throws {
        let _: OkResponse = try await request(
            "/api/tmux/send-text",
            method: "POST",
            body: ["target": target, "text": text, "submit": submit]
        )
    }

    /// A figure referenced by a markdown document, fetched as bytes.
    ///
    /// Without a task the base is the project's `.RUD/`, which is where
    /// `NOTES.md` and its images live; with one it is that task's directory.
    func asset(projectId: String, task: String, path: String) async throws -> (Data, String) {
        var components = URLComponents(string: LoomSettings.baseURL + "/api/asset")
        components?.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "project", value: projectId),
        ] + (task.isEmpty ? [] : [URLQueryItem(name: "task", value: task)])
        guard let url = components?.url else {
            throw LoomAPIError(message: "Invalid asset URL", status: 0)
        }
        var request = URLRequest(url: url)
        let token = LoomSettings.token
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await Self.session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw LoomAPIError(
                message: "Asset unavailable (\(http?.statusCode ?? 0))",
                status: http?.statusCode ?? 0
            )
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, type)
    }

    /// End a stream deliberately, rather than trusting the disconnect to be
    /// noticed. The gateway holds its upstream leg open after we go away, so
    /// the server never sees the close and its `tmux attach` — a real client,
    /// pinning the pane's size — outlives every terminal ever opened.
    func closeStream(streamId: String) async throws {
        let _: OkResponse = try await request(
            "/api/tmux/stream-close",
            method: "POST",
            body: ["stream_id": streamId]
        )
    }

    /// The same close, but blocking, for the moment the app is quitting —
    /// where an async task would be cut off before its request left.
    func closeStreamNow(streamId: String, timeout: TimeInterval = 2) {
        guard let url = URL(string: LoomSettings.baseURL + "/api/tmux/stream-close") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = LoomSettings.token
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["stream_id": streamId])
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Keystrokes for an attached stream. This writes to the pty, so the keys a
    /// terminal sends are just their bytes — no tmux key names to get wrong.
    func streamInput(streamId: String, text: String) async throws {
        let _: OkResponse = try await request(
            "/api/tmux/stream-input",
            method: "POST",
            body: ["stream_id": streamId, "text": text]
        )
    }

}
