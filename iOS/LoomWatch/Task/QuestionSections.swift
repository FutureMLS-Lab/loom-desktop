import SwiftUI

/// A question the agent is waiting on, one row per option: on a watch a
/// whole row is the only target big enough to hit.
struct QuestionSections: View {
    let question: ConversationQuestion
    @ObservedObject var session: TaskSession
    @State private var selected: [String: [String]] = [:]
    @State private var custom = ""

    private var prompts: [ConversationPrompt] { question.questions ?? [] }

    private var selectedOther: Bool {
        prompts.contains { prompt in
            let active = Set(selected[prompt.id] ?? [])
            return prompt.options.contains { TaskSession.isOther($0) && active.contains($0.value) }
        }
    }

    private var complete: Bool {
        prompts.allSatisfy { !(selected[$0.id] ?? []).isEmpty }
            && (!selectedOther || !custom.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var busy: Bool { session.answering || session.sending }

    var body: some View {
        ForEach(prompts) { prompt in
            Section {
                Text(prompt.prompt)
                    .font(.footnote)
                    .listRowBackground(Color.clear)
                ForEach(prompt.options) { option in
                    let active = (selected[prompt.id] ?? []).contains(option.value)
                    Button {
                        toggle(prompt: prompt, option: option)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(active ? LoomColors.amber : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label)
                                    .font(.footnote.weight(active ? .semibold : .regular))
                                if let description = option.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    .disabled(busy)
                }
            } header: {
                Label(prompt.header.flatMap { $0.isEmpty ? nil : $0 } ?? question.title ?? "Asks you",
                      systemImage: "questionmark.circle.fill")
                    .foregroundStyle(LoomColors.amber)
                    .textCase(nil)
            } footer: {
                if prompt.allow_multiple == true {
                    Text("Select all that apply")
                }
            }
        }

        Section {
            if selectedOther {
                TextField("Your answer", text: $custom)
            }
            Button {
                session.answer(question, selected: selected, custom: custom)
            } label: {
                HStack {
                    Label("Send Answer", systemImage: "arrow.up.circle.fill")
                    Spacer(minLength: 0)
                    if busy { ProgressView().frame(width: 18) }
                }
            }
            .tint(LoomColors.amber)
            .disabled(!complete || busy)
        }
        .onAppear {
            for prompt in prompts where selected[prompt.id] == nil {
                selected[prompt.id] = prompt.options.filter { $0.selected == true }.map(\.value)
            }
        }
    }

    private func toggle(prompt: ConversationPrompt, option: ConversationOption) {
        let other = TaskSession.isOther(option)
        if !other { custom = "" }
        var active = selected[prompt.id] ?? []
        let otherValues = prompt.options.filter { TaskSession.isOther($0) }.map(\.value)
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
/// wants a choice, so each is a reply — one tap sends the number.
struct QuickReplySection: View {
    let question: ConversationQuestion
    @ObservedObject var session: TaskSession

    var body: some View {
        if let prompt = question.questions?.first, !prompt.options.isEmpty {
            Section("Reply with") {
                ForEach(prompt.options) { option in
                    Button {
                        session.send(option.value)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(option.value)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(LoomColors.accent, in: Circle())
                            Text(WatchText.attributed(option.label, limit: 120))
                                .font(.footnote)
                                .lineLimit(3)
                        }
                    }
                    .disabled(session.sending)
                }
            }
        }
    }
}
