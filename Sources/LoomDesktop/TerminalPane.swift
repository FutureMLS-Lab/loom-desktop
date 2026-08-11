import AppKit
import SwiftUI

/// The agent's live pane, rendered natively rather than in a web view: the
/// text is real `NSTextView` content, so selection, ⌘C, and scrolling behave
/// the way they do anywhere else on the Mac. Typing goes through a compose
/// field instead of a hidden textarea, which is what makes an input method
/// (Chinese, Japanese, emoji picker) work — the marked/composing text stays
/// in the field until you commit it, and only the committed string is sent.
struct TerminalPane: View {
    @ObservedObject var session: ChatSession

    @State private var text = ""
    @State private var error = ""
    @State private var loading = true
    @State private var followTail = true
    @AppStorage("terminalFontSize") private var fontSize: Double = 15
    @FocusState private var composerFocused: Bool
    @State private var sending = false
    @State private var poller: Task<Void, Never>?
    /// True while the output view holds keyboard focus, i.e. while typing
    /// goes straight to the pane.
    @State private var typingFocused = false

    /// A live pane deserves a fast refresh; one waiting for input does not.
    private static let workingInterval: TimeInterval = 0.7
    private static let idleInterval: TimeInterval = 2.5
    /// Capture enough of the live viewport after a tmux scroll that Claude's
    /// fullscreen TUI still fills the pane.
    private static let lines = 800
    @State private var scrollAccum: CGFloat = 0
    @State private var scrollFlush: Task<Void, Never>?
    /// The plan digest below the pane, mirroring the web console's agent tab.
    @AppStorage("terminalPlanExpanded") private var planExpanded = true

    var body: some View {
        Group {
            if planExpanded {
                // Draggable divider: how much plan you want visible depends on
                // whether you are reading it or driving the agent.
                VSplitView {
                    terminalCard
                        .frame(minHeight: 360)
                    // Capped, because the pane is what you are steering; the
                    // plan is reference. Drag the divider to change your mind.
                    PlanDigest(session: session)
                        .frame(minHeight: 110, idealHeight: 180, maxHeight: 360)
                }
            } else {
                VStack(spacing: 0) {
                    terminalCard
                    PlanDigest(session: session)
                }
            }
        }
        .onAppear {
            start()
            // Land ready to type. Focus has to be set after this run loop
            // turn, or SwiftUI has not built the field yet and drops it.
            DispatchQueue.main.async { composerFocused = true }
        }
        .onDisappear {
            poller?.cancel()
            poller = nil
            session.persistTerminalDraft()
        }
        .onChange(of: session.paneTarget) { _, _ in start() }
        .onChange(of: session.terminalDraft) { _, _ in
            session.persistTerminalDraft()
        }
    }

