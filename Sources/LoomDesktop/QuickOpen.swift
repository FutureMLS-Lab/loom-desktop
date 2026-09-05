import SwiftUI

/// ⌘P over a fleet of forty tasks: type a few letters, hit Return. Scrolling
/// a sidebar to find "OSCAR-INT3-Rubin-Simulate" is the slowest thing about
/// the web console, and a palette is the one place a desktop app can simply
/// be quicker.
struct QuickOpenView: View {
    @ObservedObject var store: TaskStore
    let onOpen: (String, String) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private struct Match: Identifiable {
        let project: LoomProject
        let meta: LoomTaskMeta
        let state: TaskPill.State?
        let score: Int
        var id: String { "\(project.id)/\(meta.slug)" }
    }

    private var matches: [Match] {
        var found: [Match] = []
        // Re-scored on every keystroke, so the state lookup is a dictionary
        // built once rather than a scan of the pills per task.
        let stateByTask = Dictionary(
            store.pills.map { ($0.id, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        for project in store.projects {
            for meta in store.tasksByProject[project.id] ?? [] {
                let title = meta.title ?? meta.slug
                let state = stateByTask["\(project.id)/\(meta.slug)"]
                guard let score = Self.score(
                    query: query,
                    title: title,
                    slug: meta.slug,
                    project: project.label
                ) else { continue }
                found.append(
                    Match(project: project, meta: meta, state: state, score: score)
                )
            }
        }
        // Best match first; among equals, tasks wanting attention float up.
        return found.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return Self.rank(left.state) < Self.rank(right.state)
        }
        .prefix(40)
        .map { $0 }
    }

    private static func rank(_ state: TaskPill.State?) -> Int {
        switch state {
        case .finished: return 0
        case .working: return 1
        case .idle: return 2
        case nil: return 3
        }
    }

    /// Subsequence match, the way editors do it: "oscint" finds
    /// "OSCAR-INT3-…". A prefix hit and a whole-word hit both score higher
    /// than letters merely scattered through the name.
    private static func score(
        query: String,
        title: String,
        slug: String,
        project: String
    ) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return 0 }
        let haystacks = [(title.lowercased(), 3), (slug.lowercased(), 2), (project.lowercased(), 1)]

        var best: Int?
        for (haystack, weight) in haystacks {
            if haystack.hasPrefix(needle) {
                best = max(best ?? 0, 100 * weight)
            } else if haystack.contains(needle) {
                best = max(best ?? 0, 60 * weight)
            } else if isSubsequence(needle, of: haystack) {
                best = max(best ?? 0, 20 * weight)
            }
        }
        return best
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        for character in haystack where index < needle.endIndex && character == needle[index] {
            index = needle.index(after: index)
        }
        return index == needle.endIndex
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                TextField("Search tasks or projects…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onSubmit { openHighlighted() }
                    .onChange(of: query) { _, _ in highlighted = 0 }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            Button { open(match) } label: {
                                row(match, active: index == highlighted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(match.meta.title ?? match.meta.slug), \(match.project.label)")
                            .id(match.id)
                        }
                        if matches.isEmpty {
                            Text("No matching task")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, index in
                    guard matches.indices.contains(index) else { return }
                    proxy.scrollTo(matches[index].id)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("↑ ↓ navigate"); Text("↵ open")
                Spacer()
                Text("esc close")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(LoomColors.bgElev2)
        }
        .frame(width: 560, height: 440)
        .background(LoomColors.bgElev1)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
        .background(
            // Arrow keys move the selection without stealing them from the
            // text field, which keeps typing and navigating on one keyboard.
            KeyCaptureView(
                onUp: { highlighted = max(0, highlighted - 1) },
                onDown: { highlighted = max(0, min(matches.count - 1, highlighted + 1)) }
            )
        )
    }

    private func row(_ match: Match, active: Bool) -> some View {
        HStack(spacing: 10) {
            switch match.state {
            case .working: LoomActivityDot(size: 11)
            case .finished: LoomBlinkDot(size: 11)
            default:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: 9, height: 9)
            }
            Text(match.meta.title ?? match.meta.slug)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(match.project.label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(active ? LoomColors.accentSoft : Color.clear, in: LoomShape.control)
        .contentShape(LoomShape.control)
    }

    private func openHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        open(matches[highlighted])
    }

    private func open(_ match: Match) {
        onOpen(match.project.id, match.meta.slug)
        onDismiss()
    }
}

/// Routes ↑/↓ to the palette while the text field keeps focus.
private struct KeyCaptureView: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onUp: onUp, onDown: onDown)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onUp: onUp, onDown: onDown)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var onUp: (() -> Void)?
        private var onDown: (() -> Void)?

        func install(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 126: self?.onUp?(); return nil
                case 125: self?.onDown?(); return nil
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
