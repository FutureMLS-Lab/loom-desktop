import AppKit
import SwiftUI

/// The project scratchpad: `<project>/.RUD/NOTES.md`, the same file the web
/// console edits, so a note written here shows up there and vice versa.
///
/// Notes belong to a project rather than a task, which is why this is its own
/// window instead of another tab — a note about the repo should not be filed
/// under whichever task happened to be open when it was written.
struct NotesView: View {
    @ObservedObject var store: TaskStore

    @AppStorage("notesProject") private var projectId = ""
    @AppStorage("notesPreview") private var showPreview = false

    @State private var text = ""
    @State private var savedBaseline = ""
    @State private var loading = false
    @State private var status = ""
    @State private var editorRevision = 0
    @State private var autosave: Task<Void, Never>?
    /// One writer at a time — see `save`.
    @State private var writing = false

    private var dirty: Bool { text != savedBaseline }

    private var currentProject: LoomProject? {
        store.projects.first { $0.id == projectId } ?? store.projects.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(LoomColors.bgElev1)
        .task { await load() }
        .onChange(of: projectId) { _, _ in Task { await load() } }
        .onChange(of: text) { _, _ in scheduleAutosave() }
        .onDisappear {
            autosave?.cancel()
            if dirty { Task { await save(silent: true) } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .foregroundColor(LoomColors.accent)

            if store.projects.count > 1 {
                Picker("", selection: Binding(
                    get: { currentProject?.id ?? "" },
                    set: { projectId = $0 }
                )) {
                    ForEach(store.projects) { project in
                        Text(project.label).tag(project.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            } else {
                Text(currentProject?.label ?? "Notes")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("NOTES.md")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            if loading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Spacer()

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundColor(dirty ? LoomColors.amber : .secondary)
                    .lineLimit(1)
            }

            Picker("", selection: $showPreview) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Button("Save") { Task { await save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(LoomColors.bgElev2)
    }

    @ViewBuilder
    private var content: some View {
        if store.projects.isEmpty {
            Text("No projects yet.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showPreview {
            MarkdownPreview(
                markdown: text,
                documentID: "notes/\(currentProject?.id ?? "")",
                assetProject: currentProject?.id ?? ""
            )
        } else {
            PlainTextEditor(
                text: $text,
                documentID: "notes/\(currentProject?.id ?? "")",
                contentRevision: editorRevision,
                editable: true,
                fontSize: 13.5,
                placeholder: loading
                    ? "Loading…"
                    : "Notes for \(currentProject?.label ?? "this project") — saved to NOTES.md, shared with the web console."
            )
        }
    }

    private func load() async {
        guard let project = currentProject else { return }
        if projectId != project.id { projectId = project.id }
        loading = true
        do {
            let content = try await store.api.notes(projectId: project.id)
            text = content
            savedBaseline = content
            editorRevision += 1
            status = ""
        } catch {
            status = error.localizedDescription
        }
        loading = false
    }

    /// Notes are a scratchpad; asking someone to press Save to keep a thought
    /// is how thoughts get lost.
    private func scheduleAutosave() {
        guard dirty else { return }
        status = "Unsaved…"
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await save(silent: true)
        }
    }

    /// Writes what is on screen, one write at a time.
    ///
    /// ⌘S while the autosave is still in the air used to start a second PUT of
    /// the same file. Whichever reached the server last won, which is not
    /// necessarily the newer text — so a note could end up as an older draft
    /// while the window said it had been saved. A second caller now returns
    /// and lets the running write pick its text up: the loop re-reads `dirty`
    /// after each round trip, so anything typed during one is written by the
    /// next.
    private func save(silent: Bool = false) async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        while let project = currentProject, dirty {
            let payload = text
            do {
                try await store.api.saveNotes(projectId: project.id, content: payload)
                savedBaseline = payload
                status = silent ? "Saved" : "Saved just now"
            } catch {
                status = error.localizedDescription
                return
            }
        }
    }
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let shared = NotesWindowController()

    private var window: NSWindow?

    func show(store: TaskStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loom Notes"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: NotesView(store: store))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
