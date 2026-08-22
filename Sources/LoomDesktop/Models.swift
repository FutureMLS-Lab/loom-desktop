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
    /// The directory the server was launched in. A new folder may only be
    /// created inside it, so the Add sheet offers its children as shortcuts
    /// and says so when a path is rejected.
    var launchRoot: String?
    var launchRootChildren: [LaunchChild]?

    struct LaunchChild: Decodable, Identifiable, Equatable {
        var name: String
        var path: String

        var id: String { path }
    }
}

/// How `POST /api/projects` should get a directory before registering it.
enum ProjectSource: String, CaseIterable, Identifiable {
    case existing, empty, clone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .existing: return "Existing folder"
        case .empty: return "New folder"
        case .clone: return "Clone a repo"
        }
    }
}

struct LoomTaskMeta: Decodable, Equatable {
    var slug: String
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
    // `templates` and `task_markdown_files` are deliberately not decoded. The
    // server inlines the full text of every markdown file it finds anywhere
    // under the task, worktree included — 13 MB for a task holding a
    // documented repository. Nothing here needs it: the plan digest and the
    // Files tab both read what they show through `/files`, a directory at a
    // time. Naming the fields would rebuild all of it on every read.
    /// Where the server says the plan lives, which is what the flow prompts
    /// should name so the agent writes to the same file the viewer reads.
    var plan_path: String?

    /// Best-known tmux target for the agent pane. The server reports it three
    /// ways depending on how the pane was started, so take them in the order
    /// the web console does.
    var paneTarget: String {
        claude?.tmux_target ?? claude?.target ?? meta.tmux_interview_target ?? ""
    }
}

// MARK: - Browsing the task directory

/// One reply from `/api/tasks/<slug>/files`: either a directory's entries or
/// a single file's text. `error` explains a file the server will not send —
/// binary, or larger than an editor should hold.
struct TaskFileListing: Decodable {
    struct Entry: Decodable, Identifiable, Equatable {
        var name: String
        var dir: Bool
        var size: Int?

        var id: String { name }
    }

    var path: String?
    var dir: Bool?
    var entries: [Entry]?
    var body: String?
    var size: Int?
    var error: String?
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

// MARK: - Worktrees

/// A repository the task could base a worktree on, as the server offers it.
/// `alreadyCreated` is why the picker can show a repo without letting you add
/// it twice.
struct WorktreeCandidate: Decodable, Identifiable, Equatable {
    var path: String
    var name: String
    var kind: String?
    var destination: String?
    var already_created: Bool?

    var id: String { path }
    var alreadyCreated: Bool { already_created ?? false }
    /// The server's own pick for the repo this task is really about.
    var isPreferred: Bool { kind == "preferred" }
}

struct WorktreeCandidates: Decodable {
    var candidates: [WorktreeCandidate]?
    var worktrees: [String]?
}

/// One row of `push-all`. The request succeeds even when a push does not, so
/// the caller has to read these rather than trust the status code.
struct PushResult: Decodable {
    var ok: Bool?
    var path: String?
    var branch: String?
    var message: String?
    var error: String?
}

struct PushAllResult: Decodable {
    var ok: Bool?
    var count: Int?
    var results: [PushResult]?
}

// MARK: - Run monitor

/// Whether Loom is watching this task's pane for a finishing phrase.
/// `enabled` mirrors whether the watcher thread is actually alive, so it is
/// the one to trust over anything the app remembers.
struct MonitorStatus: Decodable {
    var enabled: Bool?
    var running: Bool?
    var pattern: String?
    var default_pattern: String?
    var last_fired: String?
    var last_match: String?

    var isOn: Bool { enabled ?? false }
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
