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

    /// A bounded panel with the add/remove bar attached at its foot, the way
    /// every macOS master list carries them — the bare List drew as one grey
    /// chip adrift in the window, with a + and − floating loose below it.
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
            .listStyle(.plain)
            Divider()
            HStack(spacing: 2) {
                Button {
                    let fresh = LoomServer(name: "New server", baseURL: LoomSettings.defaultBaseURL, token: "")
                    servers.append(fresh)
                    selectedID = fresh.id
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .help("Add a server")
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
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .disabled(servers.count <= 1)
                .help("Remove the selected server")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(3)
            .background(Color.primary.opacity(0.04))
        }
        .frame(width: 190, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
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
