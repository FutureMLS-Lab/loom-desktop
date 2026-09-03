import SwiftUI

/// The plan, read-only, directly under the agent's pane — the same pairing the
/// web console has on its agent tab, where the terminal sits above a rendered
/// `PLAN.md`. Watching the plan fill in while the agent works is the point, so
/// this re-reads on its own and whenever a flow step rewrites the file.
///
/// Editing still belongs to the Files tab; this is the glance, not the desk.
struct PlanDigest: View {
    @ObservedObject var session: ChatSession
    /// Owned by the tab around this, which pins the find bar over its own
    /// scrolling page — see `MarkdownFind`.
    @ObservedObject var find: MarkdownFind

    @AppStorage("terminalPlanExpanded") private var expanded = true
    @AppStorage("taskTab") private var taskTabRaw = TaskPane.Tab.conversation.rawValue

    /// The markdown sitting in the task's own directory, and the one on show.
    /// Deliberately not the whole task tree: a task whose worktree holds a
    /// documented repository has hundreds of `.md` files in it, none of them
    /// this task's plan. The Files tab is where you go looking for those.
    @State private var order: [String] = []
    @State private var selected = ""
    @State private var content = ""
    @State private var loading = true
    @State private var error = ""
    @State private var poller: Task<Void, Never>?
    /// Seeded from the last document measured, not from a guess. The pane is
    /// rebuilt whenever you change task, and starting at a fixed 240 collapsed
    /// the digest on every switch before it sprang back to full height — a
    /// jolt through everything below it, several times a minute.
    @State private var contentHeight: CGFloat = DigestHeightMemory.last

    /// The plan changes on the timescale of an agent turn, not a keystroke.
    private static let refreshInterval: TimeInterval = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                body_
            }
        }
        .background(LoomColors.bgElev1)
        .task(id: session.id) { await load() }
        .onChange(of: session.planRevision) { _, _ in Task { await load() } }
        .onChange(of: expanded) { _, isOpen in
            isOpen ? startPolling() : stopPolling()
        }
        .onAppear { if expanded { startPolling() } }
        .onDisappear { stopPolling() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the plan" : "Show the plan")

            Image(systemName: "doc.text")
                .font(.system(size: 11.5))
                .foregroundColor(LoomColors.accent)

            if order.count > 1 {
                Menu {
                    ForEach(order, id: \.self) { name in
                        Button {
                            select(name)
                        } label: {
                            if name == selected {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(displayName)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick which markdown to preview")
            } else {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
            }

            if loading && content.isEmpty {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Spacer()

            if !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(LoomColors.amber)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // A button as well as ⌘F: reading this panel, your focus is
            // almost always still in the pane above it, and the shortcut goes
            // wherever focus is.
            Button {
                find.show()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Find in this document")

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-read from the server")

            Button {
                taskTabRaw = TaskPane.Tab.plan.rawValue
            } label: {
                Text("Edit")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(LoomColors.accent)
            }
            .buttonStyle(.plain)
            .help("Open this file in the Files tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LoomColors.bgElev2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { expanded.toggle() }
    }

    @ViewBuilder
    private var body_: some View {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Sized to the document: this sits in a scrolling page, and a box
            // with its own scrollbar inside one is what makes reading awkward.
            MarkdownPreview(
                markdown: content,
                documentID: "\(session.id)/\(selected)",
                compact: true,
                measuredHeight: $contentHeight,
                find: find,
                assetProject: session.projectId,
                assetTask: session.slug
            )
            .frame(height: contentHeight)
            .onChange(of: contentHeight) { _, height in
                DigestHeightMemory.last = height
            }
        } else if loading {
            centered("Reading the plan…")
        } else if !error.isEmpty {
            centered(error)
        } else {
            centered("No plan yet — run the deep interview and the agent will write PLAN.md.")
        }
    }

    private func centered(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
            .background(LoomColors.bgElev1)
    }

    private var displayName: String {
        selected.isEmpty ? "PLAN.md" : (selected as NSString).lastPathComponent
    }

    // MARK: Data

    private func startPolling() {
        guard poller == nil else { return }
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// Lists the task's own directory and reads the one document on show.
    ///
    /// This used to read the task detail, which arrives with every markdown in
    /// the task tree inlined — 13 MB and seven seconds for a task holding a
    /// documented repository, re-read on a timer, with all of it then kept in
    /// view state. Two small reads instead.
    private func load() async {
        do {
            let listing = try await session.api.taskFiles(
                projectId: session.projectId,
                slug: session.slug
            )
            var names = (listing.entries ?? [])
                .filter { !$0.dir && $0.name.lowercased().hasSuffix(".md") && ($0.size ?? 0) > 0 }
                .map(\.name)
            names.sort { left, right in
                if left == "PLAN.md" { return true }
                if right == "PLAN.md" { return false }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            order = names
            if selected.isEmpty || !names.contains(selected) {
                selected = names.first ?? ""
            }
            content = selected.isEmpty ? "" : try await read(selected)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Switching document reads only that one, rather than going back for the
    /// listing it already has.
    private func select(_ name: String) {
        guard name != selected else { return }
        selected = name
        content = ""
        Task {
            do {
                content = try await read(name)
                error = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func read(_ name: String) async throws -> String {
        let file = try await session.api.taskFiles(
            projectId: session.projectId,
            slug: session.slug,
            path: name
        )
        return file.body ?? ""
    }
}

/// The last digest height measured, so switching task does not start from a
/// number that is wrong for every document.
enum DigestHeightMemory {
    static var last: CGFloat = 240
}
