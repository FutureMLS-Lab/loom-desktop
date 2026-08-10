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

    var body: some View {
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
                        .font(.system(size: 13, weight: .semibold))
                    Text(error)
                        .font(.system(size: 11))
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
                        .font(.system(size: 13, weight: .semibold))
                    Text("Every worktree matches its base branch.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    List(selection: $selection) {
                        if !errors.isEmpty {
                            Section("Worktree errors") {
                                ForEach(errors, id: \.self) { message in
                                    Text(message)
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        Section("Files (\(files.count))") {
                            ForEach(files) { file in
                                FileRow(file: file)
                                    .tag(file.id)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                } detail: {
                    if let id = selection, let file = files.first(where: { $0.id == id }) {
                        DiffDetailView(file: file)
                    } else {
                        Text("Select a file")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the diff")
            }
        }
    }

    private func load() async {
        loading = true
        error = ""
        do {
            let diff = try await session.api.diff(projectId: session.projectId, slug: session.slug)
            var collected: [DiffFile] = []
            var worktreeErrors: [String] = []
            for worktree in diff.worktrees ?? [] {
                if let e = worktree.error, !e.isEmpty {
                    worktreeErrors.append("\(worktree.path ?? "worktree"): \(e)")
                }
                for file in worktree.files ?? [] {
                    var f = file
                    f.worktree = worktree.branch ?? (worktree.path as NSString?)?.lastPathComponent
                    f.worktreePath = worktree.path
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

private struct FileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 6) {
            Text(file.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let worktree = file.worktree {
                Text(worktree)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10), in: Rectangle())
            }
            Text("+\(file.additions ?? 0)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(LoomColors.green)
            Text("-\(file.deletions ?? 0)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.red)
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
                        .font(.system(size: 11))
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
            .font(.system(size: 11, design: .monospaced))
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
