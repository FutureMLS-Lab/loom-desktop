import SwiftUI

/// Register a project without leaving the app. A project is a directory on the
/// Loom host, so the path is typed rather than picked — an open panel here
/// would browse this Mac, which is the wrong machine. The server offers the
/// children of the directory it was launched in, and those become shortcuts.
struct AddProjectView: View {
    @ObservedObject var store: TaskStore
    /// Called with the new project's id once the server has registered it.
    var onAdded: (String?) -> Void = { _ in }
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
    /// The path last filled in for the person, so that filling it in is not
    /// mistaken for their typing.
    @State private var suggestedPath = ""
    @FocusState private var pathFocused: Bool

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        guard !busy, !trimmedPath.isEmpty else { return false }
        // The prefilled prefix alone would register the launch directory.
        if source != .existing, isLaunchRoot(trimmedPath) { return false }
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
                .onChange(of: source) { _, mode in prefillPrefix(for: mode) }

                if source == .clone {
                    field("Repository") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("https://github.com/owner/repo.git", text: $repoURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .onChange(of: repoURL) { _, new in suggestPath(from: new) }
                            Text("A link copied from a GitHub page works too.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                field(source == .existing ? "Folder on the Loom host" : "New folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField(pathPlaceholder, text: $path)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .focused($pathFocused)
                                .onChange(of: path) { _, new in
                                    if pathFocused, new != suggestedPath { pathIsSuggested = false }
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
        // A URL pasted before the root arrived had nothing to suggest under.
        if source == .clone, !repoURL.isEmpty {
            suggestPath(from: repoURL)
        } else {
            prefillPrefix(for: source)
        }
    }

    private var rootPrefix: String {
        launchRoot.hasSuffix("/") ? launchRoot : launchRoot + "/"
    }

    private func isLaunchRoot(_ candidate: String) -> Bool {
        guard !launchRoot.isEmpty else { return false }
        func bare(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
        return bare(candidate) == bare(launchRoot)
    }

    private func suggest(_ value: String) {
        suggestedPath = value
        path = value
    }

    /// New folders and clones have to live under the launch root, so their
    /// path starts there.
    private func prefillPrefix(for mode: ProjectSource) {
        guard mode != .existing, pathIsSuggested, trimmedPath.isEmpty, !launchRoot.isEmpty else { return }
        suggest(rootPrefix)
    }

    /// `…/owner/repo.git` clones into `<launchRoot>/repo` unless the path has
    /// been typed in by hand.
    private func suggestPath(from url: String) {
        guard pathIsSuggested, !launchRoot.isEmpty else { return }
        var name = Self.cloneURL(from: url)
        if name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".git") { name.removeLast(4) }
        let leaf = name.lastIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? ""
        suggest(rootPrefix + leaf)
    }

    /// What `git clone` is given for what was pasted. A link copied from a
    /// GitHub page — a branch, a file, no scheme — is not a URL git can clone
    /// as written, so it is cut back to the repository it belongs to. Anything
    /// else, a URL carrying credentials included, goes through as typed.
    static func cloneURL(from raw: String) -> String {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = typed.lowercased()
        let candidate = lowered.hasPrefix("github.com/") || lowered.hasPrefix("www.github.com/")
            ? "https://" + typed
            : typed
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              url.user == nil
        else { return typed }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2 else { return typed }
        return "https://github.com/\(parts[0])/\(parts[1])"
    }

    private func add() {
        guard canAdd else { return }
        busy = true
        error = ""
        Task {
            do {
                let id = try await store.api.addProject(
                    path: trimmedPath,
                    source: source,
                    repoURL: Self.cloneURL(from: repoURL),
                    codeRoot: codeRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                onAdded(id)
                store.refreshNow()
                onDismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
