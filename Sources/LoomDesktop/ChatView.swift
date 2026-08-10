import SwiftUI

/// The chat module: the same conversation the Loom web console and the iOS
/// app render — user / assistant / tool / question / event rows — with a
/// composer that types straight into the task's agent pane.
struct ChatView: View {
    @ObservedObject var session: ChatSession
    @State private var draft = ""
    @State private var stickToLatest = true

    private static let bottomAnchor = "chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            feed
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(LoomColors.bgBase)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(session.projectLabel) · \(session.slug)")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LoomColors.accent)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(LoomColors.accent.opacity(0.10), in: Rectangle())
        } else if session.online {
            HStack(spacing: 6) {
                Circle().fill(LoomColors.green).frame(width: 7, height: 7)
                Text("Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LoomColors.green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(LoomColors.green.opacity(0.10), in: Rectangle())
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                Text("Offline")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Button(session.starting ? "Starting…" : "Start agent") {
                    session.startAgent()
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
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
                                .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(LoomColors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                        }

                        if session.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(session.messages) { message in
                                MessageRow(message: message, session: session)
                                    .id(message.id)
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
                            .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if !session.error.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                Text("Conversation unavailable")
                    .font(.system(size: 13, weight: .semibold))
                Text(session.error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if !session.available {
                Image(systemName: "text.and.command.macwindow")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No structured transcript")
                    .font(.system(size: 13, weight: .semibold))
                Text("This session has terminal output only.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No messages yet")
                    .font(.system(size: 13, weight: .semibold))
                Text(session.online
                     ? "The agent is ready for a follow-up."
                     : "Start the agent to begin.")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        } else if session.online && !session.messages.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(LoomColors.green)
                Text("Agent ready")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the agent… (⏎ to send, ⌥⏎ for newline)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(LoomColors.bgElev1, in: Rectangle())
                .overlay(
                    Rectangle()
                        .strokeBorder(LoomColors.borderStrong, lineWidth: 1)
                )
                .onSubmit(sendDraft)

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
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(LoomColors.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.sending)
            .padding(.bottom, 2)
        }
        .padding(10)
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        session.send(text)
    }
}

private struct ScrollBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Rows

private struct MessageRow: View {
    let message: ConversationMessage
    @ObservedObject var session: ChatSession

    var body: some View {
        switch message.kind {
        case "user":
            UserBubble(text: message.text ?? "", delivery: nil)
        case "tool":
            if let tool = message.tool {
                ToolCard(tool: tool)
            }
        case "question":
            if let question = message.question {
                QuestionCard(question: question, session: session)
            }
        case "event":
            Text(message.text ?? "")
                .font(.system(size: 10.5, weight: .medium))
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
                    .font(.system(size: 13))
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
                        .font(.system(size: 10))
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
            Text(MarkdownCache.attributed(text))
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 40)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Parsed markdown, kept between renders. Building an `AttributedString` is
/// not cheap, and doing it inside `body` re-parsed every visible message on
/// every poll, scroll, and window resize.
private enum MarkdownCache {
    private static var storage: [String: AttributedString] = [:]
    private static var order: [String] = []
    private static let capacity = 400

    static func attributed(_ raw: String) -> AttributedString {
        if let cached = storage[raw] { return cached }
        let parsed = (try? AttributedString(
            markdown: raw,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(raw)
        storage[raw] = parsed
        order.append(raw)
        if order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
        return parsed
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
                        .font(.system(size: 12))
                        .foregroundColor(LoomColors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(tool.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: status.symbol)
                                .font(.system(size: 10))
                                .foregroundColor(status.color)
                            Text(status.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(status.color)
                        }
                        if let summary = tool.summary, !summary.isEmpty, summary != tool.name {
                            Text(summary)
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if hasDetails {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(9)

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
                    .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusLabel)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }

            ForEach(prompts) { prompt in
                VStack(alignment: .leading, spacing: 5) {
                    if let header = prompt.header, !header.isEmpty {
                        Text(header)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    Text(prompt.prompt)
                        .font(.system(size: 12))
                    if prompt.allow_multiple == true {
                        Text("Select all that apply")
                            .font(.system(size: 10))
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
                    .font(.system(size: 12))
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
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .disabled(!complete || session.answering)
                    if !session.answerFeedback.isEmpty {
                        Text(session.answerFeedback)
                            .font(.system(size: 10.5))
                            .foregroundColor(.orange)
                    }
                }
            } else if let answer = question.answer, !answer.isEmpty {
                Text(answer)
                    .font(.system(size: 11))
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
                    .font(.system(size: 13))
                    .foregroundColor(active ? LoomColors.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10.5))
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
