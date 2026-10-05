import SwiftUI

enum WorkspaceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case working = "Working"
    case review = "To review"

    var id: String { rawValue }

    func matches(_ state: TaskActivity?) -> Bool {
        switch self {
        case .all: return true
        case .working: return state == .working
        case .review: return state == .finished
        }
    }
}

struct WorkspaceList: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Binding var selection: TaskRef?
    @Binding var showServers: Bool
    @State private var search = ""
    @State private var expanded: Set<TaskRef> = []
    @AppStorage("workspaceFilter") private var filterRaw = WorkspaceFilter.all.rawValue
    /// Projects opened up, one id per line. The rest start folded: a phone
    /// screen holds a list of projects, not every task in them.
    @AppStorage("expandedProjects") private var openRaw = ""
    @AppStorage("taskTab") private var taskTab = TaskTab.chat.rawValue

    private var filter: WorkspaceFilter { WorkspaceFilter(rawValue: filterRaw) ?? .all }
    private var openProjects: Set<String> { Set(openRaw.split(separator: "\n").map(String.init)) }

    var body: some View {
        List(selection: $selection) {
            if case .offline(let message) = workspace.connection {
                offlineBanner(message)
            }

            Section {
                summary
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            ForEach(visibleProjects) { project in
                let projectTasks = tasks(for: project)
                let folded = isFolded(project)
                Section {
                    if !folded {
                        ForEach(projectTasks, id: \.slug) { meta in
                            let ref = TaskRef(projectId: project.id, slug: meta.slug)
                            let state = workspace.state(ref)
                            TaskCard(
                                meta: meta,
                                state: state,
                                finishedAt: workspace.finishedAt(ref),
                                expanded: expanded.contains(ref),
                                preview: workspace.previews[ref],
                                toggle: { toggle(ref) },
                                open: { tab in open(ref, on: tab) }
                            )
                            .tag(ref)
                            .listRowBackground(rowBackground(state))
                        }
                    }
                } header: {
                    let all = workspace.tasksByProject[project.id] ?? []
                    let states = all.map { workspace.state(TaskRef(projectId: project.id, slug: $0.slug)) }
                    ProjectHeader(
                        project: project,
                        total: all.count,
                        working: states.filter { $0 == .working }.count,
                        review: states.filter { $0 == .finished }.count,
                        folded: folded
                    ) {
                        toggleFold(project)
                    }
                }
                .headerProminence(.increased)
            }

            if visibleProjects.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(backdrop)
        .searchable(text: $search, prompt: "Search tasks")
        .refreshable {
            await workspace.refresh()
            for ref in expanded { workspace.loadPreview(ref, force: true) }
        }
        .onChange(of: workspace.activity) { _, _ in
            for ref in expanded { workspace.loadPreview(ref) }
        }
        #if DEBUG
        // Simulator runs, which cannot tap: `-LoomExpandTask <part of a title>`.
        .onChange(of: workspace.tasksByProject.count) { _, _ in
            guard let wanted = UserDefaults.standard.string(forKey: "LoomExpandTask"), !wanted.isEmpty else { return }
            for (projectId, metas) in workspace.tasksByProject {
                for meta in metas where (meta.title ?? meta.slug).localizedCaseInsensitiveContains(wanted) {
                    let ref = TaskRef(projectId: projectId, slug: meta.slug)
                    expanded.insert(ref)
                    workspace.loadPreview(ref)
                }
            }
        }
        #endif
        .navigationTitle(workspace.activeServerName)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Circle()
                    .fill(workspace.connection.dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(connectionLabel)
            }
            ToolbarItem(placement: .topBarTrailing) { serverMenu }
        }
    }

    // MARK: Pieces

    private var backdrop: some View {
        LinearGradient(
            colors: [LoomColors.accent.opacity(0.10), LoomColors.bgBase, LoomColors.bgBase],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var summary: some View {
        HStack(spacing: 10) {
            StatTile(
                title: "All tasks",
                value: workspace.taskCount,
                symbol: "square.stack.3d.up.fill",
                tint: Color(uiColor: .systemGray),
                selected: filter == .all
            ) { choose(.all) }
            StatTile(
                title: "To review",
                value: workspace.finishedCount,
                symbol: "checkmark.seal.fill",
                tint: LoomColors.attention,
                selected: filter == .review
            ) { choose(.review) }
            StatTile(
                title: "Working",
                value: workspace.workingCount,
                symbol: "bolt.fill",
                tint: LoomColors.accent,
                selected: filter == .working
            ) { choose(.working) }
        }
    }

    private func offlineBanner(_ message: String) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't reach \(workspace.activeServerName)")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(LoomColors.amber)
            }
        }
    }

    private func rowBackground(_ state: TaskActivity?) -> some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            switch state {
            case .working: LoomColors.accent.opacity(0.06)
            case .finished: LoomColors.attention.opacity(0.09)
            default: Color.clear
            }
        }
    }

    private var connectionLabel: String {
        switch workspace.connection {
        case .connecting: return "Connecting"
        case .online: return "Connected"
        case .offline: return "Offline"
        }
    }

    private var serverMenu: some View {
        Menu {
            Section("Server") {
                ForEach(workspace.servers) { server in
                    Button {
                        LoomSettings.activate(server)
                    } label: {
                        if server.id == workspace.activeServerID {
                            Label(serverName(server), systemImage: "checkmark")
                        } else {
                            Text(serverName(server))
                        }
                    }
                }
            }
            Section {
                Button {
                    foldAll(false)
                } label: {
                    Label("Expand All Projects", systemImage: "rectangle.expand.vertical")
                }
                Button {
                    foldAll(true)
                } label: {
                    Label("Collapse All Projects", systemImage: "rectangle.compress.vertical")
                }
            }
            Button {
                showServers = true
            } label: {
                Label("Manage Servers…", systemImage: "server.rack")
            }
            Button {
                workspace.refreshNow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch workspace.connection {
        case .connecting where workspace.projects.isEmpty:
            HStack {
                Spacer()
                ProgressView("Connecting…")
                Spacer()
            }
            .padding(.vertical, 40)
        default:
            ContentUnavailableView(
                workspace.projects.isEmpty ? "No projects yet" : "No matching tasks",
                systemImage: filter == .review ? "checkmark.circle" : "magnifyingglass"
            )
        }
    }

    // MARK: Actions

    /// Tapping the selected tile again goes back to everything.
    private func choose(_ next: WorkspaceFilter) {
        withAnimation(.snappy(duration: 0.25)) {
            filterRaw = (filter == next ? WorkspaceFilter.all : next).rawValue
        }
    }

    private func toggle(_ ref: TaskRef) {
        withAnimation(.snappy(duration: 0.28)) {
            if expanded.contains(ref) {
                expanded.remove(ref)
            } else {
                expanded.insert(ref)
            }
        }
        if expanded.contains(ref) { workspace.loadPreview(ref) }
    }

    private func open(_ ref: TaskRef, on tab: TaskTab) {
        taskTab = tab.rawValue
        selection = ref
    }

    /// A search or a filter shows every match, folded project or not.
    private func isFolded(_ project: LoomProject) -> Bool {
        filter == .all && terms.isEmpty && !openProjects.contains(project.id)
    }

    private func toggleFold(_ project: LoomProject) {
        var open = openProjects
        if open.contains(project.id) {
            open.remove(project.id)
        } else {
            open.insert(project.id)
        }
        withAnimation(.snappy(duration: 0.28)) {
            openRaw = open.sorted().joined(separator: "\n")
        }
    }

    private func foldAll(_ folded: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            openRaw = folded ? "" : workspace.projects.map(\.id).sorted().joined(separator: "\n")
        }
    }

    // MARK: Filtering

    private func serverName(_ server: LoomServer) -> String {
        server.name.isEmpty ? LoomServer.suggestedName(for: server.baseURL) : server.name
    }

    private var terms: [Substring] {
        search.lowercased().split(whereSeparator: \.isWhitespace)
    }

    private func tasks(for project: LoomProject) -> [LoomTaskMeta] {
        (workspace.tasksByProject[project.id] ?? []).filter { meta in
            let ref = TaskRef(projectId: project.id, slug: meta.slug)
            guard filter.matches(workspace.state(ref)) else { return false }
            guard !terms.isEmpty else { return true }
            let haystack = "\(project.label) \(meta.title ?? "") \(meta.slug) \(meta.general_goal ?? "") \(meta.agent ?? "")".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var visibleProjects: [LoomProject] {
        workspace.projects.filter { project in
            (filter == .all && terms.isEmpty) ? true : !tasks(for: project).isEmpty
        }
    }
}

// MARK: - Summary

private struct StatTile: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.15), in: Circle())
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                    }
                }
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.75) : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Projects

