import AppKit
import SwiftUI

/// The Terminal tab: the agent's pane above, the task's plan below — the same
/// pairing the web console's agent tab has.
///
/// The pane itself is xterm attached to the pty (`TerminalSession`), so what
/// is on screen is what the agent drew: colour, cursor, and a pane sized to
/// this window rather than reflowed out of someone else's column count.
struct TerminalPane: View {
    @ObservedObject var session: ChatSession
    @StateObject private var terminal = TerminalSession()

    @AppStorage("terminalFontSize") private var fontSize: Double = 14
    @AppStorage("terminalPlanExpanded") private var planExpanded = true
    @FocusState private var composerFocused: Bool
    @State private var sending = false

    var body: some View {
        Group {
            if planExpanded {
                VSplitView {
                    terminalCard
                        .frame(minHeight: 360)
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
            terminal.target = session.paneTarget
            terminal.fontSize = fontSize
            DispatchQueue.main.async { composerFocused = true }
        }
        .onDisappear {
            terminal.stop()
            session.persistTerminalDraft()
        }
        .onChange(of: session.paneTarget) { _, target in terminal.target = target }
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
                // An input method needs a real text field to compose in; the
                // terminal only ever receives the committed string.
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
                .onSubmit { sendDraft(submit: true) }

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
                .disabled(session.terminalDraft.isEmpty || sending)

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
                        || sending
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
        guard !payload.isEmpty else { return }
        session.terminalDraft = ""
        session.persistTerminalDraft()
        terminal.send(submit ? payload + "\r" : payload)
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
/// `TerminalSession` with the web console's palette; these are the light
/// surfaces the card sits in, matching the rest of the app.
enum TerminalTheme {
    /// Matches xterm's background, so the card has no seam while it loads.
    static let screen = Color(red: 0x21 / 255, green: 0x1D / 255, blue: 0x1A / 255)
    static let chrome = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xC6 / 255)
    static let keycap = Color(red: 0xFD / 255, green: 0xF6 / 255, blue: 0xDF / 255)
    static let keycapBorder = Color(red: 0xD4 / 255, green: 0xC1 / 255, blue: 0x8B / 255)
    static let inputBackground = Color(red: 0xFF / 255, green: 0xFC / 255, blue: 0xF2 / 255)
    static let text = Color(red: 0x2C / 255, green: 0x27 / 255, blue: 0x1C / 255)
    static let dimText = Color(red: 0x7B / 255, green: 0x6E / 255, blue: 0x51 / 255)
    static let rule = Color(red: 0xE4 / 255, green: 0xD6 / 255, blue: 0xAC / 255)
    static let inkAccent = Color(red: 0xA8 / 255, green: 0x52 / 255, blue: 0x18 / 255)
}
