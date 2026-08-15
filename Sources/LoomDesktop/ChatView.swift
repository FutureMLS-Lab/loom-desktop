import SwiftUI

/// The chat module: the same conversation the Loom web console and the iOS
/// app render — user / assistant / tool / question / event rows — with a
/// composer that types straight into the task's agent pane.
struct ChatView: View {
    @ObservedObject var session: ChatSession
    @State private var stickToLatest = true
    @State private var composerHeight = ComposerField.minHeight
    @State private var composerRevision = 0
    @State private var expandedRuns: Set<String> = []

    private static let bottomAnchor = "chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            feed
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(LoomColors.bgBase)
        .onChange(of: session.chatDraft) { _, _ in
            session.persistChatDraft()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(session.projectLabel) · \(session.slug)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusChip
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusChip: some View {
        if session.working {
            HStack(spacing: 6) {
                LoomSpinnerDot(size: 13)
                Text("Working")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(LoomColors.accent)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(LoomColors.accent.opacity(0.10), in: Rectangle())
        } else if session.online {
            HStack(spacing: 6) {
                Circle().fill(LoomColors.green).frame(width: 7, height: 7)
                Text("Ready")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(LoomColors.green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(LoomColors.green.opacity(0.10), in: Rectangle())
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                Text("Offline")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Button(session.starting ? "Starting…" : "Start agent") {
                    session.startAgent()
                }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
                .disabled(session.starting)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: Rectangle())
        }
    }

    // MARK: Feed

    private var feed: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.hasMore {
                            Button {
                                session.loadOlder()
                            } label: {
                                Label(
                                    "Load earlier · \(max(0, session.total - session.messages.count)) remaining",
                                    systemImage: "clock.arrow.circlepath"
                                )
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(LoomColors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                        }

                        if session.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(FeedItem.group(session.messages)) { item in
                                switch item {
                                case .message(let message):
                                    MessageRow(
                                        message: message,
                                        session: session,
                                        openSubagent: { session.subagentDrill = $0 }
                                    )
                                    .id(message.id)
                                case .run(let tools):
                                    ToolRunRow(
                                        tools: tools,
                                        expanded: expandedRuns.contains(item.id),
                                        toggle: {
                                            if expandedRuns.contains(item.id) {
                                                expandedRuns.remove(item.id)
                                            } else {
                                                expandedRuns.insert(item.id)
                                            }
                                        },
                                        openSubagent: { session.subagentDrill = $0 }
                                    )
                                    .id(item.id)
                                }
                            }
                        }

                        if let pending = session.pendingSend {
                            UserBubble(text: pending, delivery: session.sending ? "Sending…" : "Queued")
                        }

                        footerState

                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(12)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollBottomPreference.self,
                                value: geo.frame(in: .named("chat-scroll")).maxY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "chat-scroll")
                .onPreferenceChange(ScrollBottomPreference.self) { contentMaxY in
                    // How far the content's bottom edge sits below the
                    // viewport. Small → we're at the latest message.
                    stickToLatest = contentMaxY - viewportHeight < 120
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { viewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in viewportHeight = h }
                    }
                )
                .onChange(of: session.messages.count) { _, _ in
                    if stickToLatest {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: session.pendingSend) { _, pending in
                    if pending != nil {
                        stickToLatest = true
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }

                if !stickToLatest && !session.messages.isEmpty {
                    Button {
                        stickToLatest = true
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(LoomColors.accent, in: Rectangle())
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .shadow(radius: 3)
                }
            }
        }
    }

    @State private var viewportHeight: CGFloat = 0

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if session.loading {
                ProgressView()
                Text("Loading conversation…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else if !session.error.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                Text("Conversation unavailable")
                    .font(.system(size: 14, weight: .semibold))
                Text(session.error)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if !session.available {
                Image(systemName: "text.and.command.macwindow")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No structured transcript")
                    .font(.system(size: 14, weight: .semibold))
                Text("This session has terminal output only.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No messages yet")
                    .font(.system(size: 14, weight: .semibold))
                Text(session.online
                     ? "The agent is ready for a follow-up."
                     : "Start the agent to begin.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private var footerState: some View {
        if session.working {
            HStack(spacing: 7) {
                LoomSpinnerDot(size: 13)
                Text("Agent is working…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        } else if session.online && !session.messages.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(LoomColors.green)
                Text("Agent ready")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // The same field as the terminal's, for the same reasons: a plain
            // TextField cannot tell Shift+Enter from Enter — so the old hint
            // here promised a newline it could not insert — and it cannot see
            // that an input method is mid-composition, so accepting Chinese
            // candidates with Enter would send the half-written message.
            ComposerField(
                text: $session.chatDraft,
                measuredHeight: $composerHeight,
                contentRevision: composerRevision,
                placeholder: "Message the agent… ⏎ send, ⇧⏎ newline",
                onSubmit: sendDraft
            )
            .frame(height: composerHeight)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(LoomColors.bgElev1, in: Rectangle())
            .overlay(
                Rectangle()
                    .strokeBorder(LoomColors.borderStrong, lineWidth: 1)
            )

            Button {
                session.interrupt()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(session.working ? .orange : .secondary)
            .disabled(session.paneTarget.isEmpty)
            .help("Send Esc to the agent pane (interrupt)")
            .padding(.bottom, 5)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(
                        session.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(LoomColors.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                session.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || session.sending
            )
            .padding(.bottom, 2)
        }
        .padding(10)
    }

    private func sendDraft() {
        let text = session.chatDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.chatDraft = ""
        composerRevision += 1
        session.persistChatDraft()
        session.send(text)
    }
}

private struct ScrollBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Feed grouping

/// A run of tool calls that all finished is scaffolding, not conversation.
/// Left as individual cards they crowd out what the agent actually said — a
/// dozen identical "Done" boxes between two paragraphs. Runs are folded into
/// one line you can open; anything still running, or that failed, stays a
/// card of its own, because those are the ones worth seeing.
private enum FeedItem: Identifiable {
    case message(ConversationMessage)
    case run([ConversationMessage])

    /// Below this many in a row, folding hides more than it helps.
    private static let foldFrom = 3

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .run(let tools): return "run-\(tools.first?.id ?? "")"
        }
    }

    static func group(_ messages: [ConversationMessage]) -> [FeedItem] {
        var items: [FeedItem] = []
        var run: [ConversationMessage] = []

        func flush() {
            if run.count >= foldFrom {
                items.append(.run(run))
            } else {
                items.append(contentsOf: run.map { .message($0) })
            }
            run.removeAll()
        }

        for message in messages {
            if message.kind == "tool", message.tool?.status == "completed" {
                run.append(message)
            } else {
                flush()
                items.append(.message(message))
            }
        }
        flush()
        return items
    }
}

private struct ToolRunRow: View {
    let tools: [ConversationMessage]
    let expanded: Bool
    let toggle: () -> Void
    var openSubagent: ((ConversationSubagent) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                    Text("\(tools.count) steps")
                        .font(.system(size: 12, weight: .medium))
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.035), in: Rectangle())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(tools) { message in
                    if let tool = message.tool {
                        ToolCard(tool: tool, openSubagent: openSubagent)
                    }
                }
            }
        }
    }

    /// "Shell ×4, ApplyPatch, TodoWrite" — in the order they ran.
    private var summary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in tools.compactMap({ $0.tool?.name }) {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order
            .map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Rows

private struct MessageRow: View {
    let message: ConversationMessage
    @ObservedObject var session: ChatSession
    var openSubagent: ((ConversationSubagent) -> Void)? = nil

    var body: some View {
        switch message.kind {
        case "user":
            UserBubble(text: message.text ?? "", delivery: nil)
        case "tool":
            if let tool = message.tool {
                ToolCard(tool: tool, openSubagent: openSubagent)
            }
        case "question":
            if let question = message.question {
                QuestionCard(question: question, session: session)
            }
        case "event":
            Text(message.text ?? "")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        default: // assistant
            AssistantRow(text: message.text ?? "")
        }
    }
}

struct UserBubble: View {
    let text: String
    let delivery: String?

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(2)
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(LoomColors.accent, in: Rectangle())
                    .fixedSize(horizontal: false, vertical: true)
                if let delivery {
                    Text(delivery)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AssistantRow: View {
    let text: String

    var body: some View {
        // An accent rule down the left edge instead of a floating avatar:
        // agent turns are long and multi-paragraph, and a rule marks the
        // whole turn rather than just its first line.
        HStack(alignment: .top, spacing: 10) {
            LoomSpinningRingStatic()
                .frame(width: 4)
            MarkdownBody(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 40)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The assistant avatar: a small filled Loom square. Static — a transcript
/// full of looping animations is both noisy and expensive.
private struct LoomSpinningRingStatic: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [LoomColors.accent, LoomColors.green],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolCard: View {
    let tool: ConversationTool
    var openSubagent: ((ConversationSubagent) -> Void)? = nil
    @State private var expanded = false

    private var hasDetails: Bool {
        !(tool.input ?? "").isEmpty || !(tool.output ?? "").isEmpty
    }

    private var status: (symbol: String, color: Color, label: String) {
        switch tool.status {
        case "running": return ("ellipsis.circle", .orange, "Running")
        case "error": return ("exclamationmark.circle", .red, "Error")
        case "canceled": return ("minus.circle", .secondary, "Stopped")
        default: return ("checkmark.circle", LoomColors.green, "Done")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasDetails { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13))
                        .foregroundColor(LoomColors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(tool.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: status.symbol)
                                .font(.system(size: 11))
                                .foregroundColor(status.color)
                            Text(status.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(status.color)
                        }
                        if let summary = tool.summary, !summary.isEmpty, summary != tool.name {
                            Text(summary)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if hasDetails {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(9)

            if let subagent = tool.subagent, let openSubagent {
                Button {
                    openSubagent(subagent)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                        Text(
                            subagent.status == "working"
                                ? "View \(subagentLabel(subagent)) trajectory · working"
                                : "View \(subagentLabel(subagent)) trajectory"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(LoomColors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LoomColors.accentSoft, in: Rectangle())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.bottom, 9)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    if let input = tool.input, !input.isEmpty {
                        ToolDetail(label: "Input", content: input)
                    }
                    if let output = tool.output, !output.isEmpty {
                        ToolDetail(label: "Result", content: output)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 9)
            }
        }
        .background(LoomColors.bgElev1, in: Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(LoomColors.border, lineWidth: 1)
        )
        .padding(.trailing, 30)
    }

    private func subagentLabel(_ subagent: ConversationSubagent) -> String {
        let type = (subagent.agent_type ?? "").trimmingCharacters(in: .whitespaces)
        return type.isEmpty ? "subagent" : type
    }
}

/// The transcript of one spawned subagent, rendered with the same rows as
/// the main chat — markdown turns, tool cards with arguments and results,
/// and the inputs the main agent sent it. Opened as a sheet from the Task
/// step that launched the subagent, or as the full detail pane from the
/// sidebar's subagent list (`onBack` set). Read-only: questions inside a
/// sidechain were the subagent's to answer, so they render as plain rows
/// rather than live question cards.
struct SubagentTrajectoryView: View {
    @ObservedObject var session: ChatSession
    let subagent: ConversationSubagent
    /// Sidebar-pane mode: a back-to-main-agent button instead of Done.
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ConversationMessage] = []
    @State private var loading = true
    @State private var error = ""
    @State private var expandedRuns: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            feed
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 420, idealHeight: 640)
        .background(LoomColors.bgBase)
        .task(id: subagent.session_id) { await poll() }
    }

    /// The live sidebar entry for this subagent, when the parent session's
    /// poll still lists it — carries fresher status and queued sends than
    /// the snapshot the view was opened with.
    private var liveInfo: SessionSubagent? {
        session.subagents.first { $0.id == subagent.session_id }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Main agent", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(LoomColors.accent)
                .keyboardShortcut(.cancelAction)
            }
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(LoomColors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subagent.session_id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusChip
            if onBack == nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusChip: some View {
        let status = liveInfo?.status ?? subagent.status ?? ""
        switch status {
        case "working":
            HStack(spacing: 6) {
                LoomSpinnerDot(size: 12)
                Text("Working")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(LoomColors.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(LoomColors.accent.opacity(0.10), in: Rectangle())
        case "error":
            Text("Error")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(LoomColors.red)
        case "completed":
            Label("Done", systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(LoomColors.green)
        case "canceled", "idle":
            Text(status == "canceled" ? "Stopped" : "Idle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    private var title: String {
        let type = (subagent.agent_type ?? "").trimmingCharacters(in: .whitespaces)
        let name = (subagent.title ?? "").trimmingCharacters(in: .whitespaces)
        switch (type.isEmpty, name.isEmpty) {
        case (false, false): return "\(type) · \(name)"
        case (false, true): return "\(type) subagent"
        case (true, false): return name
        case (true, true): return "Subagent"
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if loading && messages.isEmpty {
                    Text("Loading trajectory…")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else if !error.isEmpty && messages.isEmpty {
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundColor(LoomColors.red)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else if messages.isEmpty {
                    Text("No transcript yet for this subagent.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    ForEach(FeedItem.group(messages)) { item in
                        switch item {
                        case .message(let message):
                            row(message)
                        case .run(let tools):
                            ToolRunRow(
                                tools: tools,
                                expanded: expandedRuns.contains(item.id),
                                toggle: {
                                    if expandedRuns.contains(item.id) {
                                        expandedRuns.remove(item.id)
                                    } else {
                                        expandedRuns.insert(item.id)
                                    }
                                }
                            )
                        }
                    }
                }
                if let queued = liveInfo?.queued_messages, !queued.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Queued from the main agent — not yet seen by the subagent",
                            systemImage: "envelope.badge"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LoomColors.amber)
                        ForEach(Array(queued.enumerated()), id: \.offset) { _, item in
                            Text(item.text)
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(LoomColors.amber.opacity(0.10), in: Rectangle())
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(
                                            LoomColors.amber.opacity(0.45),
                                            lineWidth: 1
                                        )
                                )
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func row(_ message: ConversationMessage) -> some View {
        switch message.kind {
        case "user":
            UserBubble(text: message.text ?? "", delivery: nil)
        case "tool":
            if let tool = message.tool {
                ToolCard(tool: tool)
            }
        case "question":
            Text(message.question?.title ?? "Question")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case "event":
            Text(message.text ?? "")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        default:
            AssistantRow(text: message.text ?? "")
        }
    }

    /// Same cadence as the web console's subagent modal: re-read every 2.5s
    /// while open, so a still-running subagent's steps stream in. `.task`
    /// cancels this when the sheet closes.
    private func poll() async {
        while !Task.isCancelled {
            do {
                let feed = try await session.api.conversation(
                    projectId: session.projectId,
                    slug: session.slug,
                    limit: 500,
                    session: subagent.session_id
                )
                messages = feed.messages ?? []
                error = ""
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
    }
}

private struct ToolDetail: View {
    let label: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoomColors.bgElev1, in: Rectangle())
    }
}

private struct QuestionCard: View {
    let question: ConversationQuestion
    @ObservedObject var session: ChatSession

    @State private var selected: [String: [String]] = [:]
    @State private var custom = ""

    private var pending: Bool { question.status == "pending" }
    private var prompts: [ConversationPrompt] { question.questions ?? [] }

    private func isOther(_ option: ConversationOption) -> Bool {
        option.label.trimmingCharacters(in: .whitespaces)
            .lowercased().hasPrefix("other")
    }

    private var selectedOther: Bool {
        prompts.contains { prompt in
            let active = Set(selected[prompt.id] ?? [])
            return prompt.options.contains { isOther($0) && active.contains($0.value) }
        }
    }

    private var complete: Bool {
        prompts.allSatisfy { !(selected[$0.id] ?? []).isEmpty }
            && (!selectedOther || !custom.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(LoomColors.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.title ?? "Input needed")
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusLabel)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
            }

            ForEach(prompts) { prompt in
                VStack(alignment: .leading, spacing: 5) {
                    if let header = prompt.header, !header.isEmpty {
                        Text(header)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    Text(prompt.prompt)
                        .font(.system(size: 13))
                    if prompt.allow_multiple == true {
                        Text("Select all that apply")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    ForEach(prompt.options) { option in
                        OptionRow(
                            option: option,
                            active: (selected[prompt.id] ?? []).contains(option.value),
                            enabled: pending && !session.answering
                        ) {
                            toggle(prompt: prompt, option: option)
                        }
                    }
                }
            }

            if pending && selectedOther {
                TextField("Type a custom answer…", text: $custom, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
            }

            if pending {
                HStack(spacing: 8) {
                    Button {
                        session.answer(question: question, selected: selected, custom: custom)
                    } label: {
                        if session.answering {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Send answer", systemImage: "arrow.forward")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                    }
                    .disabled(!complete || session.answering)
                    if !session.answerFeedback.isEmpty {
                        Text(session.answerFeedback)
                            .font(.system(size: 11.5))
                            .foregroundColor(.orange)
                    }
                }
            } else if let answer = question.answer, !answer.isEmpty {
                Text(answer)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoomColors.accent.opacity(0.05), in: Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(LoomColors.accent.opacity(0.25), lineWidth: 1)
        )
        .padding(.trailing, 30)
        .onAppear {
            for prompt in prompts {
                selected[prompt.id] = prompt.options
                    .filter { $0.selected == true }
                    .map(\.value)
            }
        }
    }

    private var statusLabel: String {
        switch question.status {
        case "pending": return "Waiting for your answer"
        case "answered": return "Answered"
        case "error": return "Could not submit"
        default: return "No longer active"
        }
    }

    private func toggle(prompt: ConversationPrompt, option: ConversationOption) {
        let allowMultiple = prompt.allow_multiple == true
        let other = isOther(option)
        if !other { custom = "" }
        var active = selected[prompt.id] ?? []
        let otherValues = prompt.options.filter { isOther($0) }.map(\.value)
        if allowMultiple {
            if other {
                active = active.contains(option.value) ? [] : [option.value]
            } else if active.contains(option.value) {
                active.removeAll { $0 == option.value }
            } else {
                active.removeAll { otherValues.contains($0) }
                active.append(option.value)
            }
        } else {
            active = [option.value]
        }
        selected[prompt.id] = active
    }
}

private struct OptionRow: View {
    let option: ConversationOption
    let active: Bool
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: active ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(active ? LoomColors.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.vertical, 2)
    }
}
