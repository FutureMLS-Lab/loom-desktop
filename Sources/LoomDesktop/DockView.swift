import SwiftUI

/// The floating dock: a slim header strip (loom menu · status · hide) and,
/// when there is anything to show, the wrapped pills below it. The window's
/// own traffic lights sit on the header, so the whole surface reads as one
/// card rather than a window plus a bar.
struct DockView: View {
    @ObservedObject var store: TaskStore
    /// What the wrapped content came to. `PanelWindow` owns width and matches
    /// height to it.
    var onMeasure: (WrappingHStack.Metrics) -> Void = { _ in }
    var onHidePanel: () -> Void = {}

    /// One row by default: the dock is a glance, not a list. Expanding shows
    /// every pill, and the choice sticks across launches.
    @AppStorage("panelExpanded") private var expanded = false
    /// How many pills the collapsed row fits. Building the rest and hiding
    /// them offscreen still ran their animations — forty pills' worth of
    /// spinning and blinking for a dock showing three.
    @State private var fitCount = 0

    /// One more than fits, so a widened panel can discover the extra room;
    /// the probe converges upward a pill at a time.
    private var shownPills: [TaskPill] {
        expanded ? store.pills : Array(store.pills.prefix(fitCount + 1))
    }

    private var overflow: Int {
        max(0, store.pills.count - shownPills.count)
    }

    /// loom menu, counts, expand, hide.
    private static let headerItemCount = 4

    var body: some View {
        WrappingHStack(
            horizontalSpacing: 10,
            verticalSpacing: 8,
            maxRows: expanded ? nil : 1,
            onMeasure: { metrics in
                if !expanded {
                    let fit = max(0, metrics.visibleSubviews - Self.headerItemCount)
                    if fit != fitCount { fitCount = fit }
                }
                onMeasure(metrics)
            }
        ) {
            // Row 1: identity + controls. Always present — an empty fleet
            // collapses the panel to just this strip.
            LoomMenuButton(store: store)
            DockStatus(store: store)
            if !store.pills.isEmpty {
                ExpandButton(
                    expanded: expanded,
                    hidden: overflow,
                    action: { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } }
                )
            }
            HideButton(action: onHidePanel)

            if !store.pills.isEmpty {
                ForEach(shownPills) { pill in
                    TaskPillView(
                        pill: pill,
                        showProject: store.showsProjectPrefix,
                        action: {
                            store.acknowledge(pill)
                            store.select(projectId: pill.projectId, slug: pill.slug)
                            MainWindowController.shared.show(store: store)
                        },
                        onAcknowledge: { store.acknowledge(pill) }
                    )
                }
            }
        }
        .padding(.horizontal, DockView.contentInset)
        .padding(.vertical, DockView.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
        // The window's own corners are rounded by macOS and cannot be
        // squared off. Insetting the card by that radius means the curve
        // only ever clips transparent margin — the card stays square and
        // nothing on it gets sliced.
        .padding(DockView.cardMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut, value: store.pills)
    }

    static let contentInset: CGFloat = 8
    /// Transparent gap between the card and the window edge, sized to clear
    /// the system's window corner radius (larger on macOS 26 than the 10pt
    /// that still clipped the first and last pill).
    static let cardMargin: CGFloat = 16
    /// Every element on the dock is this tall, so a row reads as one band
    /// rather than a set of differently-sized chips.
    static let rowHeight: CGFloat = 28
}

