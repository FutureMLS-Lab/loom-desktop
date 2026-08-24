import AppKit
import SwiftUI

/// Connection settings for however many Looms you run: one machine's gateway
/// and another's, switched from here or from the loom menu.
struct SettingsView: View {
    @State private var servers: [LoomServer] = LoomSettings.servers
    @State private var selectedID: String = LoomSettings.activeServerID
    var onApply: () -> Void

    private var selectedIndex: Int? {
        servers.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Servers")
                .font(.system(size: 13, weight: .semibold))

            HStack(alignment: .top, spacing: 12) {
                serverList
                editor
            }

            HStack {
                Text(
                    LoomSettings.activeServerID == selectedID
                        ? "This is the server in use."
                        : "Applying switches to this server."
                )
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                Spacer()
                Button("Apply & Reconnect") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620)
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(servers) { server in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(
                                server.id == LoomSettings.activeServerID
                                    ? LoomColors.green
                                    : Color.secondary.opacity(0.35)
                            )
                            .frame(width: 7, height: 7)
                        Text(server.name.isEmpty ? LoomServer.suggestedName(for: server.baseURL) : server.name)
                            .lineLimit(1)
                    }
                    .tag(server.id)
                }
            }
            .frame(width: 190, height: 176)
            HStack(spacing: 0) {
                Button {
                    let fresh = LoomServer(name: "New server", baseURL: LoomSettings.defaultBaseURL, token: "")
                    servers.append(fresh)
                    selectedID = fresh.id
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    guard let index = selectedIndex, servers.count > 1 else { return }
                    let removed = servers.remove(at: index)
                    if removed.id == LoomSettings.activeServerID,
                       let first = servers.first {
                        LoomSettings.servers = servers
                        LoomSettings.activate(first)
                    }
                    selectedID = servers.first?.id ?? ""
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(servers.count <= 1)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let index = selectedIndex {
            VStack(alignment: .leading, spacing: 10) {
                field("Name", text: $servers[index].name, prompt: LoomServer.suggestedName(for: servers[index].baseURL))
                VStack(alignment: .leading, spacing: 4) {
                    field("Loom URL", text: $servers[index].baseURL, prompt: LoomSettings.defaultBaseURL)
                    Text("The loom-app gateway (default :8787) or a `loom web` instance (e.g. http://127.0.0.1:8765) — possibly through an SSH tunnel.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auth token")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    SecureField("Bearer token (optional)", text: $servers[index].token)
                        .textFieldStyle(.roundedBorder)
                    Text("Sent as Authorization: Bearer. Leave empty when the gateway needs none.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Select a server")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func apply() {
        LoomSettings.servers = servers
        if let chosen = servers.first(where: { $0.id == selectedID }) {
            if chosen.id == LoomSettings.activeServerID {
                // Same server, edited: re-read it rather than switch.
                LoomSettings.reload()
            } else {
                LoomSettings.activate(chosen)
            }
        }
        onApply()
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    var store: TaskStore?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loom Desktop Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView { [weak self] in
                    self?.store?.refreshNow()
                    self?.window?.close()
                }
            )
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
