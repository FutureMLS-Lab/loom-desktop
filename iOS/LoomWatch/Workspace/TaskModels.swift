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

    init(projectId: String, slug: String) {
        self.projectId = projectId
        self.slug = slug
    }

    /// From the `project/slug` key the activity snapshot and notifications
    /// use. Split at the last slash: slugs never contain one.
    init?(key: String) {
        guard let slash = key.lastIndex(of: "/") else { return nil }
        let project = String(key[..<slash])
        let slug = String(key[key.index(after: slash)...])
        guard !project.isEmpty, !slug.isEmpty else { return nil }
        self.init(projectId: project, slug: slug)
    }
}

/// The tail of a task's conversation, read for its row: the agent's latest
/// words, what it is running, and a question it is waiting on.
struct TaskPreview: Equatable {
    var text: String
    var running: String?
    var question: ConversationQuestion?
    /// The state the task was in when this was read. Once that moves on, the
    /// preview describes a moment that has passed and is read again.
    var state: TaskActivity?
    var fetchedAt: Date

    init(text: String, running: String?, question: ConversationQuestion?, state: TaskActivity?, fetchedAt: Date) {
        self.text = text
        self.running = running
        self.question = question
        self.state = state
        self.fetchedAt = fetchedAt
    }

    init(feed: ConversationFeed, state: TaskActivity?, fetchedAt: Date = Date()) {
        let messages = feed.messages ?? []
        let lastWords = messages.lastIndex { $0.kind == "assistant" && !($0.text ?? "").isEmpty }
        let lastTool = messages.lastIndex { $0.kind == "tool" }
        let lastUser = messages.lastIndex { $0.kind == "user" }
        var running: String?
        if feed.working == true, let lastTool, lastTool > (lastWords ?? -1), let tool = messages[lastTool].tool {
            running = tool.summary.flatMap { $0.isEmpty ? nil : $0 } ?? tool.name
        }
        // Only a question asked after your last message is still open: one
        // you have replied to, however, stays "pending" in the transcript.
        var question: ConversationQuestion?
        if let index = messages.lastIndex(where: { $0.kind == "question" }), index > (lastUser ?? -1),
           let pending = messages[index].question, pending.status == "pending" {
            question = pending
        }
        self.init(
            text: lastWords.map { WatchText.plain(messages[$0].text ?? "") } ?? "",
            running: running,
            question: question,
            state: state,
            fetchedAt: fetchedAt
        )
    }
}

/// One task as a row draws it.
struct TaskItem: Identifiable, Equatable {
    let ref: TaskRef
    let meta: LoomTaskMeta
    let projectLabel: String
    let state: TaskActivity?
    let finishedAt: Date?
    let preview: TaskPreview?

    var id: String { ref.id }

    var title: String {
        if let title = meta.title, !title.isEmpty { return title }
        return meta.slug
    }

    /// A question read while the task was in the state it is still in. A
    /// task that went back to work has had its answer, wherever it came from.
    var question: ConversationQuestion? {
        guard let preview, preview.state == state, state != .working else { return nil }
        return preview.question
    }

    var needsYou: Bool { state == .finished || question != nil }
}