/// Fleet menu — the loom knot on the left of the header.
private struct LoomMenuButton: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        Menu {
            Button("Open Loom (Projects)") {
                MainWindowController.shared.show(store: store)
            }
            Divider()
            if store.projects.isEmpty {
                Text("No projects registered")
            } else {
                ForEach(store.projects) { project in
                    let tasks = store.tasksByProject[project.id] ?? []
                    Menu(project.label) {
                        if tasks.isEmpty {
                            Text("No tasks")
                        } else {
                            ForEach(tasks, id: \.slug) { meta in
                                Button(meta.title ?? meta.slug) {
                                    store.select(projectId: project.id, slug: meta.slug)
                                    MainWindowController.shared.show(store: store)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Refresh now") { store.refreshNow() }
            Button("Settings…") { SettingsWindowController.shared.show() }
            Divider()
            Button("Quit Loom Desktop") { NSApp.terminate(nil) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [LoomColors.accent, LoomColors.green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("loom")
                    .font(.system(size: 13, weight: .semibold))
                ConnectionDot(connection: store.connection)
            }
            .padding(.horizontal, 10)
            .frame(height: DockView.rowHeight)
            .background(Color.primary.opacity(0.07), in: Rectangle())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ConnectionDot: View {
    let connection: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(help)
    }

    private var color: Color {
        switch connection {
        case .connecting: return .yellow
        case .online: return LoomColors.green
        case .offline: return .red
        }
    }

    private var help: String {
        switch connection {
        case .connecting: return "Connecting…"
        case .online: return "Connected to \(LoomSettings.baseURL)"
        case .offline(let message): return "Offline: \(message)"
        }
    }
}

/// Right side of the header: aggregate counts, or nothing when quiet.
private struct DockStatus: View {
    @ObservedObject var store: TaskStore

    private var working: Int { store.pills.filter { $0.state == .working }.count }
    private var finished: Int { store.pills.filter { $0.state == .finished }.count }

    var body: some View {
        HStack(spacing: 9) {
            if isOffline {
                Label("offline", systemImage: "wifi.exclamationmark")
                    .foregroundColor(LoomColors.amber)
            }
            if finished > 0 {
                Label("\(finished)", systemImage: "exclamationmark.circle.fill")
                    .foregroundColor(LoomColors.amber)
            }
            if working > 0 {
                Label("\(working)", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(LoomColors.accent)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, finished > 0 || working > 0 || isOffline ? 9 : 0)
        .frame(height: DockView.rowHeight)
        .background(
            (finished > 0 || working > 0 || isOffline)
                ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Color.clear),
            in: Rectangle()
        )
        .help("\(working) working · \(finished) finished and unseen")
    }

    private var isOffline: Bool {
        if case .offline = store.connection { return true }
        return false
    }
}

/// Show every row, or fold back to one. Carries the count of what is hidden,
/// so a single-row dock still says how much it is not showing.
private struct ExpandButton: View {
    let expanded: Bool
    let hidden: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !expanded && hidden > 0 {
                    Text("+\(hidden)")
                        .font(.system(size: 12, weight: .bold))
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(hovering ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: DockView.rowHeight)
            .background(
                Rectangle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Show one row" : "Show all \(hidden) hidden tasks")
        .onHover { hovering = $0 }
    }
}

/// The header's hide button — same role as the window's close light, which
/// also hides the panel.
private struct HideButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovering ? .primary : .secondary)
                .frame(width: DockView.rowHeight, height: DockView.rowHeight)
                .background(Color.primary.opacity(hovering ? 0.14 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide the dock (menu-bar icon brings it back)")
        .onHover { hovering = $0 }
    }
}

/// One Loom task with a live agent pane. Rotating ring while the agent works,
/// blinking ring + background flash once it finished unseen. Click opens the
/// task window; right-click offers quick actions.
struct TaskPillView: View {
    let pill: TaskPill
    let showProject: Bool
    let action: () -> Void
    let onAcknowledge: () -> Void

    @State private var isHovering = false

    /// A pill never gets wider than this. One 90-character research title
    /// would otherwise be the whole row (and force the panel wider than the
    /// screen); the full text is in the tooltip and the sidebar.
    private static let maxTitleWidth: CGFloat = 190

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: pill.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                if showProject {
                    Text(pill.projectLabel)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
                Text(pill.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .frame(height: DockView.rowHeight)
        }
        .buttonStyle(.plain)
        .background {
            switch pill.state {
            case .finished:
                PulsingFill(color: NSColor(LoomColors.accent))
            case .working:
                Color.gray.opacity(0.85)
            case .idle:
                Color.gray.opacity(0.7)
            }
        }
        .overlay {
            switch pill.state {
            case .working:
                PillRing(mode: .working).allowsHitTesting(false)
            case .finished:
                PillRing(mode: .finished).allowsHitTesting(false)
            case .idle:
                EmptyView()
            }
        }
        .scaleEffect(isHovering ? 1.04 : 1)
        .contentShape(Rectangle())
        .help("\(pill.projectLabel) / \(pill.slug)")
        .contextMenu {
            Button("Open") { action() }
            if pill.state == .finished {
                Button("Mark as Seen") { onAcknowledge() }
            }
            Button("Copy Slug") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pill.slug, forType: .string)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
