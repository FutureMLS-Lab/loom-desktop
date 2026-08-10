import Foundation

/// Where the dock's connection settings live. The same base URL + token pair
/// works against either the loom-app gateway (which injects the Loom token
/// itself) or a `loom web --auth-token …` instance directly — the API paths
/// are identical.
enum LoomSettings {
    static let baseURLKey = "loomBaseURL"
    static let tokenKey = "loomAuthToken"
    static let defaultBaseURL = "http://127.0.0.1:8787"

    static var baseURL: String {
        let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? defaultBaseURL : trimmed
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    static var token: String {
        (UserDefaults.standard.string(forKey: tokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LoomAPIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

/// Thin async client for the Loom HTTP API. Reads the base URL and token from
/// UserDefaults on every call so settings changes apply without a restart.
struct LoomAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil
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

        let (data, response) = try await Self.session.data(for: req)
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

    func tasks(projectId: String) async throws -> [LoomTaskMeta] {
        let out: TasksResponse = try await request(scoped("/api/tasks", projectId))
        return out.tasks ?? []
    }

    func activity() async throws -> ActivitySnapshot {
        try await request("/api/activity")
    }

    func ackActivity(projectId: String, slug: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/activity/ack", projectId),
            method: "POST",
            body: ["slug": slug]
        )
    }

    // MARK: Per-task

    func taskDetail(projectId: String, slug: String) async throws -> TaskDetail {
        try await request(scoped("/api/tasks/\(slugPath(slug))", projectId))
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

    func forceSend(projectId: String, slug: String) async throws {
        let _: OkResponse = try await request(
            scoped("/api/tasks/\(slugPath(slug))/claude/force-send", projectId),
            method: "POST"
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
            body: ["path": path]
        )
    }

    /// Merge the worktree's branch into its base. Server-side this refuses on
    /// a dirty tree and aborts on conflicts, and never pushes.
    func mergeWorktree(projectId: String, slug: String, path: String) async throws -> OkResponse {
        try await request(
            scoped("/api/tasks/\(slugPath(slug))/worktree/merge", projectId),
            method: "POST",
            body: ["path": path]
        )
    }

    /// Pane scrollback as plain text — what the terminal view renders.
    func capture(target: String, lines: Int = 400) async throws -> TerminalCapture {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
        return try await request("/api/tmux/capture?target=\(encoded)&lines=\(lines)")
    }

    /// Raw keystrokes/bytes, which is how IME-composed text (Chinese, emoji,
    /// anything multi-byte) has to reach the pane — key names cannot carry it.
    func sendLiteral(target: String, text: String) async throws {
        let _: OkResponse = try await request(
            "/api/tmux/send-literal",
            method: "POST",
            body: ["target": target, "text": text]
        )
    }

}
