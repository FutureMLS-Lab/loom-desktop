import SwiftUI

/// A task, shown inline in the main window: header, tab bar, and the selected
/// tab's content. Chat (the structured conversation), Terminal (the live
/// pane), Files (the task's markdown, editable), and Changes (diffs across
/// the task's worktrees).
struct TaskPane: View {
    @ObservedObject var session: ChatSession
    /// Remembered across tasks and launches: whoever lives in the terminal
    /// should not have to re-pick it for every task they open.
    @AppStorage("taskTab") private var tabRaw = Tab.conversation.rawValue

    private var tab: Tab {
        get { Tab(rawValue: tabRaw) ?? .conversation }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case conversation, terminal, plan, changes

        var id: String { rawValue }

        var label: String {
            switch self {
            case .conversation: return "Chat"
            case .terminal: return "Terminal"
            case .plan: return "Files"
            case .changes: return "Changes"
            }
        }

        var symbol: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right"
            case .terminal: return "apple.terminal"
            case .plan: return "folder"
            case .changes: return "arrow.triangle.branch"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .conversation: return "1"
            case .terminal: return "2"
            case .plan: return "3"
            case .changes: return "4"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch tab {
                case .conversation:
                    ChatView(session: session)
                case .terminal:
                    terminalContent
                case .plan:
                    PlanView(session: session)
                case .changes:
                    ChangesView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LoomColors.bgBase)
        .onAppear { session.start() }
    }

    // MARK: Header

    // Chrome earns its height. The header and the terminal's own toolbar
    // together took 160pt of an 860pt window before a line of output was
    // visible; the title does not need to be poster-sized to be the title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Centred, not baseline-aligned: the right side of this row is
            // boxes (chips, a menu glyph), and aligning boxes by the baseline
            // of whatever happens to be inside them scattered each one to its
            // own height. The title and its subtitle still share a baseline,
            // in a group of their own — that rule is for running text.
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Text(session.projectLabel)
                        // The slug earns its spot only when it says something the
                        // title does not — half the fleet is named after its slug,
                        // and the header was reading "video2bit · video2bit".
                        if session.title.caseInsensitiveCompare(session.slug) != .orderedSame {
                            Text("·")
                            Text(session.slug)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Spacer(minLength: 8)
                agentChip
                statusChip
                agentMenu
            }

