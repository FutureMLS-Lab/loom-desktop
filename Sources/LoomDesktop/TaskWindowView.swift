import SwiftUI

/// A task, shown inline in the main window: header, tab bar, and the selected
/// tab's content. Same three sections as the loom-app — Chat (structured
/// conversation), Terminal (live pane via the gateway's terminal page), and
/// Changes (diffs across the task's worktrees).
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
            case .plan: return "Plan"
            case .changes: return "Changes"
            }
        }

        var symbol: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right"
            case .terminal: return "apple.terminal"
            case .plan: return "doc.text"
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(session.projectLabel)
                        Text("·")
                        Text(session.slug)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                statusChip
                agentMenu
            }

            HStack(spacing: 3) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        Label(item.label, systemImage: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                tab == item ? LoomColors.accentSoft : Color.clear,
                                in: Rectangle()
                            )
                            .overlay(
                                Rectangle().strokeBorder(
                                    tab == item ? LoomColors.accent.opacity(0.30) : .clear,
                                    lineWidth: 1
                                )
                            )
                            .foregroundColor(tab == item ? LoomColors.accent : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                }

                Spacer()

                // The web console's flow toolbar: interview → /goal → write
                // result. Disabled until there is a pane to paste into.
                ForEach(ChatSession.FlowStep.allCases) { step in
                    Button {
                        session.run(step)
                    } label: {
                        Label(step.label, systemImage: step.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.05), in: Rectangle())
                            .overlay(Rectangle().strokeBorder(LoomColors.border, lineWidth: 1))
                            .foregroundColor(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(step.help)
                    .disabled(session.paneTarget.isEmpty || session.sending)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(LoomColors.bgBase)
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
        .onAppear { session.loadSessions() }
    }

    private static func sessionLabel(_ session: SessionInfo) -> String {
        let shortID = String(session.id.prefix(8))
        guard let date = session.lastUsed else { return shortID }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "\(formatter.string(from: date))  ·  \(shortID)"
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Rectangle())
    }

    // MARK: Terminal

    @ViewBuilder
    private var terminalContent: some View {
        if session.paneTarget.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 26))
                    .foregroundColor(.secondary.opacity(0.7))
                Text("No terminal yet")
                    .font(.system(size: 16, weight: .semibold))
                Text(session.online
                     ? "Waiting for the pane target…"
                     : "Start the agent to open its terminal.")
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
                if !session.online {
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
