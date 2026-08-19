import SwiftUI

/// The Changes tab: every file the agent touched across the task's worktrees,
/// plus a read-only unified-diff view per file (additions green, removals red,
/// hunk headers indigo — matching the web console's diff).
struct ChangesView: View {
    @ObservedObject var session: ChatSession

    @State private var files: [DiffFile] = []
    @State private var errors: [String] = []
    @State private var loading = true
    @State private var error = ""
    @State private var selection: DiffFile.ID?
    @State private var worktrees: [TaskDetail.WorktreeStatus] = []
    @State private var candidates: [WorktreeCandidate] = []
    @State private var busyPath: String?
    @State private var pushingAll = false
    @State private var actionResult = ""
    @State private var worktreeToRemove: TaskDetail.WorktreeStatus?

    var body: some View {
        VStack(spacing: 0) {
            // Shown even with no worktree yet: this is where you add the first
            // one, so hiding the bar until one exists left no way in.
            if !worktrees.isEmpty || !candidates.isEmpty {
                WorktreeBar(
                    worktrees: worktrees,
                    candidates: candidates,
                    busyPath: busyPath,
                    pushingAll: pushingAll,
                    result: actionResult,
                    onPush: { await act($0, merge: false) },
                    onMerge: { await act($0, merge: true) },
                    onAdd: { await addWorktree($0) },
                    onRemove: { worktreeToRemove = $0 },
                    onPushAll: { await pushAll() }
                )
                Divider()
            }
            content
        }
        .task { await load() }
        .confirmationDialog(
            "Remove \(worktreeToRemove?.repoName ?? "") from this task?",
            isPresented: Binding(
                get: { worktreeToRemove != nil },
                set: { if !$0 { worktreeToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let worktree = worktreeToRemove {
                    worktreeToRemove = nil
                    Task { await removeWorktree(worktree) }
                }
            }
            Button("Cancel", role: .cancel) { worktreeToRemove = nil }
        } message: {
            Text("The checkout is deleted. Its branch and commits stay in the "
                 + "repository it came from — push first if they only exist here.")
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !errors.isEmpty {
                    ForEach(errors, id: \.self) { message in
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundColor(LoomColors.amber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                Text("\(files.count) FILES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(files) { file in
                    Button {
                        selection = file.id
                    } label: {
                        FileRow(file: file, showWorktree: worktrees.count > 1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                selection == file.id ? LoomColors.accentSoft : Color.clear,
                                in: Rectangle()
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 10)
        }
        .background(LoomColors.bgBase)
    }

    private func act(_ worktree: TaskDetail.WorktreeStatus, merge: Bool) async {
        busyPath = worktree.path
        actionResult = ""
        do {
            let response = merge
                ? try await session.api.mergeWorktree(
                    projectId: session.projectId, slug: session.slug, path: worktree.path
                )
                : try await session.api.pushWorktree(
                    projectId: session.projectId, slug: session.slug, path: worktree.path
                )
            actionResult = response.error
                ?? (merge ? "Merged \(worktree.repoName)" : "Pushed \(worktree.repoName)")
        } catch {
            actionResult = error.localizedDescription
        }
        busyPath = nil
        await load()
    }

    private func addWorktree(_ candidate: WorktreeCandidate) async {
        busyPath = candidate.path
        actionResult = "Creating a worktree from \(candidate.name)…"
        do {
            try await session.api.addWorktree(
                projectId: session.projectId, slug: session.slug, repoPath: candidate.path
            )
            actionResult = "Added \(candidate.name)"
        } catch {
            actionResult = error.localizedDescription
        }
        busyPath = nil
        await load()
    }

    private func removeWorktree(_ worktree: TaskDetail.WorktreeStatus) async {
        busyPath = worktree.path
        actionResult = ""
        do {
            try await session.api.removeWorktree(
                projectId: session.projectId, slug: session.slug, path: worktree.path
            )
            actionResult = "Removed \(worktree.repoName)"
        } catch {
            actionResult = error.localizedDescription
        }
        busyPath = nil
        await load()
    }

    /// The server answers 200 even when a push failed, so the per-worktree
    /// rows are the only place the truth is.
    private func pushAll() async {
        pushingAll = true
        actionResult = ""
        do {
            let result = try await session.api.pushAllWorktrees(
                projectId: session.projectId, slug: session.slug
            )
            let rows = result.results ?? []
            let failed = rows.filter { $0.ok != true }
            if failed.isEmpty {
                actionResult = "Pushed \(rows.count) worktree\(rows.count == 1 ? "" : "s")"
            } else {
                actionResult = failed
                    .map { row in
                        let name = (row.path as NSString?)?.lastPathComponent ?? "worktree"
                        return "\(name): \(row.error ?? row.message ?? "push failed")"
                    }
                    .joined(separator: " · ")
            }
        } catch {
            actionResult = error.localizedDescription
        }
        pushingAll = false
        await load()
    }

    private var content: some View {
        Group {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading changes…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundColor(.orange)
                    Text("Changes unavailable")
                        .font(.system(size: 14, weight: .semibold))
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty && errors.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundColor(LoomColors.green)
                    Text("No changes")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Every worktree matches its base branch.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A plain split, not a NavigationSplitView: this pane already
                // lives inside the window's own split, and nesting them
                // collapses the file list.
                HStack(spacing: 0) {
                    fileList
                        .frame(width: 260)
                    Divider()
                    if let id = selection, let file = files.first(where: { $0.id == id }) {
                        DiffDetailView(file: file)
                    } else {
                        Text("Select a file")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        error = ""
        // Worktree state comes from the task detail, the diff from its own
        // endpoint; fetch both together so the bar and the file list agree.
        async let detail = try? session.api.taskDetail(
            projectId: session.projectId, slug: session.slug
        )
        async let offered = try? session.api.worktreeCandidates(
            projectId: session.projectId, slug: session.slug
        )
        do {
            let diff = try await session.api.diff(projectId: session.projectId, slug: session.slug)
            worktrees = await detail?.worktree_statuses ?? []
            candidates = await offered?.candidates ?? []
            var collected: [DiffFile] = []
            var worktreeErrors: [String] = []
            for worktree in diff.worktrees ?? [] {
                if let e = worktree.error, !e.isEmpty {
                    worktreeErrors.append("\(worktree.path ?? "worktree"): \(e)")
                }
                for file in worktree.files ?? [] {
                    var f = file
                    f.worktree = worktree.branch ?? (worktree.path as NSString?)?.lastPathComponent
                    collected.append(f)
                }
            }
            files = collected
            errors = worktreeErrors
            if selection == nil { selection = collected.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The task's worktrees and what you do with them after reading a diff: push a
/// branch, merge it back, add another repository, or drop one. Merge and push
/// are the server's operations — merge refuses on a dirty tree, aborts on
/// conflicts, and never pushes.
private struct WorktreeBar: View {
    let worktrees: [TaskDetail.WorktreeStatus]
    let candidates: [WorktreeCandidate]
    let busyPath: String?
    let pushingAll: Bool
    let result: String
    let onPush: (TaskDetail.WorktreeStatus) async -> Void
    let onMerge: (TaskDetail.WorktreeStatus) async -> Void
    let onAdd: (WorktreeCandidate) async -> Void
    let onRemove: (TaskDetail.WorktreeStatus) -> Void
    let onPushAll: () async -> Void

    /// Repositories not already checked out for this task.
    private var available: [WorktreeCandidate] {
        candidates.filter { !$0.alreadyCreated }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(worktrees) { worktree in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundColor(LoomColors.accent)
                    Text(worktree.branch ?? worktree.repoName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    stateChips(worktree)
                    Spacer(minLength: 8)

                    if busyPath == worktree.path {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Push") { Task { await onPush(worktree) } }
                            .help("git push -u origin \(worktree.branch ?? "branch")")
                        Button("Merge") { Task { await onMerge(worktree) } }
                            .help("Merge this branch into its base — refuses if the tree is dirty")
                            .disabled(worktree.clean == false)
                        Button {
                            onRemove(worktree)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Remove this worktree from the task")
                    }
                }
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                if available.isEmpty {
                    Text(worktrees.isEmpty
                         ? "No repository to branch from — check the project's code root."
                         : "Every repository in this project is checked out.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                } else {
                    Menu("Add worktree") {
                        ForEach(available) { candidate in
                            Button {
                                Task { await onAdd(candidate) }
                            } label: {
                                Text(candidate.isPreferred
                                     ? "\(candidate.name) (this project)"
                                     : candidate.name)
                            }
                        }
                    }
                    .fixedSize()
                    .help("Branch a repository into this task's work/ directory")
                }
                Spacer(minLength: 8)
                if worktrees.count > 1 {
                    if pushingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Push all") { Task { await onPushAll() } }
                            .help("Push every worktree's branch")
                    }
                }
            }
            .controlSize(.small)

            if !result.isEmpty {
                Text(result)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoomColors.bgBase)
    }

    @ViewBuilder
    private func stateChips(_ worktree: TaskDetail.WorktreeStatus) -> some View {
        HStack(spacing: 5) {
            if worktree.clean == true {
                chip("clean", color: LoomColors.green)
            } else {
                if let staged = worktree.staged, staged > 0 {
                    chip("\(staged) staged", color: LoomColors.accent)
                }
                if let unstaged = worktree.unstaged, unstaged > 0 {
                    chip("\(unstaged) changed", color: LoomColors.amber)
                }
                if let untracked = worktree.untracked, untracked > 0 {
                    chip("\(untracked) new", color: .secondary)
                }
            }
            if let ahead = worktree.ahead, ahead > 0 {
                chip("↑\(ahead)", color: LoomColors.accent)
            }
            if let behind = worktree.behind, behind > 0 {
                chip("↓\(behind)", color: LoomColors.amber)
            }
            if worktree.has_remote == false {
                chip("no remote", color: .secondary)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Rectangle())
    }
}

private struct FileRow: View {
    let file: DiffFile
    var showWorktree = false

    /// Name on top, the directory under it in a dimmer type. Truncating the
    /// middle of a full path hides the one part you are looking for.
    private var fileName: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !directory.isEmpty {
                    Text(directory)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if showWorktree, let worktree = file.worktree {
                    Text(worktree)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text("+\(file.additions ?? 0)")
                    .foregroundColor(LoomColors.green)
                Text("−\(file.deletions ?? 0)")
                    .foregroundColor(LoomColors.red)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
    }
}

private struct DiffDetailView: View {
    let file: DiffFile

    var body: some View {
        ScrollView {
            // Lazy: a big patch is thousands of rows, and building them all up
            // front stalls the window every time you pick a file.
            LazyVStack(alignment: .leading, spacing: 0) {
                if let patch = file.patch, !patch.isEmpty {
                    ForEach(Array(patch.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                        DiffLine(text: line)
                    }
                } else {
                    Text("Binary or empty diff")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .background(LoomColors.bgElev1)
    }
}

private struct DiffLine: View {
    let text: String

    private var kind: Character? { text.first }

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(background)
            .foregroundColor(foreground)
    }

    private var background: Color {
        switch kind {
        case "+": return LoomColors.green.opacity(0.10)
        case "-": return Color.red.opacity(0.10)
        case "@": return LoomColors.accent.opacity(0.10)
        default: return .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case "@": return LoomColors.accent
        case "+", "-": return .primary
        default: return .secondary
        }
    }
}
