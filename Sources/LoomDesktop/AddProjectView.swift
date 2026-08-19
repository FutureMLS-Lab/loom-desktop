import SwiftUI

/// Register a project without leaving the app. A project is a directory on the
/// Loom host, so the path is typed rather than picked — an open panel here
/// would browse this Mac, which is the wrong machine. The server offers the
/// children of the directory it was launched in, and those become shortcuts.
struct AddProjectView: View {
    @ObservedObject var store: TaskStore
    let onDismiss: () -> Void

    @State private var source = ProjectSource.existing
    @State private var path = ""
    @State private var repoURL = ""
    @State private var codeRoot = "."
    @State private var launchRoot = ""
    @State private var children: [ProjectsResponse.LaunchChild] = []
    @State private var busy = false
    @State private var error = ""
    /// Cleared once the path is typed in, so a repo URL stops overwriting it.
    @State private var pathIsSuggested = true
    @FocusState private var pathFocused: Bool

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        guard !busy, !trimmedPath.isEmpty else { return false }
        if source == .clone {
            return !repoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var actionLabel: String {
        switch source {
        case .existing: return busy ? "Adding…" : "Add"
        case .empty: return busy ? "Creating…" : "Create & add"
        case .clone: return busy ? "Cloning…" : "Clone & add"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add project")
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $source) {
                    ForEach(ProjectSource.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if source == .clone {
                    field("Repository") {
                        TextField("https://github.com/owner/repo.git", text: $repoURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onChange(of: repoURL) { _, new in suggestPath(from: new) }
                    }
                }

                field(source == .existing ? "Folder on the Loom host" : "New folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField(pathPlaceholder, text: $path)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .focused($pathFocused)
                                .onChange(of: path) { _, _ in
                                    if pathFocused { pathIsSuggested = false }
                                }
                            if !children.isEmpty {
                                Menu("Browse") {
                                    ForEach(children) { child in
                                        Button(child.name) {
                                            path = child.path
                                            pathIsSuggested = false
                                        }
                                    }
                                }
                                .menuStyle(.button)
                                .fixedSize()
                                .help("Folders in \(launchRoot)")
                            }
                        }
                        if source != .existing, !launchRoot.isEmpty {
                            Text("Must be inside \(launchRoot)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                field("Code root") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(".", text: $codeRoot)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        Text("Where the repositories live, relative to the project. "
                             + "Leave as “.” unless they sit in a subfolder.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(LoomColors.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel) { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LoomColors.accent)
                    .disabled(!canAdd)
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(width: 540, height: 460)
        .background(LoomColors.bgElev1)
        .task { await loadLaunchRoot() }
        .onAppear { pathFocused = true }
    }

    private var pathPlaceholder: String {
        launchRoot.isEmpty ? "/path/on/the/loom/host" : "\(launchRoot)/my-project"
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func loadLaunchRoot() async {
        guard let workspace = try? await store.api.workspace() else { return }
        launchRoot = workspace.launchRoot ?? ""
        children = workspace.launchRootChildren ?? []
    }

    /// `…/owner/repo.git` clones into `<launchRoot>/repo` unless the path has
    /// been typed in by hand.
    private func suggestPath(from url: String) {
        guard pathIsSuggested, !launchRoot.isEmpty else { return }
        var name = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard let slash = name.lastIndex(of: "/"), slash < name.endIndex else { return }
        let leaf = String(name[name.index(after: slash)...])
        path = leaf.isEmpty ? "" : "\(launchRoot)/\(leaf)"
    }

    private func add() {
        guard canAdd else { return }
        busy = true
        error = ""
        Task {
            do {
                try await store.api.addProject(
                    path: trimmedPath,
                    source: source,
                    repoURL: repoURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    codeRoot: codeRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                store.refreshNow()
                onDismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
