import SwiftUI

/// Every task, by project — stopped ones included, which the home list
/// leaves out.
struct AllTasksView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        List {
            ForEach(store.sections, id: \.project.id) { section in
                Section {
                    ForEach(section.items) { item in
                        NavigationLink(value: WatchRoute.task(item.ref)) {
                            TaskRow(item: item, showsProject: false, showsPreview: false)
                        }
                    }
                } header: {
                    ProjectHeader(project: section.project, items: section.items)
                }
            }
            if store.sections.isEmpty {
                Text(store.connection == .online ? "No tasks yet." : "Loading…")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("All Tasks")
        .containerBackground(LoomColors.accent.gradient, for: .navigation)
    }
}

private struct ProjectHeader: View {
    let project: LoomProject
    let items: [TaskItem]

    var body: some View {
        HStack(spacing: 6) {
            Text(project.label)
                .lineLimit(1)
            Spacer(minLength: 4)
            let working = items.filter { $0.state == .working }.count
            let waiting = items.filter(\.needsYou).count
            if working > 0 {
                count(working, symbol: "bolt.fill", tint: LoomColors.accent)
            }
            if waiting > 0 {
                count(waiting, symbol: "hand.raised.fill", tint: LoomColors.attention)
            }
        }
        .textCase(nil)
    }

    private func count(_ value: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
            Text("\(value)")
                .monospacedDigit()
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint)
    }
}
