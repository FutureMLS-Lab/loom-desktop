import Foundation

/// Agent turns, made readable on a wrist.
///
/// The iPhone and desktop lay markdown out as blocks — tables, code, lists.
/// Two inches of screen holds none of that, so structure is flattened into
/// prose: headings turn bold, bullets become dots, table rows become their
/// cells, and fences and rules go. Inline marks stay, for `Text` to render.
enum WatchText {
    private static var cache: [String: AttributedString] = [:]
    private static var order: [String] = []
    private static let capacity = 200

    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                if !line.isEmpty { lines.append("`\(line.replacingOccurrences(of: "`", with: "'"))`") }
                continue
            }
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                continue
            }
            if line.count >= 3, line.allSatisfy({ "-*_ ".contains($0) }) { continue }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                lines.append(cells.joined(separator: " · "))
                continue
            }
            if line.hasPrefix("#") {
                while line.hasPrefix("#") { line.removeFirst() }
                let heading = line.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { lines.append("**\(heading)**") }
                continue
            }
            if line.hasPrefix(">") {
                line.removeFirst()
                lines.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                lines.append((indent >= 2 ? "  ◦ " : "• ") + line.dropFirst(2))
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `plain`, then inline markdown, held for a while: a feed re-renders on
    /// every poll and the same few messages would be parsed each time.
    static func attributed(_ markdown: String, limit: Int = .max) -> AttributedString {
        let source = clipped(plain(markdown), to: limit)
        if let hit = cache[source] { return hit }
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(source)
        cache[source] = parsed
        order.append(source)
        if order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }

    /// For a notification, which shows text without any markup.
    static func bare(_ markdown: String, limit: Int) -> String {
        String(attributed(markdown, limit: limit).characters)
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
