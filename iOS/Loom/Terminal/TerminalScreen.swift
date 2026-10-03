import SwiftUI

struct TerminalScreen: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var terminal: TerminalController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("terminalFontSize") private var fontSize = 12.0
    @State private var selecting: SelectableItem?
    @State private var capturing = false
    @FocusState private var composerFocused: Bool

    private static let fontSizes: [Double] = [10, 11, 12, 13, 14, 16]

    var body: some View {
        Group {
            if session.paneTarget.isEmpty {
                placeholder
            } else {
                live
            }
        }
        .onAppear {
            terminal.setFontSize(fontSize)
            terminal.adopt(target: session.paneTarget)
            terminal.setVisible(scenePhase != .background)
        }
        .onDisappear { terminal.setVisible(false) }
        .onChange(of: session.paneTarget) { _, target in terminal.adopt(target: target) }
        .onChange(of: scenePhase) { _, phase in terminal.setVisible(phase != .background) }
        .onChange(of: fontSize) { _, size in terminal.setFontSize(size) }
        .onChange(of: session.terminalDraft) { _, _ in session.persistTerminalDraft() }
        .sheet(item: $selecting) { SelectableTextSheet(item: $0) }
    }

    private var live: some View {
        VStack(spacing: 0) {
            statusBar
            TerminalHost(controller: terminal)
                .overlay(alignment: .bottomTrailing) {
                    if terminal.scrolledBack {
                        Button {
                            terminal.backToLive()
                        } label: {
                            Label("Live", systemImage: "arrow.down.to.line")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .environment(\.colorScheme, .dark)
                        .padding(12)
                    }
                }
            keyBar
            composer
        }
        .background(TerminalTheme.screen)
    }

    // MARK: Status

    private var statusColor: Color {
        if terminal.connected { return LoomColors.green }
        return terminal.error.isEmpty ? .orange : LoomColors.red
    }

    private var statusText: String {
        if terminal.connected { return "Live" }
        return terminal.error.isEmpty ? "Connecting…" : terminal.error
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TerminalTheme.text)
                .lineLimit(1)
            if terminal.connected, !terminal.paneSize.isEmpty {
                Text(terminal.paneSize)
                    .font(.caption2.monospaced())
                    .foregroundStyle(TerminalTheme.dimText)
            }
            Spacer(minLength: 4)
            barButton("chevron.up.2", label: "Page Up") { terminal.page(up: true) }
            barButton("chevron.down.2", label: "Page Down") { terminal.page(up: false) }
            Button {
                selectText()
            } label: {
                Group {
                    if capturing {
                        ProgressView().controlSize(.small).tint(TerminalTheme.text)
                    } else {
                        Image(systemName: "text.viewfinder")
                    }
                }
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Select Text")
            .disabled(capturing)
            Menu {
                Picker("Text Size", selection: $fontSize) {
                    ForEach(Self.fontSizes, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                Button {
                    terminal.reconnectNow()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "textformat.size")
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            barButton("keyboard", label: "Keyboard") { terminal.toggleKeyboard() }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(TerminalTheme.text)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(TerminalTheme.chrome)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Keys

    /// The keys an agent's TUI asks for — pick an option, confirm, back out —
    /// without bringing up the keyboard.
    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc", "\u{1b}")
                key("^C", "\u{03}")
                key("tab", "\t")
                key("⇧tab", "\u{1b}[Z")
                key("↑", "\u{1b}[A")
                key("↓", "\u{1b}[B")
                key("←", "\u{1b}[D")
                key("→", "\u{1b}[C")
                key("⏎", "\r")
                key("y", "y")
                key("n", "n")
                key("1", "1")
                key("2", "2")
                key("3", "3")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(TerminalTheme.chrome)
    }

    private func key(_ label: String, _ bytes: String) -> some View {
        Button {
            terminal.sendInput(bytes)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(TerminalTheme.text)
                .frame(minWidth: 38, minHeight: 32)
                .padding(.horizontal, 4)
                .background(TerminalTheme.field, in: LoomShape.control)
                .contentShape(LoomShape.control)
        }
        .buttonStyle(.plain)
    }

    // MARK: Composer

    private var draftEmpty: Bool {
        session.terminalDraft.isEmpty
    }

    /// Typed here, text goes in through tmux's paste buffer: Chinese input and
    /// several lines arrive whole, where key-by-key they would be cut up by
    /// the IME or run as separate commands.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Type or paste, then send", text: $session.terminalDraft, axis: .vertical)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(TerminalTheme.text)
                .tint(LoomColors.accent)
                .lineLimit(1...5)
                .focused($composerFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(TerminalTheme.field, in: LoomShape.field)
            Menu {
                Button {
                    send(submit: false)
                } label: {
                    Label("Insert Without Enter", systemImage: "text.insert")
                }
                Button {
                    if let text = UIPasteboard.general.string { terminal.paste(text, submit: false) }
                } label: {
                    Label("Paste Clipboard", systemImage: "doc.on.clipboard")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(TerminalTheme.dimText)
                    .frame(width: 34, height: 38)
            }
            Button {
                send(submit: true)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(draftEmpty ? TerminalTheme.dimText : LoomColors.accent)
                    .frame(height: 38)
            }
            .disabled(draftEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(TerminalTheme.chrome)
        .environment(\.colorScheme, .dark)
    }

    private func send(submit: Bool) {
        let text = session.terminalDraft
        guard !text.isEmpty else { return }
        terminal.paste(text, submit: submit)
        session.terminalDraft = ""
        session.persistTerminalDraft()
    }

    private func selectText() {
        capturing = true
        Task {
            let text = await terminal.captureText()
            capturing = false
            if let text {
                selecting = SelectableItem(title: "Terminal", text: text, monospaced: true, scrollToEnd: true)
            }
        }
    }

    // MARK: Placeholder

    private var placeholder: some View {
        VStack(spacing: 14) {
            if session.detailLoading && session.detailError.isEmpty {
                ProgressView().tint(TerminalTheme.text)
                Text("Opening the terminal…")
                    .font(.subheadline)
                    .foregroundStyle(TerminalTheme.dimText)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 34))
                    .foregroundStyle(TerminalTheme.dimText)
                Text(session.detailError.isEmpty ? "No terminal for this task yet." : session.detailError)
                    .font(.subheadline)
                    .foregroundStyle(TerminalTheme.text)
                    .multilineTextAlignment(.center)
                if session.detailError.isEmpty && !session.online {
                    Button {
                        session.startAgent()
                    } label: {
                        if session.starting {
                            ProgressView()
                        } else {
                            Label("Start Agent", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.starting)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalTheme.screen)
    }
}

private struct TerminalHost: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> TerminalHostView {
        controller.host
    }

    func updateUIView(_ view: TerminalHostView, context: Context) {}
}
