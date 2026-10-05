import SwiftUI

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var sessions: SessionCache
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
        // The selected task polls; the task screen asks the cache for its
        // session, which starts it, and the previous one stops.
        .onChange(of: selection) { _, selected in
            if selected == nil { sessions.deactivate() }
        }
        #if DEBUG
        .onChange(of: workspace.tasksByProject.count) { _, _ in openRequestedTask() }
        .task { await runScript() }
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
                let ref = TaskRef(projectId: projectId, slug: task.slug)
                selection = ref
                // `-LoomBounceTask YES`: leave before the first read lands, come back.
                if UserDefaults.standard.bool(forKey: "LoomBounceTask") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { selection = nil }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { selection = ref }
                }
                return
            }
        }
    }

    /// `-LoomScript "open <title>; wait 6; tab terminal; back; …"`: a
    /// sequence of navigation, for reproducing on the simulator what was
    /// done by hand on a phone.
    private func runScript() async {
        guard let script = UserDefaults.standard.string(forKey: "LoomScript"), !script.isEmpty else { return }
        while workspace.tasksByProject.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for step in script.split(separator: ";") {
            let words = step.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let verb = words.first else { continue }
            let argument = words.count > 1 ? words[1] : ""
            print("[script] \(verb) \(argument)")
            switch verb {
            case "open":
                selection = workspace.tasksByProject.lazy.compactMap { projectId, tasks in
                    tasks.first { ($0.title ?? $0.slug).localizedCaseInsensitiveContains(argument) }
                        .map { TaskRef(projectId: projectId, slug: $0.slug) }
                }.first
            case "back":
                selection = nil
            case "tab":
                UserDefaults.standard.set(argument, forKey: "taskTab")
            case "wait":
                try? await Task.sleep(nanoseconds: UInt64((Double(argument) ?? 1) * 1_000_000_000))
            default:
                break
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
