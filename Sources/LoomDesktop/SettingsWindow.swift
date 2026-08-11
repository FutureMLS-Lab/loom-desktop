import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(LoomSettings.baseURLKey) private var baseURL = LoomSettings.defaultBaseURL
    @AppStorage(LoomSettings.tokenKey) private var token = ""
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Loom URL")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(LoomSettings.defaultBaseURL, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                Text("The loom-app gateway (default :8787) or a `loom web` instance (e.g. http://127.0.0.1:8765) — possibly through an SSH tunnel.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Auth token")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("Bearer token (optional)", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text("Sent as Authorization: Bearer. Leave empty when the gateway needs none.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Apply & Reconnect") { onApply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
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
