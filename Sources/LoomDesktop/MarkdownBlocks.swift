import SwiftUI

/// Agent turns, laid out as the blocks they actually are.
///
/// `AttributedString(markdown:)` only understands inline syntax, so a turn
/// came out as one run of text with its structure still written in
/// punctuation: tables as rows of pipes, lists as hyphens, code fences as
/// three backticks. These agents answer with comparison tables and code more
/// often than not, and the terminal renders both properly — so the same
/// content read as neatly aligned columns in one tab and as noise in the
/// other, which is no way to check one against the other.
///
/// A `WKWebView` per message would render all of it and cost far too much for
/// a feed hundreds of messages long, so the blocks are parsed once, cached,
/// and drawn with native views.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String, level: Int)
    case bullets([String])
    case code(String, language: String)
    case table(header: [String], rows: [[String]], alignments: [Alignment])

    enum Alignment: Equatable { case leading, trailing, center }
}

enum MarkdownBlockParser {
    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []
    private static let capacity = 300

    static func blocks(_ raw: String) -> [MarkdownBlock] {
        if let hit = cache[raw] { return hit }
        let parsed = parse(raw)
        cache[raw] = parsed
        order.append(raw)
        if order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }

    private static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !text.isEmpty { blocks.append(.paragraph(text)) }
        }
        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets.removeAll()
            }
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
        }

        let lines = raw.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(body.joined(separator: "\n"), language: language))
                continue
            }

            // A table needs its delimiter row (|---|:--:|) to be a table and
            // not a sentence that happens to contain a pipe.
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isDelimiterRow(lines[index + 1]) {
                flushAll()
                let header = cells(trimmed)
                let alignments = self.alignments(lines[index + 1], count: header.count)
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }

            if let bullet = bulletBody(trimmed) {
                flushParagraph()
                bullets.append(bullet)
                index += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                    flushAll()
                    blocks.append(
                        .heading(
                            String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces),
                            level: hashes
                        )
                    )
                    index += 1
                    continue
                }
            }

            if trimmed.isEmpty {
                flushAll()
            } else {
                flushBullets()
                paragraph.append(line)
            }
            index += 1
        }
        flushAll()
        return blocks
    }

    private static func bulletBody(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        // "1. " and friends, kept with their number so the order survives.
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return trimmed
        }
        return nil
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let body = part.trimmingCharacters(in: .whitespaces)
            return !body.isEmpty && body.allSatisfy { $0 == "-" || $0 == ":" } && body.contains("-")
        }
    }

    private static func cells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func alignments(_ line: String, count: Int) -> [MarkdownBlock.Alignment] {
        let specs = cells(line.trimmingCharacters(in: .whitespaces))
        return (0..<count).map { index in
            guard index < specs.count else { return .leading }
            let spec = specs[index]
            if spec.hasPrefix(":"), spec.hasSuffix(":") { return .center }
            if spec.hasSuffix(":") { return .trailing }
            return .leading
        }
    }
}

/// Inline markdown (bold, code spans, links) for a single block of text.
enum InlineMarkdown {
    private static var cache: [String: AttributedString] = [:]
    private static var order: [String] = []
    private static let capacity = 600

    static func text(_ raw: String) -> AttributedString {
        if let hit = cache[raw] { return hit }
        let parsed = (try? AttributedString(
            markdown: raw,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(raw)
        cache[raw] = parsed
        order.append(raw)
        if order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }
}

struct MarkdownBody: View {
    let text: String
    var fontSize: CGFloat = 14

    /// Leading for running text. At 14pt the 2 this used to be worked out
    /// around 1.35× — fine for a caption, close for a paragraph, and closer
    /// still in Chinese, which has no ascenders or descenders to open a line
    /// up. Agent turns here run to whole screens of prose.
    private var leading: CGFloat { (fontSize * 0.42).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownBlockParser.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let body):
                    Text(InlineMarkdown.text(body))
                        .font(.system(size: fontSize))
                        .lineSpacing(leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .heading(let body, let level):
                    Text(InlineMarkdown.text(body))
                        .font(.system(size: fontSize + (level <= 2 ? 3 : 1), weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(InlineMarkdown.text(item))
                                    .font(.system(size: fontSize))
                                    .lineSpacing(leading)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                case .code(let body, let language):
                    CodeBlock(source: body, language: language, fontSize: fontSize - 1.5)

                case .table(let header, let rows, let alignments):
                    MarkdownTable(
                        header: header,
                        rows: rows,
                        alignments: alignments,
                        fontSize: fontSize - 1
                    )
                }
            }
        }
    }
}

private struct CodeBlock: View {
    let source: String
    let language: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoomColors.bgElev2, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(LoomColors.border, lineWidth: 1)
        )
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [MarkdownBlock.Alignment]
    let fontSize: CGFloat

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(header[safe: column] ?? "", column: column, weight: .semibold)
                    }
                }
                .background(LoomColors.bgElev2)
                Rectangle().fill(LoomColors.border).frame(height: 1)
                    .gridCellColumns(columns)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(row[safe: column] ?? "", column: column, weight: .regular)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : LoomColors.bgElev2.opacity(0.5))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(LoomColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cell(_ body: String, column: Int, weight: Font.Weight) -> some View {
        // Monospaced digits so a column of numbers lines up on the decimal
        // point, which is the entire reason these tables exist.
        Text(InlineMarkdown.text(body))
            .font(.system(size: fontSize, weight: weight, design: .default))
            .monospacedDigit()
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(
                maxWidth: .infinity,
                alignment: swiftUIAlignment(alignments[safe: column] ?? .leading)
            )
    }

    private func swiftUIAlignment(_ alignment: MarkdownBlock.Alignment) -> SwiftUI.Alignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
