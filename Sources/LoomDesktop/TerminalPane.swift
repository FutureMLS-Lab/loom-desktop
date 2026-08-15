import SwiftUI

/// The Terminal tab: the agent's pane above, the task's plan below — the same
/// pairing the web console's agent tab has.
///
/// The pane itself is xterm attached to the pty (`TerminalSession`), so what
/// is on screen is what the agent drew: colour, cursor, and a pane sized to
/// this window rather than reflowed out of someone else's column count.
struct TerminalPane: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var terminal = TerminalSession.shared

    @AppStorage("terminalFontSize") private var fontSize: Double = 14
    @AppStorage("terminalPlanExpanded") private var planExpanded = true
    @State private var composerHeight = ComposerField.minHeight
    @State private var composerRevision = 0

    var body: some View {
        // One scrolling page, the way the web console's agent tab reads: the
        // pane at a fixed height, the plan running on underneath it. A split
        // with a draggable divider meant two things to scroll and a size to
        // manage; this just scrolls.
        GeometryReader { geometry in
            if planExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        terminalCard
                            .frame(height: max(340, geometry.size.height * 0.72))
                        PlanDigest(session: session)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    terminalCard
                    PlanDigest(session: session)
                }
            }
        }
        .onAppear {
            terminal.adopt(owner: session.id, target: session.paneTarget)
            terminal.fontSize = fontSize
        }
        .onDisappear {
            terminal.release(owner: session.id)
            session.persistTerminalDraft()
        }
        .onChange(of: session.paneTarget) { _, target in
            guard terminal.owner == session.id else { return }
            terminal.target = target
        }
        // Coming back to the tab, or arriving after the window was resized
        // while another tab was up, has to re-measure: nothing else would.
        .onChange(of: planExpanded) { _, _ in terminal.refit() }
        .onChange(of: fontSize) { _, size in terminal.fontSize = size }
        .onChange(of: session.terminalDraft) { _, _ in session.persistTerminalDraft() }
    }

    private var terminalCard: some View {
        VStack(spacing: 0) {
            toolbar
            TerminalWebView(session: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .background(TerminalTheme.screen)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(terminal.connected ? "Live session" : (terminal.error.isEmpty ? "Connecting…" : "Disconnected"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(TerminalTheme.text)
                    Text(terminal.error.isEmpty ? session.paneTarget : terminal.error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TerminalTheme.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if !terminal.paneSize.isEmpty {
                Text(terminal.paneSize)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalTheme.dimText)
                    .help(
                        """
                        Columns × rows this window asked for.
                        The session is sized to its smallest client, so another \
                        browser tab or `tmux attach` open on this task will \
                        shrink the pane here too.
                        """
                    )
            }

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

            toolbarIcon("doc.on.doc", help: "Copy the selection") {
                terminal.copySelection()
            }
            toolbarIcon("arrow.down.to.line", help: "Jump to the latest output") {
                terminal.scrollToBottom()
            }
            toolbarIcon(
                "arrow.up.left.and.arrow.down.right",
                help: "Resize the pane to this window — tmux keeps whatever size the smallest client left it at"
            ) {
                terminal.refit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TerminalTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TerminalTheme.rule).frame(height: 1)
        }
    }

    private var statusColor: Color {
        if !terminal.error.isEmpty { return LoomColors.red }
        return terminal.connected ? LoomColors.green : LoomColors.amber
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

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(TerminalKey.all, id: \.label) { key in
                    Button {
                        terminal.send(key.bytes)
                    } label: {
                        Text(key.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(TerminalTheme.keycap, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(TerminalTheme.keycapBorder, lineWidth: 1)
                            )
                            .foregroundColor(TerminalTheme.text)
                    }
                    .buttonStyle(.plain)
                    .help(key.help)
                }
                Spacer()
                Text("点击终端即可直接输入 · 中文用下方输入框")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalTheme.dimText.opacity(0.85))
            }

            HStack(alignment: .bottom, spacing: 8) {
                // An input method needs a real text view to compose in; the
                // terminal only ever receives the committed string.
                ComposerField(
                    text: $session.terminalDraft,
                    measuredHeight: $composerHeight,
                    contentRevision: composerRevision,
                    placeholder: "输入文字发送到终端 · ⏎ 发送，⇧⏎ 换行",
                    focusOnAppear: true,
                    onSubmit: { sendDraft(submit: true) }
                )
                .frame(height: composerHeight)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(TerminalTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(TerminalTheme.keycapBorder.opacity(0.85), lineWidth: 1)
                )

                Button { sendDraft(submit: false) } label: {
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
                .disabled(session.terminalDraft.isEmpty)

                Button { sendDraft(submit: true) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(
                            session.terminalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AnyShapeStyle(TerminalTheme.dimText.opacity(0.45))
                                : AnyShapeStyle(TerminalTheme.inkAccent)
                        )
                }
                .buttonStyle(.plain)
                .help("Send and press Enter")
                .disabled(
                    session.terminalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(TerminalTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(TerminalTheme.rule).frame(height: 1)
        }
    }

    private func sendDraft(submit: Bool) {
        let payload = session.terminalDraft
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.terminalDraft = ""
        composerRevision += 1
        session.persistTerminalDraft()
        terminal.paste(payload, submit: submit)
    }
}

/// Keys a terminal sends as bytes, which is all the pty wants.
private struct TerminalKey {
    let label: String
    let bytes: String
    let help: String

    static let all: [TerminalKey] = [
        .init(label: "esc", bytes: "\u{1B}", help: "Escape — interrupt the agent"),
        .init(label: "^C", bytes: "\u{03}", help: "Ctrl-C"),
        .init(label: "⇥", bytes: "\t", help: "Tab"),
        .init(label: "↑", bytes: "\u{1B}[A", help: "Up"),
        .init(label: "↓", bytes: "\u{1B}[B", help: "Down"),
        .init(label: "⏎", bytes: "\r", help: "Enter"),
    ]
}

/// The chrome around the terminal. The screen itself is xterm's, themed in
/// `TerminalSession` with the web console's palette; these are the surfaces
/// the card sits in, matching the rest of the app — pale sage in light mode,
/// and in dark mode the same green warmth pulled down next to the screen.
enum TerminalTheme {
    /// Matches xterm's background, so the card has no seam while it loads.
    /// Keep in step with the same colours in `TerminalWeb`'s page. The one
    /// colour here that does not change with the appearance: the screen is
    /// always dark.
    static let screen = Color(red: 0x1E / 255, green: 0x23 / 255, blue: 0x20 / 255)
    static let chrome = LoomColors.dynamic(light: 0xD8E2D7, dark: 0x272C28)
    static let keycap = LoomColors.dynamic(light: 0xEFF4EE, dark: 0x323A34)
    static let keycapBorder = LoomColors.dynamic(light: 0xB4C4B3, dark: 0x44503F)
    static let inputBackground = LoomColors.dynamic(light: 0xF6FAF5, dark: 0x232823)
    static let text = LoomColors.dynamic(light: 0x252B26, dark: 0xDFE6DD)
    static let dimText = LoomColors.dynamic(light: 0x637365, dark: 0x8D9C8F)
    static let rule = LoomColors.dynamic(light: 0xC4D2C3, dark: 0x39413A)
    static let inkAccent = LoomColors.dynamic(light: 0x3C7A5C, dark: 0x7FBF9C)

    /// `NSColor` twins for AppKit views configured once at creation
    /// (`ComposerField`'s text view): a dynamic `NSColor` keeps tracking the
    /// appearance, where `NSColor(Color)` would freeze the value it resolved.
    static let textNS = LoomColors.dynamicNSColor(light: 0x252B26, dark: 0xDFE6DD)
    static let inkAccentNS = LoomColors.dynamicNSColor(light: 0x3C7A5C, dark: 0x7FBF9C)
}
