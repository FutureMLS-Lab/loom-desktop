import SwiftUI

/// The main window, laid out like the Loom web console: a 320pt cream sidebar
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
    @State private var addProject = false
    /// The project whose code root is being edited, and the pattern typed so
    /// far. Two pieces of state because the alert outlives the menu that
    /// opened it.
    @State private var codeRootProject: LoomProject?
    @State private var codeRootDraft = ""
    @State private var projectToRemove: LoomProject?
    @State private var projectError = ""
    /// The task whose title is being edited, and the text typed so far.
    @State private var renameTarget: (projectId: String, meta: LoomTaskMeta)?
    @State private var renameDraft = ""

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
        .sheet(isPresented: $addProject) {
            AddProjectView(store: store) { addProject = false }
        }
        .alert(
            "Code root for \(codeRootProject?.label ?? "")",
            isPresented: Binding(
                get: { codeRootProject != nil },
                set: { if !$0 { codeRootProject = nil } }
            )
        ) {
            TextField(".", text: $codeRootDraft)
            Button("Cancel", role: .cancel) { codeRootProject = nil }
            Button("Save") { saveCodeRoot() }
        } message: {
            Text("Where this project's repositories live, relative to its "
                 + "folder. Worktree candidates are searched under it.")
        }
        .confirmationDialog(
            "Remove \(projectToRemove?.label ?? "") from Loom?",
            isPresented: Binding(
                get: { projectToRemove != nil },
                set: { if !$0 { projectToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { confirmRemoveProject() }
            Button("Cancel", role: .cancel) { projectToRemove = nil }
        } message: {
            Text("Loom forgets the folder and its tasks disappear from this "
                 + "list. Nothing on disk is deleted.")
        }
        .alert(
            "Rename task",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { saveRename() }
        } message: {
            Text("Only the title changes. The slug and the task's directory "
                 + "keep their names, so nothing running is disturbed.")
        }
        .alert("Couldn't make that change", isPresented: Binding(
            get: { !projectError.isEmpty },
            set: { if !$0 { projectError = "" } }
        )) {
            Button("OK") { projectError = "" }
        } message: {
            Text(projectError)
        }
    }

    private func saveRename() {
        guard let target = renameTarget else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        // Nothing typed, or nothing changed: nothing to send.
        guard !title.isEmpty, title != (target.meta.title ?? target.meta.slug) else { return }
        Task {
            do {
                try await store.api.renameTask(
                    projectId: target.projectId,
                    slug: target.meta.slug,
                    title: title
                )
                store.refreshNow()
            } catch {
                projectError = error.localizedDescription
            }
        }
    }

    private func saveCodeRoot() {
        guard let project = codeRootProject else { return }
        let pattern = codeRootDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        codeRootProject = nil
        Task {
            do {
                try await store.api.setCodeRoot(id: project.id, pattern: pattern)
                store.refreshNow()
            } catch {
                projectError = error.localizedDescription
            }
        }
    }

    private func confirmRemoveProject() {
        guard let project = projectToRemove else { return }
        projectToRemove = nil
        Task {
            do {
                try await store.api.removeProject(id: project.id)
                store.forget(projectId: project.id)
                store.refreshNow()
            } catch {
                projectError = error.localizedDescription
            }
        }
    }

    // MARK: Sidebar

    /// Which Loom this window is showing, at the top of the list it belongs
    /// to. The menus have the same switch, but this is where you look to
    /// answer "whose tasks are these" — so it says it without being asked.
    private var serverBar: some View {
        Menu {
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
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.connection.dotColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.activeServerName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(serverSubtitle)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(LoomColors.bgElev1, in: LoomShape.field)
            .overlay(
                LoomShape.field.strokeBorder(LoomColors.border, lineWidth: 1)
            )
            .contentShape(LoomShape.field)
        }
        // `.borderlessButton` throws the custom label away and draws its own;
        // the button style keeps the row exactly as built.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, -4)
        .help(LoomSettings.baseURL)
    }

    private var serverSubtitle: String {
        switch store.connection {
        case .online:
            let count = store.pills.count
            return count == 1 ? "1 task" : "\(count) tasks"
        case .connecting: return "Connecting…"
        case .offline: return "Can't reach this Loom"
        }
    }

    private var sidebar: some View {
        // Looked up once per render, not scanned per row: every task row asked
        // its state with a linear search of the pills, which made one sidebar
        // pass cost rows × pills comparisons.
        let stateByTask = Dictionary(
            store.pills.map { ($0.id, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        return VStack(spacing: 0) {
            serverBar

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
            .background(LoomColors.bgElev1, in: LoomShape.field)
            .overlay(
                LoomShape.field
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
                            stateFor: { slug in stateByTask["\(project.id)/\(slug)"] },
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
                            onRename: { meta in
                                renameDraft = meta.title ?? meta.slug
                                renameTarget = (project.id, meta)
                            },
                            onMoveTask: { slug, target in
                                store.moveTask(projectId: project.id, slug: slug, above: target)
                            },
                            onSetCodeRoot: {
                                codeRootDraft = "."
                                codeRootProject = project
                            },
                            onRemove: { projectToRemove = project }
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
                Menu {
                    Button("New Task…") { newTask = true }
                        .disabled(store.projects.isEmpty)
                    Button("Add Project…") { addProject = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New task (⌘N) or add a project")
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
                colors: [LoomColors.sidebarWashTop, LoomColors.sidebarWashBottom],
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
                    title: "No projects registered",
                    detail: "Add one with + at the bottom of the sidebar — an "
                        + "existing folder on the Loom host, a new one, or a repo to clone."
                )
            } else {
                EmptyDetail(
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
    let onRename: (LoomTaskMeta) -> Void
    let onMoveTask: (String, String) -> Void
    let onSetCodeRoot: () -> Void
    let onRemove: () -> Void

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
                    // Live counts; fixed-width digits so the header row does
                    // not shuffle when one of them ticks over.
                    Text("\(tasks.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    if let counts {
                        if counts.finished > 0 {
                            Label("\(counts.finished)", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(LoomColors.attention)
                        }
                        if counts.working > 0 {
                            Label("\(counts.working)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(LoomColors.accent)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(project.path, forType: .string)
                }
                Button("Set Code Root…", action: onSetCodeRoot)
                Divider()
                Button("Remove from Loom…", action: onRemove)
            }
            .help(project.path)

            if !collapsed {
                VStack(spacing: 4) {
                    ForEach(tasks, id: \.slug) { meta in
                        SidebarTaskRow(
                            meta: meta,
                            state: stateFor(meta.slug),
                            selected: selection == "\(project.id)/\(meta.slug)",
                            onSelect: { onSelect(meta.slug) },
                            onOpen: { onOpen(meta) },
                            onRename: { onRename(meta) }
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
        .background(LoomColors.bgElev1.opacity(0.62), in: LoomShape.card)
        .overlay(
            LoomShape.card
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
    let onRename: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                statusDot
                    .padding(.top, 2)
                // Two lines, then the tooltip. Wrapping without a limit reads
                // well for one title and badly for a list: a paper title runs
                // to four lines, stands four times taller than its neighbours
                // and pushes the rest of the project off the screen, so the
                // one row you can read costs you the ones you were scanning
                // for.
                Text(meta.title ?? meta.slug)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(rowBackground, in: LoomShape.control)
            .overlay(alignment: .leading) {
                // A standing edge on a task that finished unseen, so it
                // is findable in a long list even between blinks. Inset
                // and rounded, so it sits inside the row's corners.
                if state == .finished {
                    Capsule()
                        .fill(LoomColors.attention)
                        .frame(width: 3)
                        .padding(.vertical, 8)
                        .padding(.leading, 3)
                }
            }
            .overlay(
                LoomShape.control
                    .strokeBorder(
                        selected ? LoomColors.accent.opacity(0.28) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(LoomShape.control)
        }
        .buttonStyle(.plain)
        .help(meta.title ?? meta.slug)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .contextMenu {
            Button("Open Task") { onOpen() }
            Button("Rename…") { onRename() }
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
            Circle().fill(connection.dotColor).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .help(LoomSettings.baseURL)
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
    let title: String
    let detail: String

    // The mark sits above the words rather than behind them. As a watermark
    // it was 320pt of woven bars centred on a 300pt block of text, so every
    // line was read against a stripe — the two were the same size and in the
    // same place, which is the one arrangement where a backdrop cannot stay
    // out of the way.
    var body: some View {
        VStack(spacing: 16) {
            LoomMark(size: 92, opacity: 0.55)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Loom weave, softened — what an empty pane shows instead of nothing.
struct LoomMark: View {
    var size: CGFloat = 320
    var opacity: Double = 0.14

    var body: some View {
        Group {
            if let weave = LoomMark.weave {
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
        .opacity(opacity)
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
