import SwiftUI

/// The conversation, the same rows the desktop and the web console draw,
/// with a composer that types into the agent's pane.
struct ChatScreen: View {
    @ObservedObject var session: ChatSession
    @State private var expandedRuns: Set<String> = []
    @State private var atBottom = true
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var selecting: SelectableItem?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            feed
            composer
        }
        .sheet(item: $selecting) { SelectableTextSheet(item: $0) }
        .onChange(of: session.chatDraft) { _, _ in session.persistChatDraft() }
    }

    // MARK: Feed

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if session.hasMore {
                    Button {
                        session.loadOlder()
                    } label: {
                        Label(
                            "Load earlier · \(max(0, session.total - session.messages.count)) more",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.footnote.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }

                if session.messages.isEmpty {
                    emptyState
                } else {
                    ForEach(ChatFeedItem.group(session.messages)) { item in
                        switch item {
                        case .message(let message):
                            MessageRow(message: message, session: session) { selecting = $0 }
                        case .run(let tools):
                            ToolRunRow(
                                tools: tools,
                                expanded: expandedRuns.contains(item.id)
                            ) {
                                if expandedRuns.contains(item.id) {
                                    expandedRuns.remove(item.id)
                                } else {
                                    expandedRuns.insert(item.id)
                                }
                            }
                        }
                    }
                }

                if let pending = session.pendingSend {
                    UserBubble(text: pending, delivery: session.sending ? "Sending…" : "Queued") {
                        selecting = $0
                    }
                }

                footerState
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 120
        } action: { _, isAtBottom in
            atBottom = isAtBottom
        }
        .onChange(of: session.messages.count) { _, _ in
            if atBottom {
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: session.pendingSend) { _, pending in
            if pending != nil { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom && !session.messages.isEmpty {
                Button {
                    withAnimation { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(LoomColors.accent, in: Circle())
                        .shadow(radius: 3, y: 1)
                }
                .padding(14)
                .accessibilityLabel("Jump to latest")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if session.loading {
                ProgressView("Loading conversation…")
            } else if !session.error.isEmpty {
                ContentUnavailableView(
                    "Conversation unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(session.error)
                )
            } else if !session.available {
                ContentUnavailableView(
                    "No structured transcript",
                    systemImage: "terminal",
                    description: Text("This session has terminal output only.")
                )
            } else {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(session.online ? "The agent is ready for a follow-up." : "Start the agent to begin.")
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    @ViewBuilder
    private var footerState: some View {
        if session.working {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Agent is working…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else if session.online && !session.messages.isEmpty {
            Label("Agent ready", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Composer

    private var draftIsEmpty: Bool {
        session.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                session.interrupt()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(session.working ? Color.orange : Color.secondary)
            }
            .disabled(session.paneTarget.isEmpty)
            .accessibilityLabel("Interrupt the agent")
            .padding(.bottom, 4)

            TextField("Message the agent…", text: $session.chatDraft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(LoomColors.bgElev1, in: LoomShape.field)
                .overlay(
                    LoomShape.field.strokeBorder(
                        composerFocused ? LoomColors.accent.opacity(0.55) : LoomColors.borderStrong,
                        lineWidth: 1
                    )
                )

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(draftIsEmpty ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(LoomColors.accent))
            }
            .disabled(draftIsEmpty || session.sending)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = session.chatDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.chatDraft = ""
        session.persistChatDraft()
        session.send(text)
    }
}

// MARK: - Feed grouping

/// Runs of finished tool calls fold into one line; anything running or
/// failed stays a card of its own, since those are the ones worth seeing.
enum ChatFeedItem: Identifiable {
    case message(ConversationMessage)
    case run([ConversationMessage])

    private static let foldFrom = 3

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .run(let tools): return "run-\(tools.first?.id ?? "")"
        }
    }

    static func group(_ messages: [ConversationMessage]) -> [ChatFeedItem] {
        var items: [ChatFeedItem] = []
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
