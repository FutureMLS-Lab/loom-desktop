import AppKit
import SwiftUI

/// Task markdown as a tiny editor: a folder list on the left, source on the
/// right. The old SwiftUI markdown renderer froze on large `PLAN.md` files;
/// an `NSTextView` does not. `PLAN.md` / `WIKI.md` can be saved back through
/// the gateway's template API — everything else stays read-only.
struct PlanView: View {
    @ObservedObject var session: ChatSession

    @State private var files: [PlanFile] = []
    @State private var selected = ""
    @State private var draft = ""
    @State private var savedBaseline = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error = ""
    @State private var status = ""
    /// Bumped when the editor must accept an external buffer (load / file switch).
    @State private var editorRevision = 0
    @State private var autosaveTask: Task<Void, Never>?
    /// Source = edit markdown; Preview = browser page; Split = both.
    @AppStorage("filesViewMode") private var viewModeRaw = ViewMode.preview.rawValue

    private enum ViewMode: String, CaseIterable, Identifiable {
        case edit, preview, split
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return "Edit"
            case .preview: return "Preview"
            case .split: return "Split"
            }
        }
        /// For the narrow header, where the words do not fit.
        var symbol: String {
            switch self {
            case .edit: return "pencil"
            case .preview: return "eye"
            case .split: return "rectangle.split.2x1"
            }
        }
    }

    private var viewMode: ViewMode {
        get { ViewMode(rawValue: viewModeRaw) ?? .preview }
        nonmutating set { viewModeRaw = newValue.rawValue }
    }

    private static let writable: Set<String> = ["PLAN.md", "WIKI.md"]

    struct PlanFile: Identifiable, Equatable {
        let name: String
        let content: String
        var id: String { name }

        var isDirectoryHint: Bool { name.contains("/") }
        var displayName: String { (name as NSString).lastPathComponent }
    }

    private var current: PlanFile? {
        files.first { $0.name == selected } ?? files.first
    }

    private var dirty: Bool { draft != savedBaseline }
    private var canEdit: Bool {
        guard let name = current?.name else { return false }
        return Self.writable.contains((name as NSString).lastPathComponent)
            || Self.writable.contains(name)
    }

    var body: some View {
        Group {
            if loading && files.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading files…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty && files.isEmpty {
                emptyState(
                    symbol: "exclamationmark.triangle",
                    title: "Files unavailable",
                    detail: error
                )
            } else if files.isEmpty {
                emptyState(
                    symbol: "folder",
                    title: "No markdown yet",
                    detail: "Run the deep interview and the agent will write PLAN.md."
                )
            } else {
                HSplitView {
                    fileSidebar
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    editorPane
                        .frame(minWidth: 320)
                }
            }
        }
        .background(LoomColors.bgElev1)
        .task(id: session.id) { await load() }
        .onChange(of: session.planRevision) { _, _ in
            guard !dirty else { return }
            Task { await load() }
        }
        .onChange(of: draft) { _, newValue in
            guard !selected.isEmpty else { return }
            session.persistFileDraft(selected, text: newValue, baseline: savedBaseline)
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            if !selected.isEmpty {
                session.persistFileDraft(selected, text: draft, baseline: savedBaseline)
            }
        }
    }

    // MARK: Sidebar

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(LoomColors.amber)
                Text("Task files")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(files.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(files) { file in
                        Button {
                            select(file)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: file.name.hasSuffix(".md")
                                      ? "doc.text" : "doc")
                                    .font(.system(size: 12))
                                    .foregroundColor(
                                        file.name == selected
                                            ? LoomColors.accent : .secondary
                                    )
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.displayName)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(
                                            file.name == selected
                                                ? LoomColors.accent : .primary
                                        )
                                        .lineLimit(1)
                                    if file.isDirectoryHint {
                                        Text(file.name)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                file.name == selected
                                    ? LoomColors.accentSoft : Color.clear,
                                in: Rectangle()
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(LoomColors.bgBase)
    }

    // MARK: Editor

    private func modePicker(compact: Bool) -> some View {
        Picker("View", selection: $viewModeRaw) {
            ForEach(ViewMode.allCases) { mode in
                if compact {
                    Image(systemName: mode.symbol).tag(mode.rawValue)
                } else {
                    Text(mode.label).tag(mode.rawValue)
                }
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Edit source, browser preview, or both")
    }

    private var sourceEditor: some View {
        PlainTextEditor(
            text: $draft,
            documentID: selected,
            contentRevision: editorRevision,
            editable: canEdit,
            fontSize: 13.5
        )
    }

    private var renderedPreview: some View {
        MarkdownPreview(markdown: draft, documentID: selected)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Ahead of the controls in the queue for space: squeezed by
                // them, the name of the file you are editing collapsed to "…".
                Text(current?.name ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if dirty {
                    Text("Edited")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(LoomColors.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(LoomColors.amber.opacity(0.14), in: Rectangle())
                }
                if !canEdit {
                    Text("Read-only")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Words when they fit, icons when they do not: at the window's
                // minimum width this pane is barely 300pt, and the labelled
                // picker pushed Save off the edge.
                ViewThatFits(in: .horizontal) {
                    modePicker(compact: false)
                    modePicker(compact: true)
                }

                Button {
                    Task { await load(keepSelection: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload from server")
                .disabled(loading || dirty)

                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canEdit || !dirty || saving)
                .keyboardShortcut("s", modifiers: .command)
                .help(canEdit ? "Save (⌘S)" : "Only PLAN.md / WIKI.md can be saved")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch viewMode {
            case .edit:
                sourceEditor
            case .preview:
                renderedPreview
            case .split:
                // Two readable columns need width this pane does not always
                // have. Narrow, they used to shoulder each other off the
                // right edge, leaving the preview outside the window, so
                // below that width they stack. Measured rather than left to
                // `ViewThatFits`, which an `HSplitView` will always tell it
                // fits.
                GeometryReader { geo in
                    if geo.size.width >= 560 {
                        HSplitView {
                            sourceEditor.frame(minWidth: 240)
                            renderedPreview.frame(minWidth: 280)
                        }
                    } else {
                        VStack(spacing: 0) {
                            sourceEditor
                            Divider()
                            renderedPreview
                        }
                    }
                }
            }
        }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.7))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func select(_ file: PlanFile) {
        guard file.name != selected else { return }
        // Stash the current buffer before switching — drafts survive per file.
        if !selected.isEmpty {
            session.persistFileDraft(selected, text: draft, baseline: savedBaseline)
        }
        applyBuffer(for: file)
        status = dirty ? "Restored unsaved edits" : ""
    }

    private func applyBuffer(for file: PlanFile) {
        selected = file.name
        savedBaseline = file.content
        if let local = session.loadFileDraft(file.name), local != file.content {
            draft = local
        } else {
            draft = file.content
        }
        editorRevision += 1
    }

    private func load(keepSelection: Bool = false) async {
        if !keepSelection { loading = true }
        do {
            let detail = try await session.api.taskDetail(
                projectId: session.projectId,
                slug: session.slug
            )
            var collected: [PlanFile] = []
            let templates = detail.templates ?? [:]
            // Prefer the scanned name list so empty files still appear; fall
            // back to whatever arrived in `templates`.
            let names: [String] = {
                if let listed = detail.task_markdown_files, !listed.isEmpty {
                    return listed
                }
                return Array(templates.keys).sorted()
            }()
            var seen = Set<String>()
            for name in names {
                guard seen.insert(name).inserted else { continue }
                collected.append(PlanFile(name: name, content: templates[name] ?? ""))
            }
            for (name, content) in templates where seen.insert(name).inserted {
                collected.append(PlanFile(name: name, content: content))
            }
            collected.sort { left, right in
                if left.name == "PLAN.md" { return true }
                if right.name == "PLAN.md" { return false }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
            files = collected
            let pick: String = {
                if keepSelection,
                   collected.contains(where: { $0.name == selected }) {
                    return selected
                }
                if collected.contains(where: { $0.name == "PLAN.md" }) {
                    return "PLAN.md"
                }
                return collected.first?.name ?? ""
            }()
            // Keep typing in progress when a background reload lands.
            if keepSelection, dirty, pick == selected {
                if let idx = collected.firstIndex(where: { $0.name == selected }) {
                    savedBaseline = collected[idx].content
                }
            } else if let file = collected.first(where: { $0.name == pick }) {
                applyBuffer(for: file)
            } else {
                selected = ""
                draft = ""
                savedBaseline = ""
                editorRevision += 1
            }
            error = ""
            if dirty {
                status = status.isEmpty ? "Unsaved edits kept" : status
            } else {
                status = ""
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func scheduleAutosave() {
        guard canEdit, dirty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await save(silent: true)
        }
    }

    private func save(silent: Bool = false) async {
        guard canEdit, let name = current?.name else { return }
        let payload = draft
        guard payload != savedBaseline else { return }
        if !silent { saving = true }
        if !silent { status = "" }
        do {
            try await session.api.writeTemplate(
                projectId: session.projectId,
                slug: session.slug,
                name: (name as NSString).lastPathComponent,
                content: payload
            )
            savedBaseline = payload
            session.clearFileDraft(name)
            if let idx = files.firstIndex(where: { $0.name == name }) {
                files[idx] = PlanFile(name: name, content: payload)
            }
            status = silent ? "Auto-saved" : "Saved"
        } catch {
            status = error.localizedDescription
        }
        if !silent { saving = false }
    }
}

// MARK: - Plain source editor

/// Editable `NSTextView` for markdown source. Avoids SwiftUI `Text` /
/// `AttributedString(markdown:)` which stalls the main thread on big plans.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var documentID: String
    /// Parent bumps this when the binding was replaced externally (load / switch).
    var contentRevision: Int
    var editable: Bool
    var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(LoomColors.bgElev1)

        let textView = NSTextView()
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(LoomColors.bgElev1)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor(LoomColors.accent)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.documentID = documentID
        context.coordinator.contentRevision = contentRevision
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        textView.isEditable = editable
        textView.isSelectable = true
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != font { textView.font = font }

        // Only replace the buffer on an explicit document/content change.
        // Never push the SwiftUI binding back while the user is typing — that
        // is what made characters appear to vanish.
        let documentChanged = context.coordinator.documentID != documentID
        let revisionChanged = context.coordinator.contentRevision != contentRevision
        if documentChanged || revisionChanged {
            context.coordinator.documentID = documentID
            context.coordinator.contentRevision = contentRevision
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                if documentChanged {
                    textView.scrollToBeginningOfDocument(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var documentID = ""
        var contentRevision = -1

        init(text: Binding<String>) { self.text = text }

        func textDidEndEditing(_ notification: Notification) {
            if let textView {
                text.wrappedValue = textView.string
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
        }
    }
}
