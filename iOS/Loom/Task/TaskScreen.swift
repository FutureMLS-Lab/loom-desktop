import SwiftUI

enum TaskTab: String, CaseIterable, Identifiable {
    case chat, terminal, plan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .terminal: return "Terminal"
        case .plan: return "Plan"
        }
    }
}

/// One task: its conversation, its live pane and its plan, behind one switch.
struct TaskScreen: View {
    let ref: TaskRef
    let project: LoomProject
    let meta: LoomTaskMeta
    @EnvironmentObject private var sessions: SessionCache

    var body: some View {
        TaskContent(
            session: sessions.session(
                projectId: ref.projectId,
                slug: ref.slug,
                title: meta.title ?? meta.slug,
                projectLabel: project.label
            ),
            ref: ref
        )
    }
}

private struct TaskContent: View {
    @ObservedObject var session: ChatSession
    let ref: TaskRef
    @EnvironmentObject private var workspace: WorkspaceStore
    /// Owned here rather than by the Terminal tab, so leaving the tab and
    /// coming back finds the same screen instead of a blank one.
    @StateObject private var terminal = TerminalController()
    @AppStorage("taskTab") private var tabRaw = TaskTab.chat.rawValue

    private var tab: TaskTab { TaskTab(rawValue: tabRaw) ?? .chat }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tabRaw) {
                ForEach(TaskTab.allCases) { item in
                    Text(item.label).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            Group {
                switch tab {
                case .chat:
                    ChatScreen(session: session)
                case .terminal:
                    TerminalScreen(session: session, terminal: terminal)
                case .plan:
                    PlanScreen(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LoomColors.bgBase)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) { agentMenu }
        }
        .onAppear {
            session.loadSessions()
            workspace.markSeen(ref)
        }
        .onChange(of: workspace.state(ref)) { _, state in
            // A finish that happens while you are watching is already seen.
            if state == .finished { workspace.markSeen(ref) }
        }
        .alert(
            session.actionFailure?.action ?? "",
            isPresented: Binding(
                get: { session.actionFailure != nil },
                set: { if !$0 { session.dismissActionFailure() } }
            ),
            presenting: session.actionFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.reason)
        }
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(session.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                statusDot
                Text(statusText)
                Text("·")
                Text(session.projectLabel)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if session.working {
            ProgressView().controlSize(.mini)
        } else {
            Circle()
                .fill(session.online ? LoomColors.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
        }
    }

    private var statusText: String {
        if session.working { return "Working" }
        return session.online ? "Ready" : "Offline"
    }

    private var agentMenu: some View {
        Menu {
            if session.online {
                Button(role: .destructive) {
                    session.stopAgent()
                } label: {
                    Label("Stop Agent", systemImage: "stop.fill")
                }
            } else {
                Button {
                    session.startAgent()
                } label: {
                    Label("Start Agent", systemImage: "play.fill")
                }
            }
            Button {
                session.interrupt()
            } label: {
                Label("Interrupt (Esc)", systemImage: "escape")
            }
            .disabled(session.paneTarget.isEmpty)

            Section("Flow") {
                ForEach(ChatSession.FlowStep.allCases) { step in
                    Button {
                        session.run(step)
                    } label: {
                        Label(step.label, systemImage: step.symbol)
                    }
                    .disabled(session.paneTarget.isEmpty || session.sending)
                }
            }

            if !session.sessions.isEmpty {
                Section("Resume Session") {
                    ForEach(session.sessions.prefix(8)) { past in
                        Button(Self.sessionLabel(past)) { session.resume(past) }
                    }
                }
            }
        } label: {
            if session.starting {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private static func sessionLabel(_ session: SessionInfo) -> String {
        let shortID = String(session.id.prefix(8))
        guard let date = session.lastUsed else { return shortID }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(shortID)"
    }
}
