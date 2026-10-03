import SwiftUI

/// The task's markdown, read-only: `PLAN.md` on arrival, the other documents
/// at the task root a menu away. Editing stays on the desktop.
struct PlanScreen: View {
    @ObservedObject var session: ChatSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [String] = []
    @State private var selected = ""
    @State private var markdown = ""
    @State private var loaded = false
    @State private var error = ""
    @State private var figureRevision = 0
    @State private var findRequest = 0
    @State private var selecting: SelectableItem?

    /// The page's own paper, so the edges past it while scrolling match.
    private static let paper = LoomColors.dynamic(light: 0xFFFDF7, dark: 0x211F1A)
    /// The agent rewrites the plan on its own schedule; nothing announces it.
    private static let pollInterval: UInt64 = 15_000_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Self.paper)
        .task(id: session.id) { await load() }
        .task(id: "\(session.id)/\(selected)/\(scenePhase == .active)") { await poll() }
        .onChange(of: session.planRevision) { _, _ in
            Task { await read(selected) }
        }
        .sheet(item: $selecting) { SelectableTextSheet(item: $0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(files, id: \.self) { name in
                    Button {
                        open(name)
                    } label: {
                        if name == selected {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                    Text(selected.isEmpty ? "No document" : selected)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if files.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(.primary)
            }
            .disabled(files.count < 2)
            Spacer(minLength: 8)
            Button {
                findRequest += 1
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(markdown.isEmpty)
            .accessibilityLabel("Find")
            Menu {
                Button {
                    Clipboard.copy(markdown)
                } label: {
                    Label("Copy Markdown", systemImage: "doc.on.doc")
                }
                Button {
                    selecting = SelectableItem(title: selected, text: markdown, monospaced: true)
                } label: {
                    Label("Select Text", systemImage: "selection.pin.in.out")
                }
                Button {
                    Task { await reload() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(selected.isEmpty)
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !selected.isEmpty && (error.isEmpty || !markdown.isEmpty) {
            MarkdownWebView(
                markdown: markdown,
                documentID: "\(session.id)/\(selected)",
                assetProject: session.projectId,
                assetTask: session.slug,
                assetRevision: figureRevision,
                findRequest: findRequest,
                onRefresh: { await reload() }
            )
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: error.isEmpty ? "doc.text" : "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(error.isEmpty ? "No plan yet" : "Plan unavailable")
                        .font(.headline)
                    Text(error.isEmpty ? "The agent writes PLAN.md during the deep interview." : error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
                .padding(.top, 120)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await reload() }
        }
    }

    // MARK: Loading

    private func open(_ name: String) {
        guard name != selected else { return }
        selected = name
        markdown = ""
        Task { await read(name) }
    }

    private func reload() async {
        figureRevision += 1
        await load()
    }

    private func load() async {
        defer { loaded = true }
        do {
            let listing = try await session.api.taskFiles(
                projectId: session.projectId,
                slug: session.slug,
                path: ""
            )
            files = (listing.entries ?? [])
                .filter { !$0.dir && $0.name.lowercased().hasSuffix(".md") }
                .map(\.name)
                .sorted { Self.rank($0) < Self.rank($1) }
            error = ""
        } catch {
            if files.isEmpty { self.error = error.localizedDescription }
            return
        }
        if selected.isEmpty || !files.contains(selected) {
            selected = files.first ?? ""
            markdown = ""
        }
        await read(selected)
    }

    private func read(_ path: String) async {
        guard !path.isEmpty else { return }
        do {
            let file = try await session.api.taskFiles(
                projectId: session.projectId,
                slug: session.slug,
                path: path
            )
            guard selected == path else { return }
            if let reason = file.error, !reason.isEmpty {
                markdown = ""
                error = reason == "too large"
                    ? "This document is too large to open on the phone."
                    : "The server could not read this document."
                return
            }
            error = ""
            let body = file.body ?? ""
            if body != markdown { markdown = body }
        } catch {
            guard selected == path else { return }
            if markdown.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func poll() async {
        guard scenePhase == .active, !selected.isEmpty else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await read(selected)
        }
    }

    /// The plan first, the wiki next, the rest by name.
    private static func rank(_ name: String) -> String {
        switch name {
        case "PLAN.md": return "0"
        case "WIKI.md": return "1"
        default: return "2" + name.lowercased()
        }
    }
}
