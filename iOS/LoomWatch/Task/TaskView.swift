import SwiftUI

/// One task from the wrist: what it is doing, what the agent last said, and
/// what you can do about it without reaching for the phone.
struct TaskView: View {
    let ref: TaskRef
    @EnvironmentObject private var store: WatchStore
    @StateObject private var session: TaskSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var confirmStop = false
    @State private var showAll = false

    /// Long turns are clipped to a screenful or two until asked for more.
    private static let clip = 600
    private static let fullClip = 6000
    private static let presets = ["Continue", "Yes", "No"]

    init(ref: TaskRef, paneTarget: String) {
        self.ref = ref
        _session = StateObject(wrappedValue: TaskSession(ref: ref, paneTarget: paneTarget))
    }

    var body: some View {
        let item = store.item(for: ref)
        let question = session.pendingQuestion

        List {
            Section {
                header(item, waiting: question != nil)
                    .listRowBackground(Color.clear)
            }

            if let question {
                if question.source == "numbered" {
                    QuickReplySection(question: question, session: session)
                } else {
                    QuestionSections(question: question, session: session)
                        .id(question.id ?? "question")
                }
            }

            latestSection

            if !session.recentSteps.isEmpty {
                Section("Steps") {
                    ForEach(session.recentSteps) { message in
                        if let tool = message.tool { StepRow(tool: tool) }
                    }
                }
            }

            replySection
            if session.loaded {
                agentSection
            }
        }
        // The project, not the task: the title is in full just below, and
        // the bar has room for a word or two.
        .navigationTitle(item.flatMap { $0.projectLabel.isEmpty ? nil : $0.projectLabel } ?? "Task")
        .containerBackground(
            LoomColors.tint(displayState(item), waiting: question != nil).gradient,
            for: .navigation
        )
        .onAppear {
            let store = self.store
            let ref = self.ref
            session.onFeed = { [weak store] feed in store?.updatePreview(ref, from: feed) }
            session.start()
            store.markSeen(ref)
        }
        .onDisappear { session.stop() }
        .onChange(of: store.state(ref)) { _, state in
            // A finish that happens while you are looking is already seen.
            if state == .finished { store.markSeen(ref) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.stop() } else { session.start() }
        }
        .alert(
            session.failure?.action ?? "",
            isPresented: Binding(
                get: { session.failure != nil },
                set: { if !$0 { session.failure = nil } }
            ),
            presenting: session.failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.reason)
        }
        .confirmationDialog("Stop the agent?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Agent", role: .destructive) { session.stopAgent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its pane closes. The session stays resumable from the iPhone or the Mac.")
        }
    }

    // MARK: Sections

    /// The feed is read every few seconds here and the fleet's snapshot less
    /// often, so once the feed has come back it decides whether this works.
    private func displayState(_ item: TaskItem?) -> TaskActivity? {
        if session.loaded {
            if session.working { return .working }
            if item?.state == .working { return .idle }
        }
        return item?.state
    }

    private func header(_ item: TaskItem?, waiting: Bool) -> some View {
        let state = displayState(item)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusOrb(state: state, waiting: waiting, size: 20)
                Text(stateText(state, waiting: waiting, finishedAt: item?.finishedAt))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LoomColors.tint(state, waiting: waiting))
                    .lineLimit(1)
            }
            Text(item?.title ?? ref.slug)
                .font(.system(.headline, design: .rounded))
                .lineLimit(4)
            if let agent = item?.meta.agent, !agent.isEmpty {
                AgentBadge(agent: agent)
            }
        }
    }

    /// One line beside the orb, so short enough for the 41 mm screen.
    private func stateText(_ state: TaskActivity?, waiting: Bool, finishedAt: Date?) -> String {
        if waiting { return "Needs your answer" }
        switch state {
        case .working: return "Working"
        case .finished:
            return finishedAt.map { "Done \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" }
                ?? "Done"
        case .idle: return "Ready"
        case nil: return session.online ? "Ready" : "Agent stopped"
        }
    }

    @ViewBuilder
    private var latestSection: some View {
        Section("Latest") {
            if let running = session.runningTool {
                Label {
                    Text(running.summary.flatMap { $0.isEmpty ? nil : $0 } ?? running.name)
                        .lineLimit(3)
                } icon: {
                    Image(systemName: "gearshape.2")
                        .symbolEffect(.pulse, options: .repeating)
                }
                .font(.footnote)
                .foregroundStyle(LoomColors.accent)
            }

            if let words = session.latestWords {
                VStack(alignment: .leading, spacing: 6) {
                    if let asked = session.lastAsked {
                        Text("You: \(WatchText.clipped(asked, to: 90))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(WatchText.attributed(words, limit: showAll ? Self.fullClip : Self.clip))
                        .font(.footnote)
                }
                if WatchText.plain(words).count > Self.clip {
                    Button(showAll ? "Show Less" : "Show More") {
                        withAnimation { showAll.toggle() }
                    }
                    .font(.footnote)
                    .foregroundStyle(LoomColors.accent)
                }
            } else if !session.loaded {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if !session.error.isEmpty {
                Label(session.error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !session.available {
                Text("This session has terminal output only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(session.online ? "Nothing from the agent yet." : "Start the agent to begin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var replySection: some View {
        Section("Reply") {
            TextField("Message the agent", text: $draft)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .disabled(session.sending)
            if let pending = session.pendingSend {
                Label(pending, systemImage: session.sending ? "arrow.up.circle" : "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        session.send(preset)
                    } label: {
                        Text(preset)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 6)
                            // A fixed height: "Continue" is drawn smaller to fit,
                            // and its capsule should not shrink with it.
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(LoomColors.accent.opacity(0.25), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.sending)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }

    private var agentSection: some View {
        Section("Agent") {
            if session.working {
                // Colour on the label: a list row's button does not take a tint.
                Button {
                    session.interrupt()
                } label: {
                    Label("Interrupt (Esc)", systemImage: "escape")
                        .foregroundStyle(.orange)
                }
                .disabled(session.paneTarget.isEmpty)
            }
            if session.online {
                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    Label("Stop Agent", systemImage: "stop.fill")
                }
                .disabled(session.controlling)
            } else {
                Button {
                    session.startAgent()
                } label: {
                    HStack {
                        Label("Start Agent", systemImage: "play.fill")
                            .foregroundStyle(LoomColors.green)
                        Spacer(minLength: 0)
                        if session.controlling { ProgressView().frame(width: 18) }
                    }
                }
                .disabled(session.controlling)
            }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        session.send(text)
    }
}

private struct StepRow: View {
    let tool: ConversationTool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let summary = tool.summary, !summary.isEmpty, summary != tool.name {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var symbol: String {
        switch tool.status {
        case "running": return "ellipsis.circle"
        case "error": return "exclamationmark.circle"
        case "canceled": return "minus.circle"
        default: return "checkmark.circle"
        }
    }

    private var tint: Color {
        switch tool.status {
        case "running": return .orange
        case "error": return LoomColors.red
        case "canceled": return .secondary
        default: return LoomColors.green
        }
    }
}
