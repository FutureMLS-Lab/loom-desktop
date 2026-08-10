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
    @AppStorage("terminalFontSize") private var fontSize: Double = 13
    @State private var draft = ""
    @State private var sending = false
    @State private var poller: Task<Void, Never>?
    /// True while the output view holds keyboard focus, i.e. while typing
    /// goes straight to the pane.
    @State private var typingFocused = false

    /// A live pane deserves a fast refresh; one waiting for input does not.
    private static let workingInterval: TimeInterval = 0.7
    private static let idleInterval: TimeInterval = 2.5
    private static let lines = 500

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            composer
        }
        .background(TerminalTheme.background)
        .onAppear { start() }
        .onDisappear { poller?.cancel(); poller = nil }
        .onChange(of: session.paneTarget) { _, _ in start() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(error.isEmpty ? LoomColors.green : LoomColors.red)
                    .frame(width: 7, height: 7)
                Text(error.isEmpty ? "Live" : error)
                    .font(.system(size: 12))
                    .foregroundColor(TerminalTheme.dimText)
                    .lineLimit(1)
            }
            Text(session.paneTarget)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(TerminalTheme.dimText.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(typingFocused ? "typing here" : "click to type")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(typingFocused ? LoomColors.accent : TerminalTheme.dimText.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    typingFocused ? LoomColors.accent.opacity(0.16) : Color.white.opacity(0.06),
                    in: Rectangle()
                )

            Button { fontSize = max(9, fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .help("Smaller text")
            Button { fontSize = min(20, fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .help("Larger text")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy the whole pane")
            Button { followTail = true } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .help("Jump to the latest output")
            .disabled(followTail)
        }
        .buttonStyle(.plain)
        .foregroundColor(TerminalTheme.dimText)
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(TerminalTheme.chrome)
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
                }
            )
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(TerminalKeyButton.all, id: \.key) { item in
                    Button {
                        Task { await sendKey(item.key) }
                    } label: {
                        Text(item.label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(TerminalTheme.keycap, in: Rectangle())
                            .overlay(
                                Rectangle()
                                    .strokeBorder(TerminalTheme.keycapBorder, lineWidth: 1)
                            )
                            .foregroundColor(TerminalTheme.text)
                    }
                    .buttonStyle(.plain)
                    .help(item.help)
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 8) {
                // A normal AppKit text field: the input method composes here
                // (中文/日本語/emoji all work), and only the committed text is
                // sent to the pane.
                TextField("输入文字发送到终端 · type here, ⏎ to send", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .foregroundColor(TerminalTheme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(TerminalTheme.inputBackground, in: Rectangle())
                    .overlay(
                        Rectangle()
                            .strokeBorder(TerminalTheme.keycapBorder, lineWidth: 1)
                    )
                    .onSubmit { Task { await sendDraft(submit: true) } }

                Button {
                    Task { await sendDraft(submit: false) }
                } label: {
                    Text("Paste")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(TerminalTheme.keycap, in: Rectangle())
                        .foregroundColor(TerminalTheme.text)
                }
                .buttonStyle(.plain)
                .help("Send the text without pressing Enter")
                .disabled(draft.isEmpty || sending)

                Button {
                    Task { await sendDraft(submit: true) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AnyShapeStyle(TerminalTheme.dimText.opacity(0.5))
                                : AnyShapeStyle(LoomColors.accent)
                        )
                }
                .buttonStyle(.plain)
                .help("Send and press Enter")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(10)
        .background(TerminalTheme.chrome)
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
        try? await session.api.sendKey(target: session.paneTarget, key: key)
        followTail = true
        await refresh()
    }

    private func sendDraft(submit: Bool) async {
        let payload = draft
        guard !payload.isEmpty else { return }
        draft = ""
        if await !sendLiteral(payload, submit: submit) {
            draft = payload
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

/// The xterm palette the loom-app uses, so a pane looks the same everywhere.
enum TerminalTheme {
    static let background = Color(red: 0x11 / 255, green: 0x10 / 255, blue: 0x14 / 255)
    static let chrome = Color(red: 0x19 / 255, green: 0x18 / 255, blue: 0x1D / 255)
    static let keycap = Color(red: 0x28 / 255, green: 0x26 / 255, blue: 0x2D / 255)
    static let keycapBorder = Color(red: 0x4A / 255, green: 0x47 / 255, blue: 0x51 / 255)
    static let inputBackground = Color(red: 0x1F / 255, green: 0x1E / 255, blue: 0x24 / 255)
    static let text = Color(red: 0xDE / 255, green: 0xD9 / 255, blue: 0xE2 / 255)
    static let dimText = Color(red: 0xAA / 255, green: 0xA5 / 255, blue: 0xB0 / 255)
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
        case 51: return "Backspace"
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

/// A read-only `NSTextView`: real macOS text selection, ⌘C, and scrolling —
/// which a SwiftUI `Text` in a `ScrollView` cannot give at this size.
private struct SelectableTerminalText: NSViewRepresentable {
    let text: String
    let fontSize: Double
    @Binding var followTail: Bool
    @Binding var focused: Bool
    var onLiteral: (String) -> Void
    var onKey: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(TerminalTheme.background)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

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
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(TerminalTheme.background)
        textView.textColor = NSColor(TerminalTheme.text)
        textView.insertionPointColor = NSColor(LoomColors.accent)
        textView.textContainerInset = NSSize(width: 10, height: 10)
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

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? TerminalTextView else { return }
        context.coordinator.followTail = $followTail
        textView.onLiteral = onLiteral
        textView.onKey = onKey

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.string != text || textView.font != font {
            // Keep the selection anchored across refreshes so a poll landing
            // mid-drag does not wipe what the user just highlighted.
            let selected = textView.selectedRange()
            textView.font = font
            textView.string = text
            if selected.location + selected.length <= (text as NSString).length {
                textView.setSelectedRange(selected)
            }
            if followTail {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(followTail: $followTail) }

    final class Coordinator {
        var followTail: Binding<Bool>
        private var observer: NSObjectProtocol?

        init(followTail: Binding<Bool>) {
            self.followTail = followTail
        }

        /// Scrolling up releases the tail-follow; scrolling back to the bottom
        /// re-arms it, the way any log viewer behaves.
        func observe(scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak scroll] _ in
                guard let scroll, let documentView = scroll.documentView else { return }
                let visible = scroll.contentView.bounds
                let distance = documentView.bounds.height - visible.maxY
                let atBottom = distance < 24
                if self.followTail.wrappedValue != atBottom {
                    self.followTail.wrappedValue = atBottom
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
