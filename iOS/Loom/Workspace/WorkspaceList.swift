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
    @AppStorage("workspaceFilter") private var filterRaw = WorkspaceFilter.all.rawValue

    private var filter: WorkspaceFilter { WorkspaceFilter(rawValue: filterRaw) ?? .all }

    var body: some View {
        List(selection: $selection) {
            if case .offline(let message) = workspace.connection {
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

            Section {
                Picker("Show", selection: $filterRaw) {
                    ForEach(WorkspaceFilter.allCases) { filter in
                        Text(label(for: filter)).tag(filter.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .listRowBackground(Color.clear)
            }

            ForEach(visibleProjects) { project in
                Section(project.label) {
                    ForEach(tasks(for: project), id: \.slug) { meta in
                        let ref = TaskRef(projectId: project.id, slug: meta.slug)
                        TaskRow(meta: meta, state: workspace.state(ref))
                            .tag(ref)
                    }
                }
            }

            if visibleProjects.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search tasks")
        .refreshable { await workspace.refresh() }
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

    private var connectionLabel: String {
        switch workspace.connection {
        case .connecting: return "Connecting"
        case .online: return "Connected"
        case .offline: return "Offline"
        }
    }

    private func label(for filter: WorkspaceFilter) -> String {
        switch filter {
        case .all: return "All"
        case .working: return workspace.workingCount > 0 ? "Working \(workspace.workingCount)" : "Working"
        case .review: return workspace.finishedCount > 0 ? "Review \(workspace.finishedCount)" : "Review"
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
}

struct TaskRow: View {
    let meta: LoomTaskMeta
    let state: TaskActivity?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: state)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title ?? meta.slug)
                    .font(.body)
                    .lineLimit(2)
                if state == .finished {
                    Text("Finished — not opened yet")
                        .font(.caption)
                        .foregroundStyle(LoomColors.attention)
                } else if state == .working {
                    Text("Working")
                        .font(.caption)
                        .foregroundStyle(LoomColors.accent)
                }
            }
            Spacer(minLength: 0)
            if let agent = meta.agent, !agent.isEmpty {
                Image(systemName: Self.agentSymbol(agent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }

    static func agentSymbol(_ agent: String) -> String {
        switch agent.lowercased() {
        case "cursor": return "cursorarrow.rays"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "claude": return "terminal.fill"
        default: return "sparkles"
        }
    }
}

struct StatusDot: View {
    let state: TaskActivity?

    var body: some View {
        switch state {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(LoomColors.accent)
                .frame(width: 10, height: 10)
        case .finished:
            Circle()
                .fill(LoomColors.attention)
                .frame(width: 10, height: 10)
        case .idle:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.4)
                .frame(width: 10, height: 10)
        case nil:
            Circle()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 10, height: 10)
        }
    }
}