    private var terminalCard: some View {
        VStack(spacing: 0) {
            toolbar
            content
            composer
        }
        .background(
            LinearGradient(
                colors: [TerminalTheme.backgroundTop, TerminalTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                // No shadow: this toolbar re-renders on every capture, and a
                // layer shadow is re-applied each time for a 8pt dot nobody
                // looks at.
                Circle()
                    .fill(error.isEmpty ? LoomColors.green : LoomColors.red)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(error.isEmpty ? "Live session" : "Disconnected")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(TerminalTheme.text)
                    Text(error.isEmpty ? session.paneTarget : error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TerminalTheme.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(typingFocused ? "Typing into pane" : "Click pane to type")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(typingFocused ? TerminalTheme.inkAccent : TerminalTheme.dimText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    typingFocused
                        ? TerminalTheme.inkAccent.opacity(0.14)
                        : TerminalTheme.text.opacity(0.06),
                    in: Capsule()
                )

            HStack(spacing: 2) {
                toolbarIcon("textformat.size.smaller", help: "Smaller text (⌘−)") {
                    fontSize = max(9, fontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)
                Text("\(Int(fontSize))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalTheme.dimText)
                    .frame(minWidth: 18)
                toolbarIcon("textformat.size.larger", help: "Larger text (⌘+)") {
                    fontSize = min(28, fontSize + 1)
                }
                .keyboardShortcut("+", modifiers: .command)
            }
            toolbarIcon("doc.on.doc", help: "Copy the whole pane") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            toolbarIcon("arrow.down.to.line", help: "Jump to the latest output") {
                followTail = true
                // Also bring a scrolled-back remote pane home, since a
                // full-screen app's history is not in this buffer.
                Task { await scrollPane(direction: "down", lines: 80) }
            }
            .disabled(followTail)
            .opacity(followTail ? 0.35 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TerminalTheme.chrome.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TerminalTheme.rule)
                .frame(height: 1)
        }
    }

    private func toolbarIcon(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(TerminalTheme.dimText)
                .frame(width: 28, height: 28)
                .background(TerminalTheme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Output

    @ViewBuilder
    private var content: some View {
        if loading && text.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Attaching to the pane…")
                    .font(.system(size: 13))
                    .foregroundColor(TerminalTheme.dimText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SelectableTerminalText(
                text: text,
                fontSize: fontSize,
                followTail: $followTail,
                focused: $typingFocused,
                onLiteral: { characters in
                    Task { await sendLiteral(characters, submit: false) }
                },
                onKey: { key in
                    Task { await sendKey(key) }
                },
                onWheel: { deltaY in
                    enqueueScroll(deltaY: deltaY)
                }
            )
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(TerminalKeyButton.all, id: \.key) { item in
                    Button {
                        Task { await sendKey(item.key) }
                    } label: {
                        Text(item.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                LinearGradient(
                                    colors: [
                                        TerminalTheme.keycap,
                                        TerminalTheme.keycap.opacity(0.85),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(TerminalTheme.keycapBorder, lineWidth: 1)
                            )
                            .foregroundColor(TerminalTheme.text)
                    }
                    .buttonStyle(.plain)
                    .help(item.help)
                }
                Spacer()
                Text("中文走下面输入框")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalTheme.dimText.opacity(0.85))
            }

            HStack(alignment: .bottom, spacing: 8) {
                // A normal AppKit text field: the input method composes here
                // (中文/日本語/emoji all work), and only the committed text is
                // sent to the pane.
                TextField(
                    "输入文字发送到终端 · type here, ⏎ to send",
                    text: $session.terminalDraft,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .font(.system(size: 14.5))
                    .lineLimit(1...5)
                    .foregroundColor(TerminalTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(TerminalTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(TerminalTheme.keycapBorder.opacity(0.85), lineWidth: 1)
                    )
                    .onSubmit { Task { await sendDraft(submit: true) } }

                Button {
                    Task { await sendDraft(submit: false) }
                } label: {
                    Text("Paste")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(TerminalTheme.keycap, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(TerminalTheme.keycapBorder, lineWidth: 1)
                        )
                        .foregroundColor(TerminalTheme.text)
                }
                .buttonStyle(.plain)
                .help("Send the text without pressing Enter")
                .disabled(session.terminalDraft.isEmpty || sending)

                Button {
                    Task { await sendDraft(submit: true) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(
                            session.terminalDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AnyShapeStyle(TerminalTheme.dimText.opacity(0.45))
                                : AnyShapeStyle(TerminalTheme.inkAccent)
                        )
                }
                .buttonStyle(.plain)
                .help("Send and press Enter")
                .disabled(
                    session.terminalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || sending
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(TerminalTheme.chrome.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalTheme.rule)
                .frame(height: 1)
        }
    }

    // MARK: Behavior

    private func start() {
        poller?.cancel()
        guard !session.paneTarget.isEmpty else { return }
        loading = true
        poller = Task {
            while !Task.isCancelled {
                await refresh()
                let interval = session.working ? Self.workingInterval : Self.idleInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func refresh() async {
        do {
            let capture = try await session.api.capture(
                target: session.paneTarget,
                lines: Self.lines
            )
            if capture.ok == false {
                error = capture.error ?? "Pane unavailable"
            } else {
                // The gateway captures with `tmux capture-pane -p` and no `-e`,
                // so the text arrives as plain characters — no escape sequences
                // to strip, and no colour to recover either.
                let next = capture.text ?? ""
                if next != text { text = next }
                error = ""
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func sendKey(_ key: String) async {
        guard !session.paneTarget.isEmpty else { return }
        // PageUp/PageDown browse history the same way the web terminal does.
        if key == "PageUp" || key == "PageDown" {
            await scrollPane(direction: key == "PageUp" ? "up" : "down", lines: 24)
            return
        }
        try? await session.api.sendKey(target: session.paneTarget, key: key)
        followTail = true
        await refresh()
    }

    /// Match the web console: coalesce trackpad deltas, then POST /api/tmux/scroll
    /// so Claude's fullscreen (and tmux copy-mode) actually move.
    private func enqueueScroll(deltaY: CGFloat) {
        scrollAccum += deltaY
        scrollFlush?.cancel()
        scrollFlush = Task {
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            let total = scrollAccum
            scrollAccum = 0
            guard total != 0 else { return }
            let lines = max(1, min(80, Int((abs(total) / 24).rounded())))
            await scrollPane(direction: total < 0 ? "up" : "down", lines: lines)
        }
    }

    private func scrollPane(direction: String, lines: Int) async {
        guard !session.paneTarget.isEmpty else { return }
        do {
            try await session.api.scroll(
                target: session.paneTarget,
                direction: direction,
                lines: lines
            )
            await refresh()
        } catch {
            // Scroll is best-effort; keep showing the last capture.
        }
    }

    private func sendDraft(submit: Bool) async {
        let payload = session.terminalDraft
        guard !payload.isEmpty else { return }
        session.terminalDraft = ""
        session.persistTerminalDraft()
        if await !sendLiteral(payload, submit: submit) {
            session.terminalDraft = payload
            session.persistTerminalDraft()
        }
    }

    @discardableResult
    private func sendLiteral(_ text: String, submit: Bool) async -> Bool {
        guard !text.isEmpty, !session.paneTarget.isEmpty else { return false }
        do {
            try await session.api.sendLiteral(target: session.paneTarget, text: text)
            if submit {
                try await session.api.sendKey(target: session.paneTarget, key: "Enter")
            }
            followTail = true
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

}

private struct TerminalKeyButton {
    let label: String
    let key: String
    let help: String

    static let all: [TerminalKeyButton] = [
        .init(label: "esc", key: "Escape", help: "Escape — interrupt the agent"),
        .init(label: "^C", key: "C-c", help: "Ctrl-C"),
        .init(label: "⇥", key: "Tab", help: "Tab"),
        .init(label: "↑", key: "Up", help: "Up"),
        .init(label: "↓", key: "Down", help: "Down"),
        .init(label: "⏎", key: "Enter", help: "Enter"),
    ]
}

/// Parchment terminal — warm paper, dark ink. The yellow is held back to the
/// tint of aged paper rather than a highlighter, because a terminal is read
/// for minutes at a time and saturated backgrounds fight the text for
/// attention. Contrast lands around 12:1, comfortably past WCAG AAA.
enum TerminalTheme {
    static let backgroundTop = Color(red: 0xFE / 255, green: 0xF6 / 255, blue: 0xD6 / 255)
    static let background = Color(red: 0xF9 / 255, green: 0xEB / 255, blue: 0xBE / 255)
    static let chrome = Color(red: 0xF2 / 255, green: 0xE4 / 255, blue: 0xB8 / 255)
    static let keycap = Color(red: 0xFD / 255, green: 0xF6 / 255, blue: 0xDF / 255)
    static let keycapBorder = Color(red: 0xD4 / 255, green: 0xC1 / 255, blue: 0x8B / 255)
    static let inputBackground = Color(red: 0xFF / 255, green: 0xFC / 255, blue: 0xF2 / 255)
    static let text = Color(red: 0x2C / 255, green: 0x27 / 255, blue: 0x1C / 255)
    static let dimText = Color(red: 0x7B / 255, green: 0x6E / 255, blue: 0x51 / 255)
    static let rule = Color(red: 0xE4 / 255, green: 0xD6 / 255, blue: 0xAC / 255)
    static let inkAccent = Color(red: 0xA8 / 255, green: 0x52 / 255, blue: 0x18 / 255)
    static let selection = Color(red: 0xF6 / 255, green: 0xDC / 255, blue: 0x93 / 255)
}

/// A text view that types into the pane. Click it and keystrokes go straight
/// to the agent the way they would in Terminal.app — Return, arrows, Tab,
/// Ctrl-C included — while selection and ⌘C keep working, because the view is
/// selectable-but-not-editable and we intercept `keyDown` ourselves rather
/// than letting AppKit try to edit the buffer.
///
/// Input methods are the exception: marked (composing) text needs a real
/// editable field, so Chinese and other IME input goes through the compose
/// box below instead of here.
final class TerminalTextView: NSTextView {
    var onLiteral: ((String) -> Void)?
    var onKey: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        // ⌘C / ⌘A / ⌘F belong to the text view, not the pane.
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let key = Self.keyName(for: event) {
            onKey?(key)
            return
        }
        if let characters = event.characters, !characters.isEmpty {
            onLiteral?(characters)
        }
    }

    /// tmux key names for the keys a terminal needs but a string cannot carry.
    private static func keyName(for event: NSEvent) -> String? {
        if event.modifierFlags.contains(.control),
           let letter = event.charactersIgnoringModifiers?.lowercased().first,
           letter.isLetter {
            return "C-\(letter)"
        }
        switch event.keyCode {
        case 36, 76: return "Enter"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "BSpace" // tmux key name; "Backspace" is typed literally
        case 117: return "DC"
        case 126: return "Up"
        case 125: return "Down"
        case 123: return "Left"
        case 124: return "Right"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        default: return nil
        }
    }
}

/// Scrolling is hybrid, because the history lives in two different places.
///
/// `capture-pane -S -800` returns real scrollback for an ordinary pane, so that
/// history is already here and scrolls natively — instant, no network. A
/// full-screen app (Claude Code's TUI, vim, less) draws into the alternate
/// screen, which has no scrollback: the capture is exactly one viewport, and
/// the only way back is to ask the remote pane to scroll itself.
///
/// So: scroll locally while there is local content to scroll, and hand the
/// wheel to tmux once there is not — or once the top of the buffer is reached.
private final class TerminalScrollView: NSScrollView {
    /// Delta in the web console's convention: negative is "up / older".
    var onWheel: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // AppKit's positive `scrollingDeltaY` means scrolling toward the start
        // of the document — the opposite sign of a DOM wheel event, which is
        // what the /api/tmux/scroll contract is written against.
        let raw = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 18
        guard raw != 0, let onWheel else {
            super.scrollWheel(with: event)
            return
        }
        let dy = -raw
        let goingUp = dy < 0

        let documentHeight = documentView?.bounds.height ?? 0
        let viewport = contentView.bounds
        let hasLocalHistory = documentHeight > viewport.height + 4
        let atTop = viewport.minY <= 0.5
        let atBottom = documentHeight - viewport.maxY <= 0.5

        if hasLocalHistory, !(goingUp && atTop), !(!goingUp && atBottom) {
            super.scrollWheel(with: event)
            return
        }
        onWheel(dy)
    }
}

/// A read-only `NSTextView`: real macOS text selection and ⌘C. History browsing
/// is remote (tmux scroll), not local — see `TerminalScrollView`.
private struct SelectableTerminalText: NSViewRepresentable {
    let text: String
    let fontSize: Double
    @Binding var followTail: Bool
    @Binding var focused: Bool
    var onLiteral: (String) -> Void
    var onKey: (String) -> Void
    var onWheel: (CGFloat) -> Void

    func makeNSView(context: Context) -> TerminalScrollView {
        let scroll = TerminalScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(TerminalTheme.background)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.onWheel = onWheel

        let textView = TerminalTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(TerminalTheme.text)
        textView.insertionPointColor = NSColor(TerminalTheme.inkAccent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(TerminalTheme.selection),
            .foregroundColor: NSColor(TerminalTheme.text),
        ]
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Long agent output lines are easier to read wrapped than clipped.
        textView.textContainer?.widthTracksTextView = true
        textView.onLiteral = onLiteral
        textView.onKey = onKey
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { self.focused = focused }
        }
        scroll.documentView = textView

        context.coordinator.observe(scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: TerminalScrollView, context: Context) {
        guard let textView = scroll.documentView as? TerminalTextView else { return }
        scroll.onWheel = onWheel
        textView.onLiteral = onLiteral
        textView.onKey = onKey
        context.coordinator.followTail = $followTail

        let bg = NSColor(TerminalTheme.background)
        let fg = NSColor(TerminalTheme.text)
        scroll.backgroundColor = bg
        textView.backgroundColor = .clear
        textView.textColor = fg
        textView.insertionPointColor = NSColor(TerminalTheme.inkAccent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(TerminalTheme.selection),
            .foregroundColor: fg,
        ]

        // No line spacing and no kerning: a TUI draws boxes out of `│ ─ ╭ ╯`,
        // and any gap between lines or drift between columns breaks the frame
        // into dashes. A terminal's grid has to stay a grid.
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byCharWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: paragraph,
        ]

        let fontChanged = textView.typingAttributes[.font] as? NSFont != font
        guard textView.string != text || fontChanged else { return }

        // Anchor the view before swapping the buffer. Output arrives at the
        // bottom, so holding the distance to the bottom keeps whatever the
        // reader is looking at exactly where it was — no jump on every poll.
        let viewport = scroll.contentView.bounds
        let previousHeight = textView.frame.height
        let distanceToBottom = max(0, previousHeight - viewport.maxY)
        let selected = textView.selectedRange()

        textView.typingAttributes = attrs
        textView.font = font
        if let storage = textView.textStorage {
            storage.beginEditing()
            if fontChanged {
                storage.setAttributedString(
                    NSAttributedString(string: text, attributes: attrs)
                )
            } else {
                // A poll usually changes a spinner, a line, or appends at the
                // end — not 800 lines. Rewriting the whole storage re-lays out
                // the entire document twice a second; replacing just the span
                // that actually differs keeps the pane still and cheap.
                let (range, replacement) = Self.changedSpan(
                    from: storage.string,
                    to: text
                )
                storage.replaceCharacters(
                    in: range,
                    with: NSAttributedString(string: replacement, attributes: attrs)
                )
            }
            storage.endEditing()
        }
        if selected.location + selected.length <= (text as NSString).length {
            textView.setSelectedRange(selected)
        }

        // Lay the new text out before moving: until layout runs, the text view
        // still reports its old height, so "scroll to the end" would land at
        // the end of the *previous* buffer — near the top of a first capture.
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }

        // Programmatic scrolling must not be mistaken for the reader scrolling
        // away, or a single mistimed frame latches tail-following off for good.
        context.coordinator.suppressFollowUpdates = true
        if followTail {
            textView.scrollToEndOfDocument(nil)
        } else {
            let newHeight = textView.frame.height
            let target = max(0, newHeight - distanceToBottom - viewport.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        DispatchQueue.main.async {
            context.coordinator.suppressFollowUpdates = false
        }
    }

    /// The span of `old` that has to be rewritten to become `new`: everything
    /// between the shared head and the shared tail. Boundaries are snapped to
    /// composed-character sequences so an edit can never land inside a
    /// surrogate pair or split a character from its combining marks.
    static func changedSpan(from old: String, to new: String) -> (NSRange, String) {
        let oldText = old as NSString
        let newText = new as NSString
        let shortest = min(oldText.length, newText.length)

        var head = 0
        while head < shortest, oldText.character(at: head) == newText.character(at: head) {
            head += 1
        }
        if head > 0, head < oldText.length {
            let sequence = oldText.rangeOfComposedCharacterSequence(at: head)
            if sequence.location < head { head = sequence.location }
        }

        var tail = 0
        while tail < shortest - head,
              oldText.character(at: oldText.length - 1 - tail)
                == newText.character(at: newText.length - 1 - tail) {
            tail += 1
        }
        if tail > 0 {
            let boundary = oldText.length - tail
            if boundary > 0, boundary < oldText.length {
                let sequence = oldText.rangeOfComposedCharacterSequence(at: boundary)
                if sequence.location < boundary {
                    tail = max(0, oldText.length - (sequence.location + sequence.length))
                }
            }
        }
        if head + tail > shortest { tail = max(0, shortest - head) }

        return (
            NSRange(location: head, length: oldText.length - head - tail),
            newText.substring(with: NSRange(location: head, length: newText.length - head - tail))
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(followTail: $followTail) }

    final class Coordinator {
        var followTail: Binding<Bool>
        /// True while the view is being scrolled by code rather than by hand.
        var suppressFollowUpdates = false
        private var observer: NSObjectProtocol?
        private var reflowObserver: NSObjectProtocol?

        init(followTail: Binding<Bool>) {
            self.followTail = followTail
        }

        /// Scrolling up releases tail-follow; coming back to the bottom re-arms
        /// it, the way any log viewer behaves.
        func observe(scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak scroll] _ in
                guard !self.suppressFollowUpdates else { return }
                guard let scroll, let documentView = scroll.documentView else { return }
                let visible = scroll.contentView.bounds
                // A pane with no local scrollback (a full-screen app) is always
                // "at the bottom"; tail-follow must stay on there.
                let scrollable = documentView.bounds.height > visible.height + 4
                let atBottom = !scrollable
                    || documentView.bounds.height - visible.maxY < 24
                if self.followTail.wrappedValue != atBottom {
                    self.followTail.wrappedValue = atBottom
                }
            }

            // Anything that changes the wrap width — opening the plan panel,
            // dragging the split, resizing the window — re-flows the text and
            // changes its height, which silently strands a bottom-pinned view
            // partway up. No text changed, so nothing else would notice.
            guard let textView = scroll.documentView else { return }
            textView.postsFrameChangedNotifications = true
            reflowObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak scroll] _ in
                guard self.followTail.wrappedValue,
                      !self.suppressFollowUpdates,
                      let documentView = scroll?.documentView as? NSTextView
                else { return }
                self.suppressFollowUpdates = true
                documentView.scrollToEndOfDocument(nil)
                DispatchQueue.main.async { self.suppressFollowUpdates = false }
            }
        }

        deinit {
            let center = NotificationCenter.default
            if let observer { center.removeObserver(observer) }
            if let reflowObserver { center.removeObserver(reflowObserver) }
        }
    }
}
