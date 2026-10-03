import SwiftUI

/// The Looms this phone knows about, and which one is current.
struct ServersView: View {
    var startAdding = false
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: LoomServer?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if workspace.servers.isEmpty {
                    Text("No servers yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(workspace.servers) { server in
                    Button {
                        LoomSettings.activate(server)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: server.id == workspace.activeServerID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(server.id == workspace.activeServerID ? LoomColors.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name.isEmpty ? LoomServer.suggestedName(for: server.baseURL) : server.name)
                                    .foregroundStyle(.primary)
                                Text(server.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                editing = server
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            remove(server)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { server in
                ServerEditor(server: server) { save($0) }
            }
            .sheet(isPresented: $adding) {
                ServerEditor(server: nil) { save($0) }
            }
            .onAppear { if startAdding { adding = true } }
        }
    }

    private func save(_ server: LoomServer) {
        var list = workspace.hasServer ? LoomSettings.servers : []
        if let index = list.firstIndex(where: { $0.id == server.id }) {
            list[index] = server
            LoomSettings.servers = list
            if server.id == LoomSettings.activeServerID {
                LoomSettings.reload()
            } else {
                workspace.reloadServers()
            }
        } else {
            list.append(server)
            LoomSettings.servers = list
            if list.count == 1 {
                LoomSettings.activeServerID = server.id
                LoomSettings.reload()
            } else {
                workspace.reloadServers()
            }
        }
    }

    private func remove(_ server: LoomServer) {
        let list = LoomSettings.servers.filter { $0.id != server.id }
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: LoomSettings.serversKey)
            UserDefaults.standard.removeObject(forKey: LoomSettings.activeServerKey)
            LoomSettings.reload()
            return
        }
        LoomSettings.servers = list
        if server.id == LoomSettings.activeServerID, let first = list.first {
            LoomSettings.activeServerID = first.id
        }
        LoomSettings.reload()
    }
}

private struct ServerEditor: View {
    let server: LoomServer?
    let onSave: (LoomServer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var testing = false
    @State private var testResult: String?

    private var normalizedURL: String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private var valid: Bool {
        normalizedURL.hasPrefix("http://") || normalizedURL.hasPrefix("https://")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    TextField("https://gateway.example.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Group {
                            if showToken {
                                TextField("Token", text: $token)
                            } else {
                                SecureField("Token", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("The loom-app gateway's URL and its token, or a `loom web` instance started with `--auth-token`.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(!valid || testing)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(server == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(LoomServer(
                            id: server?.id ?? UUID().uuidString,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            baseURL: normalizedURL,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .onAppear {
                name = server?.name ?? ""
                url = server?.baseURL ?? ""
                token = server?.token ?? ""
            }
        }
    }

    /// Asks the server for its activity with what is typed here, before any
    /// of it is saved.
    private func test() async {
        testing = true
        defer { testing = false }
        guard let endpoint = URL(string: normalizedURL + "/api/activity") else {
            testResult = "That URL is not valid."
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: testResult = "Connected."
            case 401, 403: testResult = "Reached the server, but the token was refused (\(status))."
            default: testResult = "The server answered \(status)."
            }
        } catch {
            testResult = error.localizedDescription
        }
    }
}
