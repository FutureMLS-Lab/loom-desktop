import SwiftUI

/// The task's markdown — `PLAN.md` by default, plus any other top-level
/// markdown the server scanned. Read-only, like the web console's viewer: the
/// agent writes the plan, you drive the agent.
struct PlanView: View {
    @ObservedObject var session: ChatSession

    @State private var files: [PlanFile] = []
    @State private var selected: String = ""
    @State private var loading = true
    @State private var error = ""

    struct PlanFile: Identifiable, Equatable {
        let name: String
        let content: String
        var id: String { name }
    }

    private var current: PlanFile? {
        files.first { $0.name == selected } ?? files.first
    }

    var body: some View {
        Group {
            if loading && files.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading plan…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                emptyState(
                    symbol: "exclamationmark.triangle",
                    title: "Plan unavailable",
                    detail: error
                )
            } else if files.isEmpty {
                emptyState(
                    symbol: "doc.text",
                    title: "No plan yet",
                    detail: "Run the deep interview and the agent will write PLAN.md."
                )
            } else {
                VStack(spacing: 0) {
                    if files.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(files) { file in
                                Button {
                                    selected = file.name
                                } label: {
                                    Text(file.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            file.name == current?.name
                                                ? LoomColors.accentSoft : Color.clear,
                                            in: Rectangle()
                                        )
                                        .foregroundColor(
                                            file.name == current?.name
                                                ? LoomColors.accent : .secondary
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider()
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(MarkdownBlock.parse(current?.content ?? "")) { block in
                                block.view
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(26)
                    }
                }
            }
        }
        .background(LoomColors.bgElev1)
        .task(id: session.id) { await load() }
        .onChange(of: session.planRevision) { _, _ in Task { await load() } }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.7))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        do {
            let detail = try await session.api.taskDetail(
                projectId: session.projectId,
                slug: session.slug
            )
            // `templates` carries the contents; `task_markdown_files` is only
            // a list of names, so the viewer shows what actually arrived.
            var collected: [PlanFile] = []
            for (name, content) in (detail.templates ?? [:])
            where !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(PlanFile(name: name, content: content))
            }
            collected.sort { left, right in
                if left.name == "PLAN.md" { return true }
                if right.name == "PLAN.md" { return false }
                return left.name < right.name
            }
            files = collected
            if selected.isEmpty || !collected.contains(where: { $0.name == selected }) {
                selected = collected.first?.name ?? ""
            }
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// A plan rendered block by block.
///
/// `AttributedString(markdown:)` in `.full` mode flattens a document into one
/// run — headings, list items and paragraphs all arrive as a single wall of
/// text, which is what a plan is least useful as. Splitting into blocks first
/// keeps the shape the agent wrote, and inline markdown still gets parsed
/// within each block.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case bullet(indent: Int)
        case code
        case rule
        case paragraph
    }

    let id: Int
    let kind: Kind
    let text: String

    @ViewBuilder
    var view: some View {
        switch kind {
        case .heading(let level):
            Text(inline(text))
                .font(.system(size: level <= 1 ? 21 : (level == 2 ? 17 : 15), weight: .semibold))
                .padding(.top, level <= 2 ? 8 : 4)
        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 14))
                    .foregroundColor(LoomColors.accent)
                Text(inline(text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .code:
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(2)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LoomColors.bgElev2, in: Rectangle())
                .overlay(Rectangle().strokeBorder(LoomColors.border, lineWidth: 1))
        case .rule:
            Rectangle()
                .fill(LoomColors.border)
                .frame(height: 1)
                .padding(.vertical, 4)
        case .paragraph:
            Text(inline(text))
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(raw)
    }

    static func parse(_ document: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false
        var next = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            guard !joined.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            blocks.append(MarkdownBlock(id: next, kind: .paragraph, text: joined))
            next += 1
        }

        for line in document.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(
                        MarkdownBlock(id: next, kind: .code, text: code.joined(separator: "\n"))
                    )
                    next += 1
                    code.removeAll()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let body = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(id: next, kind: .heading(level: level), text: body))
                next += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(id: next, kind: .rule, text: ""))
                next += 1
                continue
            }
            if let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+",
               trimmed.dropFirst().hasPrefix(" ") {
                flushParagraph()
                let leading = line.prefix { $0 == " " || $0 == "\t" }.count
                blocks.append(
                    MarkdownBlock(
                        id: next,
                        kind: .bullet(indent: min(3, leading / 2)),
                        text: String(trimmed.dropFirst(2))
                    )
                )
                next += 1
                continue
            }
            paragraph.append(line)
        }

        if inCode, !code.isEmpty {
            blocks.append(MarkdownBlock(id: next, kind: .code, text: code.joined(separator: "\n")))
            next += 1
        }
        flushParagraph()
        return blocks
    }
}
