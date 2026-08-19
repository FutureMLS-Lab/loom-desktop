import AppKit
import SwiftUI

/// The Files tab: the whole task directory as a small editor. A folder tree on
/// the left, folders before files as the server lists them, and the selected
/// file's source on the right; `PLAN.md` is the one opened on arrival. Loom
/// writes back only `PLAN.md` and `WIKI.md`, so everything else is read-only.
struct PlanView: View {
    @ObservedObject var session: ChatSession

    /// Directory (relative to the task root, `""` for the root) → its entries.
    /// Only directories someone has opened are in here; the tree is fetched a
    /// level at a time so a task holding a large worktree still opens at once.
    @State private var children: [String: [TaskFileListing.Entry]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loadingDirs: Set<String> = []
    @State private var selected = ""
    @State private var draft = ""
    @State private var savedBaseline = ""
    /// Why the open file shows no source: binary, or too big to edit.
    @State private var unreadable = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error = ""
    @State private var status = ""
    /// Bumped when the editor must accept an external buffer (load / file switch).
    @State private var editorRevision = 0
    @State private var autosaveTask: Task<Void, Never>?

    /// What the gateway's template API accepts, and only at the task root: a
    /// `PLAN.md` further down inside a worktree is a different file, and saving
    /// it would write over the task's own plan.
    private static let writable: Set<String> = ["PLAN.md", "WIKI.md"]

    private var dirty: Bool { draft != savedBaseline }
    private var canEdit: Bool { Self.writable.contains(selected) }

    /// One line of the tree as drawn: the flattening of everything expanded.
    private struct Row: Identifiable {
        let path: String
        let name: String
        let isDir: Bool
        let depth: Int
        var id: String { path }
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for entry in children[dir] ?? [] {
                let path = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
                out.append(
                    Row(path: path, name: entry.name, isDir: entry.dir, depth: depth)
                )
                if entry.dir && expanded.contains(path) {
                    walk(path, depth + 1)
                }
            }
        }
        walk("", 0)
        return out
    }

    var body: some View {
        Group {
            if loading && children.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading files…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty && children.isEmpty {
                emptyState(
                    symbol: "exclamationmark.triangle",
                    title: "Files unavailable",
                    detail: error
                )
            } else if (children[""] ?? []).isEmpty {
                emptyState(
                    symbol: "folder",
                    title: "Nothing here yet",
                    detail: "Run the deep interview and the agent will write PLAN.md."
                )
            } else {
                HSplitView {
                    fileSidebar
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
                    editorPane
                        .frame(minWidth: 300)
                }
            }
        }
        .background(LoomColors.bgElev1)
        .task(id: session.id) { await loadRoot() }
        .onChange(of: session.planRevision) { _, _ in
            guard !dirty else { return }
            Task { await refreshOpenFile() }
        }
        .onChange(of: draft) { _, newValue in
            guard !selected.isEmpty else { return }
            session.persistFileDraft(selected, text: newValue, baseline: savedBaseline)
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            if !selected.isEmpty {
                session.persistFileDraft(selected, text: draft, baseline: savedBaseline)
            }
        }
    }

    // MARK: Tree

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(LoomColors.amber)
                Text(session.slug)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    Task { await reloadTree() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Rescan the task directory")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        treeRow(row)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(LoomColors.bgBase)
    }

