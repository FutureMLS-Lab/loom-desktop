import SwiftUI

/// The main window, laid out like the Loom web console: a 300pt cream sidebar
/// of card sections (one per project, tasks inside), and a content pane on the
/// right. Task titles wrap instead of truncating — a slug like
/// "Is Quantization Noise Really Exploration?…" is the only way to tell two
/// tasks apart, so cutting it off defeats the list.
struct ProjectPickerView: View {
    @ObservedObject var store: TaskStore
    @StateObject private var sessions = SessionCache()
    @State private var projectDropTarget: String?
    @State private var collapsed: Set<String> = []
    @State private var search = ""

    /// Selection lives on the store so a dock pill and the sidebar drive this
    /// one view instead of opening windows.
    private var selection: String? { store.selection }
    private var projects: [LoomProject] { store.projects }

    @State private var quickOpen = false
    @State private var newTask = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LoomColors.bgBase)
        .frame(minWidth: 940, minHeight: 640)
        .onAppear { store.refreshNow() }
        .background(
            // Invisible shortcut hosts: a button is the simplest way to
            // register one that works wherever focus happens to be.
            ZStack {
                Button("Open Task…") { quickOpen = true }
                    .keyboardShortcut("p", modifiers: .command)
                Button("New Task…") { newTask = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .opacity(0)
        )
        .sheet(isPresented: $newTask) {
            NewTaskView(
                store: store,
                onCreated: { projectId, slug in
                    store.select(projectId: projectId, slug: slug)
                },
                onDismiss: { newTask = false }
            )
        }
        .sheet(isPresented: $quickOpen) {
            QuickOpenView(
                store: store,
                onOpen: { projectId, slug in
                    store.select(projectId: projectId, slug: slug)
                },
                onDismiss: { quickOpen = false }
            )
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                TextField("Filter tasks", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(LoomColors.bgElev1, in: Rectangle())
            .overlay(
                Rectangle()
                    .strokeBorder(LoomColors.border, lineWidth: 1)
            )
            .padding(12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredProjects, id: \.id) { project in
                        ProjectCard(
                            project: project,
                            tasks: filteredTasks(for: project.id),
                            counts: store.projectCounts(for: project.id),
                            collapsed: collapsed.contains(project.id),
                            selection: selection,
                            stateFor: { slug in
                                store.pills.first {
                                    $0.projectId == project.id && $0.slug == slug
                                }?.state
                            },
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    if collapsed.contains(project.id) {
                                        collapsed.remove(project.id)
                                    } else {
                                        collapsed.insert(project.id)
                                    }
                                }
                            },
                            onSelect: { slug in store.select(projectId: project.id, slug: slug) },
                            onOpen: { meta in store.select(projectId: project.id, slug: meta.slug) },
                            onMoveTask: { slug, target in
                                store.moveTask(projectId: project.id, slug: slug, above: target)
                            }
                        )
                        .draggable(DragPayload.project(id: project.id).text)
                        .dropDestination(for: String.self) { items, _ in
                            guard let payload = items.compactMap(DragPayload.init).first,
                                  case let .project(id) = payload
                            else { return false }
                            store.moveProject(id, above: project.id)
                            return true
                        } isTargeted: { over in
                            projectDropTarget = over
                                ? project.id
                                : (projectDropTarget == project.id ? nil : projectDropTarget)
                        }
                        .overlay(alignment: .top) {
                            if projectDropTarget == project.id {
                                Rectangle()
                                    .fill(LoomColors.accent)
                                    .frame(height: 2)
                            }
                        }
                    }
                    if filteredProjects.isEmpty {
                        Text(emptyListMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }

            Divider()
            HStack(spacing: 8) {
                ConnectionPill(connection: store.connection)
                Spacer()
                Button { newTask = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("New task (⌘N)")
                Button { store.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button { SettingsWindowController.shared.show() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .background(
            LinearGradient(
                colors: [LoomColors.dynamic(light: 0xF8F6F0, dark: 0x22211B),
                         LoomColors.dynamic(light: 0xEBE7DC, dark: 0x1B1A15)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var filteredProjects: [LoomProject] {
        guard !search.isEmpty else { return projects }
        return projects.filter { !filteredTasks(for: $0.id).isEmpty }
    }

    private func filteredTasks(for projectId: String) -> [LoomTaskMeta] {
        let all = store.tasksByProject[projectId] ?? []
        guard !search.isEmpty else { return all }
        let needle = search.lowercased()
        return all.filter {
            ($0.title ?? "").lowercased().contains(needle)
                || $0.slug.lowercased().contains(needle)
        }
    }

    /// An empty list has three quite different causes, and saying "No projects
    /// yet" for all of them tells someone whose gateway is down that their
    /// work is gone.
    private var emptyListMessage: String {
        guard store.projects.isEmpty else { return "No matches" }
        switch store.connection {
        case .offline: return "Can't reach Loom"
        case .connecting: return "Connecting…"
        case .online: return "No projects yet"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch store.connection {
        case .offline(let message):
            OfflineDetail(message: message) { store.refreshNow() }
        case .connecting where projects.isEmpty:
            VStack(spacing: 10) {
                ProgressView()
                Text("Connecting to Loom…")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if let selection, let (project, meta) = store.meta(forSelection: selection) {
                // The task opens right here — no second window to manage.
                TaskPane(
                    session: sessions.session(
                        projectId: project.id,
                        slug: meta.slug,
                        title: meta.title ?? meta.slug,
                        projectLabel: project.label
                    )
                )
                .id(selection)
            } else if projects.isEmpty {
                EmptyDetail(
                    symbol: "square.grid.2x2",
                    title: "No projects registered",
                    detail: "Register projects in the Loom web console, or check the gateway settings."
                )
            } else {
                EmptyDetail(
                    symbol: "sidebar.left",
                    title: "Select a task",
                    detail: "Pick a task on the left to see its status and open it."
                )
            }
        }
    }

    static func split(_ selection: String) -> (String, String)? {
        guard let slash = selection.firstIndex(of: "/") else { return nil }
        return (String(selection[..<slash]), String(selection[selection.index(after: slash)...]))
    }
}

// MARK: - Sidebar pieces

/// One project = one card, mirroring `.sidebar__section` in the web console.
private struct ProjectCard: View {
    let project: LoomProject
    let tasks: [LoomTaskMeta]
    let counts: (working: Int, finished: Int)?
    let collapsed: Bool
    let selection: String?
    let stateFor: (String) -> TaskPill.State?
    let onToggle: () -> Void
    let onSelect: (String) -> Void
    let onOpen: (LoomTaskMeta) -> Void
    let onMoveTask: (String, String) -> Void

    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(project.label.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.7)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(tasks.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    if let counts {
                        if counts.finished > 0 {
                            Label("\(counts.finished)", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(LoomColors.attention)
                        }
                        if counts.working > 0 {
                            Label("\(counts.working)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(LoomColors.accent)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                VStack(spacing: 4) {
                    ForEach(tasks, id: \.slug) { meta in
                        SidebarTaskRow(
                            meta: meta,
                            state: stateFor(meta.slug),
                            selected: selection == "\(project.id)/\(meta.slug)",
                            onSelect: { onSelect(meta.slug) },
                            onOpen: { onOpen(meta) }
                        )
                        .draggable(DragPayload.task(project: project.id, slug: meta.slug).text)
                        .dropDestination(for: String.self) { items, _ in
                            guard let payload = items.compactMap(DragPayload.init).first,
                                  case let .task(fromProject, slug) = payload,
                                  fromProject == project.id
                            else { return false }
                            onMoveTask(slug, meta.slug)
                            return true
                        } isTargeted: { over in
                            dropTarget = over ? meta.slug : (dropTarget == meta.slug ? nil : dropTarget)
                        }
                        .overlay(alignment: .top) {
                            if dropTarget == meta.slug {
                                Rectangle()
                                    .fill(LoomColors.accent)
                                    .frame(height: 2)
                            }
                        }
                    }
                    if tasks.isEmpty {
                        Text("No tasks")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(11)
        .background(LoomColors.bgElev1.opacity(0.62), in: Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(LoomColors.border.opacity(0.78), lineWidth: 1)
        )
    }
}

private struct SidebarTaskRow: View {
    let meta: LoomTaskMeta
    let state: TaskPill.State?
    let selected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                statusDot
                    .padding(.top, 2)
                // Wrapping, not truncating: long research-paper titles are
                // the ones you most need to read in full.
                Text(meta.title ?? meta.slug)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(rowBackground, in: Rectangle())
            .overlay(alignment: .leading) {
                // A standing edge on a task that finished unseen, so it
                // is findable in a long list even between blinks.
                if state == .finished {
                    Rectangle()
                        .fill(LoomColors.attention)
                        .frame(width: 3)
                }
            }
            .overlay(
                Rectangle()
                    .strokeBorder(
                        selected ? LoomColors.accent.opacity(0.28) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .contextMenu {
            Button("Open Task") { onOpen() }
            Button("Copy Slug") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meta.slug, forType: .string)
            }
        }
    }

    private var rowBackground: Color {
        if selected { return LoomColors.accentSoft }
        if state == .finished { return LoomColors.attention.opacity(0.10) }
        return hovering ? LoomColors.bgElev1 : LoomColors.bgElev1.opacity(0.72)
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .working:
            LoomActivityDot(size: 12)
        case .finished:
            LoomBlinkDot(size: 12)
        case .idle:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.2)
                .frame(width: 9, height: 9)
        case nil:
            Circle()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 9, height: 9)
        }
    }
}

private struct ConnectionPill: View {
    let connection: ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .help(LoomSettings.baseURL)
    }

    private var color: Color {
        switch connection {
        case .connecting: return LoomColors.amber
        case .online: return LoomColors.green
        case .offline: return LoomColors.red
        }
    }

    private var label: String {
        switch connection {
        case .connecting: return "Connecting…"
        case .online: return "Connected"
        case .offline: return "Offline"
        }
    }
}

private struct OfflineDetail: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(LoomColors.amber)
            Text("Cannot reach the Loom backend")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack(spacing: 10) {
                Button("Open Settings") { SettingsWindowController.shared.show() }
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(LoomColors.accent)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyDetail: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            LoomWatermark()
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundColor(.secondary.opacity(0.7))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A ghost of the Loom mark behind an empty pane — enough to say whose
/// window this is without competing with the text on top of it.
struct LoomWatermark: View {
    var size: CGFloat = 320

    var body: some View {
        Group {
            if let weave = LoomWatermark.weave {
                Image(nsImage: weave)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [LoomColors.accent, LoomColors.green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .opacity(0.14)
        .allowsHitTesting(false)
    }

    /// The app icon with its cream tile dissolved away. The tile is neutral
    /// and the weave is saturated, so per-pixel saturation is what separates
    /// them — luminance does not, since both are light.
    private static let weave: NSImage? = {
        guard let url = Bundle.main.url(forResource: "loom-mark", withExtension: "png"),
              let source = NSImage(contentsOf: url),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let highest = max(r, g, b)
            let saturation = highest <= 0 ? 0 : (highest - min(r, g, b)) / highest
            let alpha = min(1, saturation * 1.8)
            // Premultiplied: scale the colour by the alpha it now carries.
            pixels[index] = UInt8(r * alpha * 255)
            pixels[index + 1] = UInt8(g * alpha * 255)
            pixels[index + 2] = UInt8(b * alpha * 255)
            pixels[index + 3] = UInt8(alpha * 255)
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }()
}

/// What a sidebar drag carries. Tasks and projects are dragged in the same
/// list, so each says which it is and a drop ignores the other kind.
private enum DragPayload {
    case task(project: String, slug: String)
    case project(id: String)

    var text: String {
        switch self {
        case let .task(project, slug): return "loom-task:\(project)/\(slug)"
        case let .project(id): return "loom-project:\(id)"
        }
    }

    init?(_ text: String) {
        if text.hasPrefix("loom-task:") {
            let body = String(text.dropFirst("loom-task:".count))
            guard let slash = body.firstIndex(of: "/") else { return nil }
            self = .task(
                project: String(body[..<slash]),
                slug: String(body[body.index(after: slash)...])
            )
        } else if text.hasPrefix("loom-project:") {
            self = .project(id: String(text.dropFirst("loom-project:".count)))
        } else {
            return nil
        }
    }
}
