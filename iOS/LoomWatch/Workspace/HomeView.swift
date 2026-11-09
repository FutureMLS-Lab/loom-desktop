import SwiftUI

/// The fleet from the wrist: what needs you first, then what is working,
/// then the agents sitting at a prompt. Stopped tasks are under All Tasks —
/// the same choice the desktop dock makes, for the same reason.
struct HomeView: View {
    @EnvironmentObject private var store: WatchStore
    @EnvironmentObject private var router: WatchRouter

    var body: some View {
        let live = store.liveItems
        let needsYou = live.filter(\.needsYou)
        let working = live.filter { $0.state == .working && !$0.needsYou }
        let ready = live.filter { $0.state == .idle && !$0.needsYou }

        List {
            Section {
                SummaryTiles(working: store.workingCount, needsYou: needsYou.count)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } header: {
                ServerLine()
            }

            if case .offline(let message) = store.connection {
                Section { OfflineRow(server: store.activeServerName, message: message) }
            }

            if !needsYou.isEmpty {
                Section("Needs you") { rows(needsYou) }
            }
            if !working.isEmpty {
                Section("Working") { rows(working) }
            }
            if !ready.isEmpty {
                Section("Ready") { rows(ready) }
            }

            if live.isEmpty, store.connection == .online {
                Section {
                    QuietRow(tasks: store.taskCount)
                        .listRowBackground(Color.clear)
                }
            } else if live.isEmpty, store.connection == .connecting {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                NavigationLink(value: WatchRoute.allTasks) {
                    LabeledContent {
                        Text("\(store.taskCount)")
                            .monospacedDigit()
                    } label: {
                        Label("All Tasks", systemImage: "square.stack.3d.up")
                    }
                }
                NavigationLink(value: WatchRoute.servers) {
                    Label(store.activeServerName, systemImage: "server.rack")
                        .lineLimit(1)
                }
            }
        }
        .navigationTitle("Loom")
        .containerBackground(LoomColors.accent.gradient, for: .navigation)
        .refreshable { await store.refresh() }
        #if DEBUG
        // Simulator runs, which cannot tap: `-LoomWatchOpen <part of a title>`.
        .onChange(of: store.taskCount) { _, _ in openRequestedTask() }
        #endif
    }

    private func rows(_ items: [TaskItem]) -> some View {
        ForEach(items) { item in
            NavigationLink(value: WatchRoute.task(item.ref)) {
                TaskRow(item: item)
            }
        }
    }

    #if DEBUG
    private func openRequestedTask() {
        guard router.path.isEmpty,
              let wanted = UserDefaults.standard.string(forKey: "LoomWatchOpen"), !wanted.isEmpty,
              let item = store.sections.flatMap(\.items).first(where: {
                  $0.title.localizedCaseInsensitiveContains(wanted)
              })
        else { return }
        router.path = [.task(item.ref)]
    }
    #endif
}

private struct ServerLine: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.connection.dotColor)
                .frame(width: 6, height: 6)
            Text(store.activeServerName)
                .lineLimit(1)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.activeServerName), \(connectionLabel)")
    }

    private var connectionLabel: String {
        switch store.connection {
        case .connecting: return "connecting"
        case .online: return "connected"
        case .offline: return "offline"
        }
    }
}

private struct SummaryTiles: View {
    let working: Int
    let needsYou: Int

    var body: some View {
        HStack(spacing: 6) {
            Tile(value: working, title: "Working", symbol: "bolt.fill", tint: LoomColors.accent)
            Tile(value: needsYou, title: "Needs you", symbol: "hand.raised.fill", tint: LoomColors.attention)
        }
    }

    private struct Tile: View {
        let value: Int
        let title: String
        let symbol: String
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                }
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(value > 0 ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .animation(.snappy, value: value)
        }
    }
}

private struct OfflineRow: View {
    let server: String
    let message: String
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Can't reach \(server)", systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LoomColors.amber)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button("Retry") { store.refreshNow() }
                .font(.footnote)
        }
    }
}

private struct QuietRow: View {
    let tasks: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "moon.stars")
                .font(.title3)
                .foregroundStyle(LoomColors.accent)
            Text("All quiet")
                .font(.headline)
            Text(tasks == 0 ? "No tasks yet." : "No agent is running. \(tasks == 1 ? "1 task" : "\(tasks) tasks") under All Tasks.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}
