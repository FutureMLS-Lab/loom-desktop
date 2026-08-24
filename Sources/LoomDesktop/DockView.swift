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
    /// Read so the dock redraws when the size is changed; the metrics
    /// themselves come from `DockScale`.
    @AppStorage(DockScale.key) private var scale = 1.0
    @AppStorage(DockTheme.key) private var theme = DockTheme.light.rawValue
    /// How many pills the collapsed row fits. Building the rest and hiding
    /// them offscreen still ran their animations — forty pills' worth of
    /// spinning and blinking for a dock showing three.
    @State private var fitCount = 0

    /// Only what is asking for something: running, or finished and unseen.
    ///
    /// An idle task is not news, and a dock of thirty grey pills buries the
    /// two that are. The rest are a click away in the loom menu and the main
    /// window, both of which still list everything.
    private var activePills: [TaskPill] {
        store.pills.filter { $0.state != .idle }
    }

    /// One more than fits, so a widened panel can discover the extra room;
    /// the probe converges upward a pill at a time.
    private var shownPills: [TaskPill] {
        expanded ? activePills : Array(activePills.prefix(fitCount + 1))
    }

    private var overflow: Int {
        max(0, activePills.count - shownPills.count)
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
            if !activePills.isEmpty {
                ExpandButton(
                    expanded: expanded,
                    hidden: overflow,
                    action: { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } }
                )
            }
            HideButton(action: onHidePanel)

            if !activePills.isEmpty {
                ForEach(shownPills) { pill in
                    TaskPillView(
                        pill: pill,
                        showProject: store.showsProjectPrefix,
                        action: {
                            // Selecting marks it seen.
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
        // The shadow hangs on the card's own backing shape rather than on the
        // card as a whole. A shadow over the whole card is computed from
        // everything inside it, so one pill animating had the compositor
        // redraw and re-shadow the entire dock every frame: 26 points of
        // WindowServer with the shadow out here, 9 with it moved down onto a
        // shape that never changes. This, not the animation, was what made the
        // machine drag whenever the dock was on screen.
        .background(
            Rectangle()
                .fill(DockPalette.card)
                .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
        )
        .overlay(
            Rectangle()
                .strokeBorder(DockPalette.cardEdge, lineWidth: 0.5)
        )
        // The window's own corners are rounded by macOS and cannot be
        // squared off. Insetting the card by that radius means the curve
        // only ever clips transparent margin — the card stays square and
        // nothing on it gets sliced.
        .padding(DockView.cardMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut, value: store.pills)
    }

    static var contentInset: CGFloat { (8 * DockScale.factor).rounded() }
    /// Transparent gap between the card and the window edge, sized to clear
    /// the system's window corner radius (larger on macOS 26 than the 10pt
    /// that still clipped the first and last pill). Not scaled: it answers to
    /// the system's corner, not to how big you like your pills.
    static let cardMargin: CGFloat = 16
    /// Every element on the dock is this tall, so a row reads as one band
    /// rather than a set of differently-sized chips.
    static var rowHeight: CGFloat { (28 * DockScale.factor).rounded() }
}

/// How large the dock draws itself.
///
/// A real size, not a zoom: the panel measures the content it is given and
/// sizes the window to fit, so scaling the metrics is what actually makes the
/// dock smaller — a visual transform would leave the window the same size
/// with the pills floating inside it.
/// Whether the dock is a dark card or a light one.
///
/// Carried by the panel's `NSAppearance` rather than by two sets of hardcoded
/// colours: everything on the card then follows, including the `.primary` and
/// `.secondary` the header's own controls ask for, which no palette of ours
/// would have reached.
enum DockTheme: String, CaseIterable {
    case light, dark, system

    static let key = "panelTheme"
    static let didChange = Notification.Name("loom.dockTheme.didChange")

    static var current: DockTheme {
        DockTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .light
    }

    static func set(_ theme: DockTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// `nil` follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Match System"
        }
    }
}

/// The dock's own surfaces. Each resolves against whichever appearance the
/// panel is wearing, so one setting restyles the whole card.
///
/// Built once as `static let`. A colour rebuilt on every read is one SwiftUI
/// cannot cache, and these are read on every pill of every pass.
enum DockPalette {
    private static func pair(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func warm(_ value: UInt32, _ alpha: Double = 1) -> NSColor {
        NSColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The card. Translucent but never blurred — a live blur costs the
    /// compositor four points whenever a pill animates over it.
    static let card = Color(nsColor: pair(light: warm(0xEFECE3, 0.94), dark: warm(0x16150F, 0.93)))
    /// The pill's face, a step away from the card so a pill reads as a pill.
    static let chipFace = Color(nsColor: pair(light: warm(0xFFFFFF), dark: warm(0x2C2A26)))
    /// Text on that face.
    static let chipText = Color(nsColor: pair(light: warm(0x1D1C17), dark: warm(0xFFFFFF)))
    /// The hairline round the card.
    static let cardEdge = Color(
        nsColor: pair(light: warm(0x000000, 0.10), dark: warm(0xFFFFFF, 0.14))
    )

    /// The travelling light. White reads as a glow on a dark face and as
    /// nothing at all on a white one, so on the light card it is the accent
    /// instead — the same idea carried by colour rather than by brightness.
    static let moteCore = pair(light: warm(0x4338CA, 0.62), dark: warm(0xFFFFFF, 0.55))
    static let moteHalo = pair(light: warm(0x2AA8BF, 0.34), dark: warm(0x429AAB, 0.28))
    static let moteEdge = pair(light: warm(0x2AA8BF, 0), dark: warm(0x429AAB, 0))

    /// The rim, lifted a little on the light card: a mid-tone that carries
    /// against near-black is quiet against near-white.
    static let rimAccent = pair(light: warm(0x4F46E5), dark: warm(0x5957C7))
    static let rimCyan = pair(light: warm(0x1E96AE), dark: warm(0x42A8BF))
    static let rimGreen = pair(light: warm(0x18A06A), dark: warm(0x42AD7A))
}

enum DockScale {
    static let key = "panelScale"

    static let choices: [(label: String, value: Double)] = [
        ("Small", 0.85), ("Medium", 1.0), ("Large", 1.2),
    ]

    static var factor: CGFloat {
        let stored = UserDefaults.standard.double(forKey: key)
        guard stored > 0 else { return 1 }
        return CGFloat(min(max(stored, 0.7), 1.5))
    }

    /// Point sizes are scaled through here so a chosen size reaches the type
    /// as well as the boxes around it.
    static func font(_ size: CGFloat) -> CGFloat { (size * factor).rounded() }
}

/// Fleet menu — the loom knot on the left of the header.
private struct LoomMenuButton: View {
    @ObservedObject var store: TaskStore
    @AppStorage(DockScale.key) private var scale = 1.0
    @AppStorage(DockTheme.key) private var theme = DockTheme.light.rawValue

    var body: some View {
        Menu {
            Button("Open Loom (Projects)") {
                MainWindowController.shared.show(store: store)
            }
            // Width is a drag on the panel's edge; this is the other axis —
            // how big the pills themselves are, which is what decides how
            // much of the screen the dock takes for a given number of tasks.
            Menu("Dock Size") {
                ForEach(DockScale.choices, id: \.value) { choice in
                    Button {
                        scale = choice.value
                    } label: {
                        if abs(scale - choice.value) < 0.01 {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            }
            Menu("Dock Theme") {
                ForEach(DockTheme.allCases, id: \.rawValue) { choice in
                    Button {
                        DockTheme.set(choice)
                        theme = choice.rawValue
                    } label: {
                        if theme == choice.rawValue {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            }
            // Which Loom this is, and the way to another one. Shown even with
            // a single server configured: hiding it until there are two left
            // no way to reach the place where a second one is added.
            Menu("Server: \(store.activeServerName)") {
                ForEach(store.servers) { server in
                    Button {
                        LoomSettings.activate(server)
                    } label: {
                        if server.id == store.activeServerID {
                            Label(server.name, systemImage: "checkmark")
                        } else {
                            Text(server.name)
                        }
                    }
                }
                Divider()
                Button("Add or edit servers…") { SettingsWindowController.shared.show() }
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
            if store.unseenCount > 0 {
                Button("Mark all \(store.unseenCount) as seen") { store.markAllSeen() }
            }
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

    private var color: Color { connection.dotColor }

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
                    .foregroundColor(LoomColors.attention)
            }
            if working > 0 {
                Label("\(working)", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(LoomColors.accent)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        // The counts tick as tasks start and finish; fixed-width digits keep
        // the header from shuffling sideways every time one does.
        .monospacedDigit()
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
                        .monospacedDigit()
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

    private var bandMode: PillBand.Mode? {
        switch pill.state {
        case .working: return .working
        case .finished: return .finished
        case .idle: return nil
        }
    }

    private static let chipFace = DockPalette.chipFace

    /// A pill never gets wider than this. One 90-character research title
    /// would otherwise be the whole row (and force the panel wider than the
    /// screen); the full text is in the tooltip and the sidebar.
    private static var maxTitleWidth: CGFloat { (190 * DockScale.factor).rounded() }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: pill.symbolName)
                    .font(.system(size: DockScale.font(11), weight: .medium))
                    .foregroundColor(DockPalette.chipText.opacity(0.75))
                if showProject && !pill.projectPrefixIsNoise {
                    Text(pill.projectLabel)
                        .font(.system(size: DockScale.font(12)))
                        .foregroundColor(DockPalette.chipText.opacity(0.66))
                        .lineLimit(1)
                        .frame(maxWidth: (110 * DockScale.factor).rounded(), alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .font(.system(size: DockScale.font(12)))
                        .foregroundColor(DockPalette.chipText.opacity(0.4))
                }
                Text(pill.displayTitle)
                    .font(.system(size: DockScale.font(13), weight: .medium))
                    .foregroundColor(DockPalette.chipText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, (12 * DockScale.factor).rounded())
            .frame(height: DockView.rowHeight)
        }
        .buttonStyle(.plain)
        // A lit edge around a dark face: the band fills the pill and the face
        // covers its middle, so what shows is a rim. Drawing a rim as a rim
        // would mean masking it to that shape, and a masked layer is redrawn
        // offscreen on every frame it changes.
        .background {
            ZStack {
                if let bandMode {
                    PillBand(mode: bandMode)
                } else {
                    Color.secondary.opacity(0.5)
                }
                Self.chipFace.padding(PillBand.rimWidth)
                if pill.state == .working {
                    PillMote().allowsHitTesting(false)
                }
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