private struct ProjectHeader: View {
    let project: LoomProject
    let total: Int
    let working: Int
    let review: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                ProjectMonogram(name: project.label)
                // Explicit label colours: a list header's own style is
                // secondary, and `.primary` inside it resolves to that grey.
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1)
                    Text(total == 1 ? "1 task" : "\(total) tasks")
                        .font(.caption2)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                Spacer(minLength: 8)
                if working > 0 {
                    CountBadge(value: working, symbol: "bolt.fill", tint: LoomColors.accent)
                }
                if review > 0 {
                    CountBadge(value: review, symbol: "checkmark", tint: LoomColors.attention)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel("\(project.label), \(folded ? "folded" : "open")")
    }
}

/// Two letters on a colour of the project's own, the same on every launch.
private struct ProjectMonogram: View {
    let name: String

    private static let palette: [UInt32] = [
        0x4F46E5, 0x0E9F8E, 0xC96442, 0xC2417A, 0x5B8C51, 0x8A5CF5, 0x2F80ED, 0xB7791F,
    ]

    var body: some View {
        Text(initials)
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                LinearGradient(
                    colors: [color, color.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }

    private var initials: String {
        let capitals = name.filter(\.isUppercase)
        if capitals.count >= 2 { return String(capitals.prefix(2)) }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return String([a, b]).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(uiColor: LoomColors.uiColor(Self.palette[Int(hash % UInt32(Self.palette.count))]))
    }
}

private struct CountBadge: View {
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .heavy))
            Text("\(value)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Tasks

private struct TaskCard: View {
    let meta: LoomTaskMeta
    let state: TaskActivity?
    let finishedAt: Date?
    let expanded: Bool
    let preview: TaskPreview?
    let toggle: () -> Void
    let open: (TaskTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                StatusOrb(state: state)
                VStack(alignment: .leading, spacing: 5) {
                    Text(meta.title ?? meta.slug)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(expanded ? 4 : 2)
                    HStack(spacing: 6) {
                        if let agent = meta.agent, !agent.isEmpty {
                            AgentBadge(agent: agent)
                        }
                        stateLine
                    }
                }
                Spacer(minLength: 4)
                Button(action: toggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(expanded ? 0.09 : 0.05), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
            }

            if expanded {
                details
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var stateLine: some View {
        switch state {
        case .working:
            Text("Working")
                .font(.caption.weight(.medium))
                .foregroundStyle(LoomColors.accent)
        case .finished:
            Text(finishedAt.map { "Finished \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" }
                 ?? "Finished — not opened yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(LoomColors.attention)
                .lineLimit(1)
        case .idle:
            Text("Ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            Text("Stopped")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let goal = meta.general_goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
                DetailBlock(title: "Goal", symbol: "scope") {
                    Text(goal)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            DetailBlock(title: "Latest", symbol: "text.bubble") {
                latest
            }
            HStack(spacing: 8) {
                QuickAction(title: "Chat", symbol: "bubble.left.and.text.bubble.right") { open(.chat) }
                QuickAction(title: "Terminal", symbol: "terminal") { open(.terminal) }
                QuickAction(title: "Plan", symbol: "doc.richtext") { open(.plan) }
            }
        }
        .padding(.leading, 44)
    }

    @ViewBuilder
    private var latest: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 6) {
                if let running = preview.running {
                    Label(running, systemImage: "gearshape.2")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LoomColors.accent)
                        .lineLimit(2)
                }
                if !preview.text.isEmpty {
                    Text(InlineMarkdown.text(preview.text))
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(5)
                } else if preview.running == nil {
                    Text("Nothing from the agent yet.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the conversation…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DetailBlock<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

private struct QuickAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(LoomColors.accent)
                .background(LoomColors.accent.opacity(0.11), in: Capsule())
        }
        .buttonStyle(.borderless)
    }
}

private struct StatusOrb: View {
    let state: TaskActivity?

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.15))
            icon
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .working:
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(tint)
        case .idle:
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
        case nil:
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch state {
        case .working: return LoomColors.accent
        case .finished: return LoomColors.attention
        case .idle: return Color(uiColor: .systemGray)
        case nil: return Color(uiColor: .systemGray2)
        }
    }
}

private struct AgentBadge: View {
    let agent: String

    var body: some View {
        Text(name)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var name: String {
        switch agent.lowercased() {
        case "claude": return "Claude"
        case "cursor": return "Cursor"
        case "codex": return "Codex"
        default: return agent.capitalized
        }
    }

    private var color: Color {
        switch agent.lowercased() {
        case "claude": return Color(uiColor: LoomColors.uiColor(0xC96442))
        case "cursor": return Color(uiColor: LoomColors.uiColor(0x2F80ED))
        case "codex": return Color(uiColor: LoomColors.uiColor(0x10A37F))
        default: return .secondary
        }
    }
}
