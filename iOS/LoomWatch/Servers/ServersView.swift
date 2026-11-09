import SwiftUI

/// The Looms the iPhone handed over, and which one the watch is showing.
/// Editing them happens on the phone, where a token can be pasted.
struct ServersView: View {
    @EnvironmentObject private var store: WatchStore
    @EnvironmentObject private var phone: PhoneSync

    var body: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    Button {
                        LoomSettings.activate(server)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: server.id == store.activeServerID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(server.id == store.activeServerID ? LoomColors.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name.isEmpty ? LoomServer.suggestedName(for: server.baseURL) : server.name)
                                    .lineLimit(1)
                                Text(server.baseURL)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } footer: {
                Text("Servers come from Loom on your iPhone. Add or edit them there.")
            }

            Section {
                Button {
                    phone.requestServers()
                } label: {
                    HStack {
                        Label("Sync from iPhone", systemImage: "arrow.triangle.2.circlepath")
                        Spacer(minLength: 0)
                        if phone.requesting { ProgressView().frame(width: 18) }
                    }
                }
                .disabled(!phone.phoneReachable || phone.requesting)
            } footer: {
                if let last = phone.lastSync {
                    Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                } else if !phone.phoneReachable {
                    Text("Your iPhone isn't reachable right now.")
                }
            }
        }
        .navigationTitle("Servers")
        .containerBackground(LoomColors.accent.gradient, for: .navigation)
    }
}
