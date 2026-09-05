import SwiftUI

enum WorkspaceFilter: String, CaseIterable, Identifiable {
    case all = "All tasks", working = "Working", finished = "To review"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .all: return "square.stack"; case .working: return "waveform.path"; case .finished: return "checkmark.circle" }
    }
    var color: Color {
        switch self { case .all: return .primary; case .working: return LoomColors.accent; case .finished: return LoomColors.attention }
    }
    func matches(_ state: TaskPill.State?) -> Bool {
        switch self { case .all: return true; case .working: return state == .working; case .finished: return state == .finished }
    }
}

struct WorkspaceOverview: View {
    @ObservedObject var store: TaskStore
    let onNewTask: () -> Void
    let onAddProject: () -> Void
    let onQuickOpen: () -> Void

    private var attention: [TaskPill] {
        store.pills.filter { $0.state != .idle }.sorted {
            if $0.state != $1.state { return $0.state == .finished }
            return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(LoomColors.accent)
                        Text("A clear view of your work.").font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                        Text("\(store.projects.count) projects · \(store.tasksByProject.values.reduce(0) { $0 + $1.count }) tasks on \(store.activeServerName)")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    LoomMark(size: 60, opacity: 0.8)
                }

                HStack(spacing: 12) {
                    summary("To review", count: store.pills.filter { $0.state == .finished }.count, detail: "New results, ready to open", color: LoomColors.attention, symbol: "checkmark.circle")
                    summary("Working", count: store.pills.filter { $0.state == .working }.count, detail: "Agents making progress", color: LoomColors.accent, symbol: "waveform.path")
                }

                HStack(spacing: 10) {
                    Button(action: store.projects.isEmpty ? onAddProject : onNewTask) {
                        Label(store.projects.isEmpty ? "Add project" : "New task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent).tint(LoomColors.accent)
                    Button(action: onQuickOpen) { Label("Open task…", systemImage: "magnifyingglass") }
                        .disabled(store.tasksByProject.values.allSatisfy { $0.isEmpty })
                    Spacer()
                    Text("⌘K to switch").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 12) {
                    Text("IN FOCUS").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    if attention.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Everything is quiet.").font(.system(size: 15, weight: .medium))
                            Text("Open a task to continue, or start something new. Finished work will appear here.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .background(LoomColors.bgElev1, in: LoomShape.card)
                    } else {
                        ForEach(attention.prefix(8)) { task in
                            Button { store.select(projectId: task.projectId, slug: task.slug) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: task.state == .finished ? "checkmark.circle" : "waveform.path")
                                        .foregroundStyle(task.state == .finished ? LoomColors.attention : LoomColors.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.displayTitle).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                        Text(task.projectLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(task.state == .finished ? "To review" : "Working")
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                .padding(16).background(LoomColors.bgElev1, in: LoomShape.card)
                                .overlay(LoomShape.card.strokeBorder(LoomColors.border.opacity(0.7)))
                                .contentShape(LoomShape.card)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                HStack(spacing: 18) {
                    Label("Chat & steer", systemImage: "bubble.left.and.bubble.right")
                    Label("Watch the terminal", systemImage: "terminal")
                    Label("Review changes", systemImage: "arrow.triangle.branch")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(36).frame(maxWidth: .infinity)
        }
    }

    private func summary(_ title: String, count: Int, detail: String, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                Spacer()
                Text("\(count)").font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(color.opacity(0.055), in: LoomShape.card)
        .overlay(LoomShape.card.strokeBorder(color.opacity(0.18)))
    }
}