    private func treeRow(_ row: Row) -> some View {
        let isSelected = row.path == selected
        return Button {
            if row.isDir {
                toggle(row.path)
            } else {
                Task { await open(row.path) }
            }
        } label: {
            HStack(spacing: 5) {
                if row.isDir {
                    Image(
                        systemName: expanded.contains(row.path)
                            ? "chevron.down" : "chevron.right"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: symbol(for: row))
                    .font(.system(size: 11.5))
                    .foregroundColor(isSelected ? LoomColors.accent : .secondary)
                    .frame(width: 14)
                Text(row.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? LoomColors.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if loadingDirs.contains(row.path) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 12 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? LoomColors.accentSoft : Color.clear,
                in: Rectangle()
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbol(for row: Row) -> String {
        if row.isDir {
            return expanded.contains(row.path) ? "folder.fill" : "folder"
        }
        switch (row.name as NSString).pathExtension.lowercased() {
        case "md", "txt", "tex", "bib":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf":
            return "photo"
        case "json", "jsonl", "yaml", "yml", "toml", "cfg", "ini":
            return "curlybraces"
        case "sh", "bash", "zsh":
            return "terminal"
        case "csv", "tsv":
            return "tablecells"
        case "log":
            return "list.bullet.rectangle"
        case "":
            return "doc"
        default:
            return "chevron.left.forwardslash.chevron.right"
        }
    }

    // MARK: Editor

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Ahead of the controls in the queue for space: squeezed by
                // them, the name of the file you are editing collapsed to "…".
                Text(selected.isEmpty ? "No file open" : selected)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if dirty {
                    Text("Edited")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(LoomColors.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(LoomColors.amber.opacity(0.14), in: Rectangle())
                }
                if !selected.isEmpty && !canEdit && unreadable.isEmpty {
                    Text("Read-only")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Button {
                    Task { await refreshOpenFile(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload from server")
                .disabled(selected.isEmpty || dirty)

                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canEdit || !dirty || saving)
                .keyboardShortcut("s", modifiers: .command)
                .help(canEdit ? "Save (⌘S)" : "Only PLAN.md / WIKI.md can be saved")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if !unreadable.isEmpty {
                emptyState(
                    symbol: "doc.questionmark",
                    title: "Nothing to show",
                    detail: unreadable
                )
            } else if selected.isEmpty {
                emptyState(
                    symbol: "doc.text",
                    title: "No file open",
                    detail: "Pick one from the tree on the left."
                )
            } else {
                PlainTextEditor(
                    text: $draft,
                    documentID: selected,
                    contentRevision: editorRevision,
                    editable: canEdit,
                    fontSize: 13.5
                )
            }
        }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.7))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil {
                Task { await list(path) }
            }
        }
    }

    private func list(_ path: String) async {
        loadingDirs.insert(path)
        defer { loadingDirs.remove(path) }
        do {
            let listing = try await session.api.taskFiles(
                projectId: session.projectId,
                slug: session.slug,
                path: path
            )
            children[path] = listing.entries ?? []
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadRoot() async {
        loading = true
        children = [:]
        expanded = []
        selected = ""
        draft = ""
        savedBaseline = ""
        unreadable = ""
        status = ""
        await list("")
        // The plan is what the tab is mostly for; open it when there is one.
        if (children[""] ?? []).contains(where: { !$0.dir && $0.name == "PLAN.md" }) {
            await open("PLAN.md")
        }
        loading = false
    }

    /// Re-reads every directory already open, so the tree comes back the shape
    /// it was rather than collapsed to the root.
    private func reloadTree() async {
        for path in [""] + expanded.sorted() {
            await list(path)
        }
        await refreshOpenFile()
    }

    private func open(_ path: String) async {
        guard path != selected else { return }
        // Stash the current buffer before switching — drafts survive per file.
        if !selected.isEmpty {
            session.persistFileDraft(selected, text: draft, baseline: savedBaseline)
        }
        selected = path
        unreadable = ""
        status = ""
        draft = ""
        savedBaseline = ""
        editorRevision += 1
        await read(path)
    }

    private func refreshOpenFile(force: Bool = false) async {
        guard !selected.isEmpty, force || !dirty else { return }
        await read(selected)
    }

    private func read(_ path: String) async {
        do {
            let file = try await session.api.taskFiles(
                projectId: session.projectId,
                slug: session.slug,
                path: path
            )
            // A slow reply for a file the reader has already navigated away
            // from must not land in the editor.
            guard selected == path else { return }
            if let reason = file.error, !reason.isEmpty {
                unreadable = explain(reason, size: file.size)
                draft = ""
                savedBaseline = ""
                editorRevision += 1
                return
            }
            unreadable = ""
            applyBuffer(path: path, content: file.body ?? "")
        } catch {
            guard selected == path else { return }
            unreadable = error.localizedDescription
        }
    }

    private func explain(_ reason: String, size: Int?) -> String {
        switch reason {
        case "binary":
            return "This is not a text file, so there is no source to show."
        case "too large":
            let mb = Double(size ?? 0) / 1_048_576
            return String(
                format: "This file is %.1f MB, past what the editor will open.", mb
            )
        default:
            return "The server could not read this file."
        }
    }

    private func applyBuffer(path: String, content: String) {
        savedBaseline = content
        if let local = session.loadFileDraft(path), local != content {
            draft = local
            status = "Restored unsaved edits"
        } else {
            draft = content
        }
        editorRevision += 1
    }

    private func scheduleAutosave() {
        guard canEdit, dirty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await save(silent: true)
        }
    }

    private func save(silent: Bool = false) async {
        guard canEdit, !selected.isEmpty else { return }
        let name = selected
        let payload = draft
        guard payload != savedBaseline else { return }
        if !silent {
            saving = true
            status = ""
        }
        do {
            try await session.api.writeTemplate(
                projectId: session.projectId,
                slug: session.slug,
                name: name,
                content: payload
            )
            savedBaseline = payload
            session.clearFileDraft(name)
            status = silent ? "Auto-saved" : "Saved"
        } catch {
            status = error.localizedDescription
        }
        if !silent { saving = false }
    }
}
