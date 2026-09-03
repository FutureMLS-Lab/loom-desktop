import SwiftUI

/// Create a task without leaving the app — the one thing that still sent you
/// back to the browser. The server slugifies the title and lays out
/// `.RUD/<slug>/`; the worktree appears when the agent first starts.
struct NewTaskView: View {
    @ObservedObject var store: TaskStore
    let onCreated: (String, String) -> Void
    let onDismiss: () -> Void

    @State private var projectId = ""
    @State private var title = ""
    @State private var goal = ""
    @State private var agent = "cursor"
    @State private var busy = false
    @State private var error = ""
    @FocusState private var titleFocused: Bool

    private static let agents = ["cursor", "claude", "codex"]

    private var canCreate: Bool {
        !projectId.isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New task")
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 16) {
                field("Project") {
                    Picker("", selection: $projectId) {
                        ForEach(store.projects) { project in
                            Text(project.label).tag(project.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                field("Title") {
                    TextField("what this task is", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                        .focused($titleFocused)
                }

                field("Goal") {
                    // The deep interview starts from this, so it is worth a
                    // sentence rather than a phrase.
                    TextEditor(text: $goal)
                        .font(.system(size: 14))
                        .frame(height: 96)
                        .padding(4)
                        .overlay(LoomShape.field.strokeBorder(LoomColors.border, lineWidth: 1))
                }

                field("Agent") {
                    Picker("", selection: $agent) {
                        ForEach(Self.agents, id: \.self) { name in
                            Text(name.capitalized).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(LoomColors.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LoomColors.accent)
                    .disabled(!canCreate)
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(width: 520, height: 460)
        .background(LoomColors.bgElev1)
        .onAppear {
            // Default to whatever project you were already looking at.
            if projectId.isEmpty {
                projectId = store.selection
                    .flatMap { ProjectPickerView.split($0)?.0 }
                    ?? store.projects.first?.id
                    ?? ""
            }
            titleFocused = true
        }
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func create() {
        guard canCreate else { return }
        busy = true
        error = ""
        Task {
            do {
                let meta = try await store.api.createTask(
                    projectId: projectId,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                    agent: agent
                )
                store.refreshNow()
                onCreated(projectId, meta.slug)
                onDismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
