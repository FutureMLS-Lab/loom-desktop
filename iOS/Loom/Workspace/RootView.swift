import SwiftUI

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var selection: TaskRef?
    @State private var showServers = false

    var body: some View {
        Group {
            if workspace.hasServer {
                NavigationSplitView {
                    WorkspaceList(selection: $selection, showServers: $showServers)
                } detail: {
                    if let selection, let (project, meta) = workspace.meta(for: selection) {
                        TaskScreen(ref: selection, project: project, meta: meta)
                            .id(selection)
                    } else {
                        ContentUnavailableView(
                            "Pick a task",
                            systemImage: "rectangle.stack",
                            description: Text("Its conversation, terminal and plan open here.")
                        )
                    }
                }
            } else {
                OnboardingView(showServers: $showServers)
            }
        }
        .sheet(isPresented: $showServers) {
            ServersView(startAdding: !workspace.hasServer)
        }
        .onChange(of: workspace.activeServerID) { _, _ in selection = nil }
        #if DEBUG
        .onChange(of: workspace.tasksByProject.count) { _, _ in openRequestedTask() }
        #endif
    }

    #if DEBUG
    /// Simulator runs, which have no way to tap: launched with
    /// `-LoomOpenTask <part of a title>`, that task opens once it is listed.
    private func openRequestedTask() {
        guard selection == nil,
              let wanted = UserDefaults.standard.string(forKey: "LoomOpenTask"), !wanted.isEmpty
        else { return }
        for (projectId, tasks) in workspace.tasksByProject {
            if let task = tasks.first(where: { ($0.title ?? $0.slug).localizedCaseInsensitiveContains(wanted) }) {
                selection = TaskRef(projectId: projectId, slug: task.slug)
                return
            }
        }
    }
    #endif
}

private struct OnboardingView: View {
    @Binding var showServers: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(LoomColors.accent)
            VStack(spacing: 6) {
                Text("Connect to Loom")
                    .font(.title2.weight(.semibold))
                Text("Add the gateway your agents run behind — its URL and token.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showServers = true
            } label: {
                Label("Add Server", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LoomColors.bgBase)
    }
}