            // Narrow the window and this row used to break its own words —
            // "Cha/t", "Term/inal". The tabs are where you live, so they keep
            // their labels; the flow steps, which you reach for occasionally,
            // give theirs up first and fall back to their tooltips.
            ViewThatFits(in: .horizontal) {
                tabRow(compactActions: false)
                tabRow(compactActions: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .background(LoomColors.bgBase)
    }

    private func tabRow(compactActions: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases) { item in
                TabButton(item: item, selected: tab == item) { tab = item }
            }

            Spacer(minLength: 12)

            // The web console's flow toolbar: interview → /goal → write
            // result. Disabled until there is a pane to paste into.
            // Quieter than the tabs on purpose: these are things you do
            // occasionally, the tabs are where you live.
            ForEach(ChatSession.FlowStep.allCases) { step in
                FlowButton(step: step, compact: compactActions) { session.run(step) }
                    .disabled(session.paneTarget.isEmpty || session.sending)
            }
        }
    }

    /// One tab. Its own view so hovering can answer — a row of flat
    /// rectangles that ignores the pointer reads as labels, not buttons.
    private struct TabButton: View {
        let item: Tab
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Label(item.label, systemImage: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selected
                            ? LoomColors.accentSoft
                            : (hovering ? Color.primary.opacity(0.05) : Color.clear),
                        in: LoomShape.control
                    )
                    .overlay(
                        LoomShape.control.strokeBorder(
                            selected ? LoomColors.accent.opacity(0.30) : .clear,
                            lineWidth: 1
                        )
                    )
                    .foregroundColor(
                        selected ? LoomColors.accent : (hovering ? .primary : .secondary)
                    )
                    .contentShape(LoomShape.control)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(item.shortcut, modifiers: .command)
            .onHover { hovering = $0 }
        }
    }

    /// One flow step, with the same hover answer as the tabs. Disabled state
    /// comes through the environment, and a button that cannot be pressed
    /// does not light up.
    private struct FlowButton: View {
        let step: ChatSession.FlowStep
        let compact: Bool
        let action: () -> Void
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: action) {
                Group {
                    if compact {
                        Image(systemName: step.symbol)
                    } else {
                        Label(step.label, systemImage: step.symbol)
                    }
                }
                .font(.system(size: 11.5))
                .fixedSize()
                .frame(minWidth: compact ? 16 : nil)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isEnabled && hovering ? Color.primary.opacity(0.04) : Color.clear,
                    in: LoomShape.control
                )
                .overlay(LoomShape.control.strokeBorder(LoomColors.border, lineWidth: 1))
                .foregroundColor(isEnabled && hovering ? .primary : .secondary)
                .contentShape(LoomShape.control)
            }
            .buttonStyle(.plain)
            .help(step.help)
            .onHover { hovering = $0 }
        }
    }

    /// Start/stop the pane, and reopen a past session. Resuming works even
    /// when the original tmux was killed, which is the whole point of it on a
    /// remote box.
    private var agentMenu: some View {
        Menu {
            if session.online {
                Button("Stop agent") { session.stopAgent() }
            } else {
                Button("Start agent") { session.startAgent() }
            }
            Divider()
            Toggle("Notify when finished", isOn: Binding(
                get: { session.monitorOn },
                set: { session.setMonitor($0) }
            ))
            .disabled(session.monitorBusy)
            .help("Loom watches the pane for a finishing phrase and tells you, "
                  + "whether or not this task is open")
            Divider()
            if session.sessions.isEmpty {
                Text("No past sessions")
            } else {
                Section("Resume session") {
                    ForEach(session.sessions.prefix(10)) { past in
                        Button(Self.sessionLabel(past)) { session.resume(past) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.starting)
        .onAppear {
            session.loadSessions()
            session.loadMonitor()
        }
    }

    private static func sessionLabel(_ session: SessionInfo) -> String {
        let shortID = String(session.id.prefix(8))
        guard let date = session.lastUsed else { return shortID }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "\(formatter.string(from: date))  ·  \(shortID)"
    }

    /// Which CLI is in the pane. The dock and sidebar carry this on their
    /// icons, but the open task itself never said — and "start the agent"
    /// reads differently when you can see which agent that is.
    @ViewBuilder
    private var agentChip: some View {
        if !session.agent.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: TaskPill.agentSymbol(session.agent))
                    .font(.system(size: 10.5, weight: .medium))
                Text(session.agent.capitalized)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .help("The CLI running this task's pane")
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if session.working {
            chip(color: LoomColors.accent) {
                LoomSpinnerDot(size: 12)
                Text("Working")
            }
        } else if session.online {
            chip(color: LoomColors.green) {
                Circle().fill(LoomColors.green).frame(width: 7, height: 7)
                Text("Ready")
            }
        } else {
            HStack(spacing: 8) {
                chip(color: .secondary) {
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                    Text("Offline")
                }
                Button(session.starting ? "Starting…" : "Start agent") {
                    session.startAgent()
                }
                .disabled(session.starting)
                .controlSize(.small)
            }
        }
    }

    private func chip<Content: View>(
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }

    // MARK: Terminal

    private var terminalEmptyTitle: String {
        if session.detailLoading { return "Opening the task…" }
        return session.detailError.isEmpty ? "No terminal yet" : "Can't reach this task"
    }

    private var detailMessage: String {
        if session.detailLoading {
            return "Reading where its agent is running."
        }
        if !session.detailError.isEmpty {
            return "\(session.detailError)\n\nThe pane may well be running — this is the "
                + "task's own details that could not be read. Retrying."
        }
        return session.online
            ? "Waiting for the pane target…"
            : "Start the agent to open its terminal."
    }

    @ViewBuilder
    private var terminalContent: some View {
        if session.paneTarget.isEmpty {
            VStack(spacing: 10) {
                if session.detailLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: session.detailError.isEmpty
                          ? "apple.terminal" : "exclamationmark.triangle")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Text(terminalEmptyTitle)
                    .font(.system(size: 16, weight: .semibold))
                // A pane can be alive and this still be empty, when the task's
                // details are too big to fetch. Saying "waiting" then is a
                // promise the app cannot keep.
                Text(detailMessage)
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                // Offered only once there is an answer. Until the read lands
                // the app does not know whether an agent is already running,
                // so inviting you to start one is a guess.
                if !session.online && session.detailError.isEmpty && !session.detailLoading {
                    Button("Start agent") { session.startAgent() }
                        .buttonStyle(.borderedProminent)
                        .tint(LoomColors.accent)
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TerminalPane(session: session)
        }
    }
}
