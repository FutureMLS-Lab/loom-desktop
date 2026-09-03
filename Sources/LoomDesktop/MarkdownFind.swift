import SwiftUI

/// A find session over a markdown preview, owned by whatever scrolls that
/// preview and shared with the preview itself.
///
/// The digest under the terminal is laid out as part of a page, so it cannot
/// scroll itself — the page around it does. A find bar inside the page would
/// scroll away with the text, and a match it highlighted could not be
/// brought into view by anything inside the web view. So the bar lives out
/// here, pinned over the scrolling page, and the web view only highlights:
/// it reports where the current match is, and the host moves the page.
@MainActor
final class MarkdownFind: ObservableObject {
    @Published var visible = false
    @Published var query = ""
    /// Counters, not flags: the preview steps once per tick and nothing has
    /// to be reset afterwards.
    @Published var nextRequests = 0
    @Published var prevRequests = 0
    /// Reported back by the preview.
    @Published var current = 0
    @Published var total = 0

    func show() { visible = true }

    func hide() {
        visible = false
        current = 0
        total = 0
    }
}

/// The bar itself: a field, the count, and a way through the matches.
/// ⏎ steps forward, ⇧⏎ back, esc closes.
struct MarkdownFindBar: View {
    @ObservedObject var find: MarkdownFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            TextField("Find in plan", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { find.nextRequests += 1 }
                .onExitCommand { find.hide() }
            Text(countLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            stepButton("chevron.up", help: "Previous match (⇧⏎)") { find.prevRequests += 1 }
            stepButton("chevron.down", help: "Next match (⏎)") { find.nextRequests += 1 }
            Button("Done") { find.hide() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(LoomColors.accent)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: LoomShape.field)
        .overlay(LoomShape.field.strokeBorder(LoomColors.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        // ⇧⏎ steps back. A hidden button is the one way to hear it while the
        // field has the keyboard, since a text field's submit cannot tell
        // shift from no shift.
        .background(
            Button("") { find.prevRequests += 1 }
                .keyboardShortcut(.return, modifiers: .shift)
                .opacity(0)
        )
        .onAppear { focused = true }
    }

    private var countLabel: String {
        if find.total == 0 { return find.query.isEmpty ? "" : "0" }
        return "\(find.current)/\(find.total)"
    }

    private func stepButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(find.total == 0 ? Color.secondary.opacity(0.4) : .secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(find.total == 0)
        .help(help)
    }
}
