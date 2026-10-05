import SwiftUI

/// Long press on anything in the feed: copy all of it, or open it to select
/// a piece. One menu for every row, so copying works the same everywhere.
private struct CopyMenu: ViewModifier {
    let title: String
    let text: String
    let onSelect: (SelectableItem) -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                Clipboard.copy(text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                onSelect(SelectableItem(title: title, text: text))
            } label: {
                Label("Select Text", systemImage: "selection.pin.in.out")
            }
        }
    }
}

private extension View {
    func copyMenu(_ title: String, text: String, onSelect: @escaping (SelectableItem) -> Void) -> some View {
        modifier(CopyMenu(title: title, text: text, onSelect: onSelect))
    }
}

struct MessageRow: View {
    let message: ConversationMessage
    @ObservedObject var session: ChatSession
    let onSelect: (SelectableItem) -> Void

    var body: some View {
        switch message.kind {
        case "user":
            UserBubble(text: message.text ?? "", delivery: nil, onSelect: onSelect)
        case "tool":
            if let tool = message.tool {
                ToolCard(tool: tool, onSelect: onSelect)
            }
        case "question":
            if let question = message.question {
                if question.source == "numbered" {
                    QuickReplies(question: question, session: session)
                } else {
                    QuestionCard(question: question, session: session)
                }
            }
        case "event":
            Text(message.text ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .copyMenu("Event", text: message.text ?? "", onSelect: onSelect)
        default:
            AssistantRow(text: message.text ?? "", onSelect: onSelect)
        }
    }
}

struct UserBubble: View {
    let text: String
    let delivery: String?
    let onSelect: (SelectableItem) -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(LoomColors.accent, in: LoomShape.bubble)
                    .contentShape(.contextMenuPreview, LoomShape.bubble)
                    .copyMenu("Message", text: text, onSelect: onSelect)
                if let delivery {
                    Text(delivery)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AssistantRow: View {
    let text: String
    let onSelect: (SelectableItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(LinearGradient(
                    colors: [LoomColors.accent, LoomColors.green],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 3)
            MarkdownBody(text: text, fontSize: 15.5, selectable: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .copyMenu("Agent", text: text, onSelect: onSelect)
    }
}

struct ToolRunRow: View {
    let tools: [ConversationMessage]
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Image(systemName: "checkmark.circle")
                        .font(.footnote)
                    Text("\(tools.count) steps")
                        .font(.footnote.weight(.medium))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04), in: LoomShape.control)
                .contentShape(LoomShape.control)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(tools) { message in
                    if let tool = message.tool {
                        ToolCard(tool: tool) { _ in }
                    }
                }
            }
        }
    }

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

private struct ToolCard: View {
    let tool: ConversationTool
    let onSelect: (SelectableItem) -> Void
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
                if hasDetails { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.footnote)
                        .foregroundStyle(LoomColors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tool.name)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: status.symbol)
                                .font(.caption)
                                .foregroundStyle(status.color)
                            Text(status.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(status.color)
                        }
                        if let summary = tool.summary, !summary.isEmpty, summary != tool.name {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if hasDetails {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = tool.input, !input.isEmpty {
                        ToolDetail(label: "Input", content: input, onSelect: onSelect)
                    }
                    if let output = tool.output, !output.isEmpty {
                        ToolDetail(label: "Result", content: output, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(LoomColors.bgElev1, in: LoomShape.field)
        .overlay(LoomShape.field.strokeBorder(LoomColors.border, lineWidth: 1))
    }
}

private struct ToolDetail: View {
    let label: String
    let content: String
    let onSelect: (SelectableItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: 220)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoomColors.bgElev2, in: LoomShape.control)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                Clipboard.copy(content)
            } label: {
                Label("Copy \(label)", systemImage: "doc.on.doc")
            }
            Button {
                onSelect(SelectableItem(title: label, text: content, monospaced: true))
            } label: {
                Label("Select Text", systemImage: "selection.pin.in.out")
            }
        }
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
        option.label.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("other")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(LoomColors.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.title ?? "Input needed")
                        .font(.subheadline.weight(.semibold))
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(prompts) { prompt in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = prompt.header, !header.isEmpty {
                        Text(header)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(prompt.prompt)
                        .font(.subheadline)
                    if prompt.allow_multiple == true {
                        Text("Select all that apply")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    .lineLimit(1...4)
            }

            if pending {
                HStack(spacing: 10) {
                    Button {
                        submit()
                    } label: {
                        if session.answering {
                            ProgressView()
                        } else {
                            Label("Send answer", systemImage: "arrow.forward")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!complete || session.answering)
                    if !session.answerFeedback.isEmpty {
                        Text(session.answerFeedback)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else if let answer = question.answer, !answer.isEmpty {
                Text(answer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoomColors.accent.opacity(0.06), in: LoomShape.card)
        .overlay(LoomShape.card.strokeBorder(LoomColors.accent.opacity(0.25), lineWidth: 1))
        .onAppear {
            for prompt in prompts {
                selected[prompt.id] = prompt.options.filter { $0.selected == true }.map(\.value)
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

    /// A menu open in the pane is answered with its keys; any other question
    /// is answered the way a person would, by replying with the choice.
    private func submit() {
        if question.source == "terminal", question.id != nil {
            session.answer(question: question, selected: selected, custom: custom)
            return
        }
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let answers = prompts.map { prompt -> (prompt: String, values: [String]) in
            let values = (selected[prompt.id] ?? []).map { value -> String in
                let option = prompt.options.first { $0.value == value }
                if let option, isOther(option), !typed.isEmpty { return typed }
                return value
            }
            return (prompt.prompt, values)
        }
        let text = answers.count == 1
            ? answers[0].values.joined(separator: ", ")
            : answers.map { "\($0.prompt)\n\($0.values.joined(separator: ", "))" }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        session.send(text)
    }

    private func toggle(prompt: ConversationPrompt, option: ConversationOption) {
        let other = isOther(option)
        if !other { custom = "" }
        var active = selected[prompt.id] ?? []
        let otherValues = prompt.options.filter { isOther($0) }.map(\.value)
        if prompt.allow_multiple == true {
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

/// A 1/2/3 list read out of the agent's last message. Only a guess that it
/// is waiting on a choice, so it is offered as replies under the message —
/// one tap sends the number — rather than as a question card, and goes away
/// once the conversation moves on.
private struct QuickReplies: View {
    let question: ConversationQuestion
    @ObservedObject var session: ChatSession

    var body: some View {
        if question.status == "pending", let prompt = question.questions?.first, !prompt.options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reply with")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(prompt.options) { option in
                    Button {
                        session.send(option.value)
                    } label: {
                        HStack(spacing: 8) {
                            Text(option.value)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(LoomColors.accent, in: Circle())
                            Text(InlineMarkdown.text(option.label))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.circle")
                                .foregroundStyle(LoomColors.accent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(LoomColors.accent.opacity(0.07), in: LoomShape.field)
                        .contentShape(LoomShape.field)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.sending)
                }
            }
            .padding(.leading, 13)
        }
    }
}

private struct OptionRow: View {
    let option: ConversationOption
    let active: Bool
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? LoomColors.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
