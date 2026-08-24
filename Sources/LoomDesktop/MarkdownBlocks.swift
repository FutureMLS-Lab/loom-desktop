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
    case bullets([Bullet])
    case code(String, language: String)
    case table(header: [String], rows: [[String]], alignments: [Alignment])
    case quote(String)
    case rule

    enum Alignment: Equatable { case leading, trailing, center }

    struct Bullet: Equatable {
        let depth: Int
        let text: String

        /// "1. " and friends carry their own marker; drawing a dot in front
        /// of the number dressed every ordered list in two bullets.
        var isNumbered: Bool {
            let digits = text.prefix(while: \.isNumber)
            return !digits.isEmpty && text.dropFirst(digits.count).hasPrefix(". ")
        }
    }
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
        var bullets: [MarkdownBlock.Bullet] = []

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

            // A separator line — agents punctuate with these constantly, and
            // it was coming out as a literal "---" paragraph. Only after a
            // break though: butted against a paragraph, "---" is a setext
            // underline for the line above, not a rule.
            if paragraph.isEmpty, isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushAll()
                var quoted: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoted.append(
                        String(quoteLine.dropFirst(quoteLine.hasPrefix("> ") ? 2 : 1))
                    )
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let bullet = bulletBody(trimmed) {
                flushParagraph()
                bullets.append(
                    MarkdownBlock.Bullet(depth: bulletDepth(line), text: bullet)
                )
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

    /// How deep the item sits, from the indentation the trim threw away.
    /// Two columns per level is the common step; four-space nesting just
    /// lands a level deeper, which still reads as "inside".
    private static func bulletDepth(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
        }
        return min(columns / 2, 4)
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

    /// Three or more of the same rule character and nothing else.
    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
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
                                if !item.isNumbered {
                                    if item.depth == 0 {
                                        Circle()
                                            .fill(Color.secondary.opacity(0.45))
                                            .frame(width: 4, height: 4)
                                            .padding(.top, 6)
                                    } else {
                                        // Hollow at depth, the way lists mark
                                        // their inner levels.
                                        Circle()
                                            .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                                            .frame(width: 4.5, height: 4.5)
                                            .padding(.top, 6)
                                    }
                                }
                                Text(InlineMarkdown.text(item.text))
                                    .font(.system(size: fontSize))
                                    .lineSpacing(leading)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, CGFloat(item.depth) * 15)
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

                case .quote(let body):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(LoomColors.border)
                            .frame(width: 3)
                        Text(InlineMarkdown.text(body))
                            .font(.system(size: fontSize - 0.5))
                            .foregroundColor(.secondary)
                            .lineSpacing(leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .rule:
                    Rectangle()
                        .fill(LoomColors.border)
                        .frame(height: 1)
                        .padding(.vertical, 3)
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
