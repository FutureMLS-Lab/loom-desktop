import Foundation

// MARK: - Projects & tasks

struct LoomProject: Decodable, Identifiable, Equatable {
    let id: String
    let path: String
    var name: String?
    var title: String?

    /// Human label: explicit title/name, else the last path component.
    var label: String {
        if let title, !title.isEmpty { return title }
        if let name, !name.isEmpty { return name }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }
}

struct ProjectsResponse: Decodable {
    var projects: [LoomProject]?
}

struct LoomTaskMeta: Decodable, Equatable {
    let slug: String
    var title: String?
    var general_goal: String?
    var kind: String?
    var agent: String?
    var tmux_interview_target: String?
}

struct TasksResponse: Decodable {
    var tasks: [LoomTaskMeta]?
}

struct TaskDetail: Decodable {
    struct AgentStatus: Decodable {
        var session: String?
        var target: String?
        var tmux_target: String?
        var tmux_alive: Bool?
        var agent_running: Bool?
        var agent: String?
    }

    struct WorktreeStatus: Decodable, Identifiable, Equatable {
        var path: String
        var branch: String?
        var upstream: String?
        var has_remote: Bool?
        var ahead: Int?
        var behind: Int?
        var staged: Int?
        var unstaged: Int?
        var untracked: Int?
        var clean: Bool?
        var dirty_count: Int?

        var id: String { path }

        /// Last path component — the repo name, which is what identifies a
        /// worktree in a task that has several.
        var repoName: String { (path as NSString).lastPathComponent }
    }

    var meta: LoomTaskMeta
    var claude: AgentStatus?
    var worktree_statuses: [WorktreeStatus]?
    /// File name → contents. `PLAN.md` lives here.
    var templates: [String: String]?
    /// Names only, of the markdown the server scanned in the task directory.
    var task_markdown_files: [String]?
    /// Where the server says the plan lives, which is what the flow prompts
    /// should name so the agent writes to the same file the viewer reads.
    var plan_path: String?

    /// Best-known tmux target for the agent pane, mirroring the app's
    /// `agentTarget()` helper.
    var paneTarget: String {
        claude?.tmux_target ?? claude?.target ?? meta.tmux_interview_target ?? ""
    }
}

// MARK: - Activity (the dock's heartbeat)

struct ActivityTask: Decodable, Equatable {
    var project: String
    var slug: String
    var working: Bool
    /// Epoch seconds of an unacknowledged finish; 0 once seen.
    var finished_at: Double?
}

struct ActivitySnapshot: Decodable, Equatable {
    var ok: Bool?
    var tasks: [String: ActivityTask]?
}

// MARK: - Conversation feed (the chat module)

struct ConversationTool: Decodable, Equatable {
    var name: String
    var summary: String?
    var status: String // running | completed | error | canceled
    var input: String?
    var output: String?
}

struct ConversationOption: Decodable, Equatable, Identifiable {
    var id: String
    var label: String
    var description: String?
    var value: String
    var selected: Bool?
}

struct ConversationPrompt: Decodable, Equatable, Identifiable {
    var id: String
    var header: String?
    var prompt: String
    var allow_multiple: Bool?
    var options: [ConversationOption]
}

struct ConversationQuestion: Decodable, Equatable {
    var id: String?
    var title: String?
    var status: String // pending | answered | error | canceled
    var answer: String?
    var questions: [ConversationPrompt]?
}

struct ConversationMessage: Decodable, Equatable, Identifiable {
    var id: String
    var kind: String // user | assistant | tool | question | event
    var text: String?
    var created_at: Double?
    var tool: ConversationTool?
    var question: ConversationQuestion?
}

struct ConversationFeed: Decodable, Equatable {
    var ok: Bool?
    var available: Bool?
    var agent: String?
    var online: Bool?
    var working: Bool?
    var session_id: String?
    var updated_at: Double?
    var messages: [ConversationMessage]?
    var total: Int?
    var has_more: Bool?
}

// MARK: - Diff (the Changes tab)

struct DiffFile: Decodable, Identifiable {
    var path: String
    var status: String?
    var patch: String?
    var additions: Int?
    var deletions: Int?
    var worktree: String?
    var worktreePath: String?

    var id: String { "\(worktree ?? "")/\(path)" }
}

struct WorktreeDiff: Decodable {
    var path: String?
    var branch: String?
    var base: String?
    var files: [DiffFile]?
    var error: String?
}

struct TaskDiff: Decodable {
    var slug: String?
    var worktrees: [WorktreeDiff]?
}

// MARK: - Agent sessions

struct SessionInfo: Decodable, Identifiable, Equatable {
    var id: String
    var path: String?
    var mtime: Double?
    var size: Int?

    var lastUsed: Date? { mtime.map { Date(timeIntervalSince1970: $0) } }
}

struct SessionList: Decodable {
    var sessions: [SessionInfo]?
    /// Sessions Loom itself started for this task, newest last.
    var tracked: [String]?
    var agent: String?
    var agent_label: String?
    var agent_running: Bool?
    var tmux_alive: Bool?
    var tmux_target: String?
}

struct TerminalCapture: Decodable {
    var ok: Bool?
    var text: String?
    var error: String?
}

// MARK: - Small acknowledgement payloads

struct OkResponse: Decodable {
    var ok: Bool?
    var error: String?
}

struct AgentStartResult: Decodable {
    var ok: Bool?
    var target: String?
    var already_running: Bool?
    var error: String?
}
