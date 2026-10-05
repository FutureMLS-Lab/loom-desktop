import SwiftTerm
import SwiftUI
import UIKit

/// The agent's pane, attached to its pty and drawn by SwiftTerm.
///
/// The transport is the desktop's: `GET /api/tmux/stream` carries the raw
/// bytes, `POST /api/tmux/stream-input` writes keys back to the same pty, and
/// tmux sizes the pane to the columns asked for. What is different here is
/// what a phone needs: keys typed into a native view, a selection the
/// system's handles drive, and a keyboard that comes and goes without
/// re-attaching each time.
@MainActor
final class TerminalController: NSObject, ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var error = ""
    @Published private(set) var paneSize = ""
    /// The pane is showing history rather than the live screen.
    @Published private(set) var scrolledBack = false
    /// The terminal has the keyboard: what is typed goes straight to the pane.
    @Published private(set) var typing = false
    /// Ctrl is held for the next key typed on the keyboard.
    @Published private(set) var controlArmed = false
    /// A keyboard is on screen, for the terminal or for the composer.
    @Published private(set) var keyboardUp = false

    let terminalView: LoomTerminalView
    let host: TerminalHostView

    private let api = LoomAPI()
    private(set) var target = ""
    private var visible = false
    private var inWindow = false
    private var appActive = true
    /// The grid has been sized to the screen once. Attached before that, tmux
    /// sizes the pane to the placeholder frame and the real size costs a
    /// second attach straight after.
    private var laidOut = false
    private var cols = 0
    private var rows = 0

    private var streamTask: URLSessionDataTask?
    private var streamSession: URLSession?
    private var streamID = ""
    /// Which attachment a callback belongs to: a cancelled stream still
    /// delivers what was in flight, and must not paint over its successor.
    private var streamGeneration = 0
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var reconnectStreak = 0
    private var reattach: Task<Void, Never>?
    private var mouseFilter = MouseModeFilter()

    private var inputQueue: [String] = []
    private var inputInFlight = false

    private var pendingScroll = 0
    private var scrollInFlight = false
    private var panRemainder: CGFloat = 0

    private static var streamConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 86_400
        config.networkServiceType = .responsiveData
        return config
    }

    override init() {
        let view = LoomTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        terminalView = view
        host = TerminalHostView(terminal: view)
        super.init()
        configure()
    }

    deinit {
        streamTask?.cancel()
        streamSession?.invalidateAndCancel()
    }

    private func configure() {
        terminalView.terminalDelegate = self
        // Touches stay local: a long press selects here instead of reaching
        // the agent's TUI as a click, and a drag scrolls through the server.
        terminalView.allowMouseReporting = false
        terminalView.isScrollEnabled = false
        // Slid up under the navigation bar with the keyboard up; safe-area
        // insets there would push the grid down.
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.keyboardAppearance = .dark
        // SwiftTerm's own key bar: its "hide keyboard" button swaps in a panel
        // of special keys rather than hiding anything, so there was no way
        // back to the full screen. The screen's key bar replaces it.
        terminalView.inputAccessoryView = nil
        terminalView.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
        let background = LoomColors.uiColor(TerminalTheme.background)
        terminalView.backgroundColor = background
        terminalView.nativeBackgroundColor = background
        terminalView.nativeForegroundColor = LoomColors.uiColor(TerminalTheme.foreground)
        terminalView.caretColor = LoomColors.uiColor(TerminalTheme.caret)
        terminalView.installColors(TerminalTheme.palette.map { value in
            SwiftTerm.Color(
                red8: UInt16((value >> 16) & 0xFF),
                green8: UInt16((value >> 8) & 0xFF),
                blue8: UInt16(value & 0xFF)
            )
        })
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        terminalView.addGestureRecognizer(pan)
        host.onLayout = { [weak self] in self?.hostLaidOut() }
        host.onWindowChange = { [weak self] inWindow in
            self?.inWindow = inWindow
            self?.updateVisibility()
        }
        host.onKeyboardChange = { [weak self] up in
            if self?.keyboardUp != up { self?.keyboardUp = up }
        }
    }

    private func focusChanged(_ focused: Bool) {
        host.holdsHeight = focused
        if typing != focused { typing = focused }
        if !focused && controlArmed {
            controlArmed = false
            terminalView.controlModifier = false
        }
    }

    private func hostLaidOut() {
        guard !laidOut else { return }
        laidOut = true
        let terminal = terminalView.getTerminal()
        cols = terminal.cols
        rows = terminal.rows
        paneSize = "\(cols)×\(rows)"
        attachIfReady()
    }

    // MARK: Lifecycle

    /// The app in front or not. Together with the terminal being in a window,
    /// that is "on screen"; off, the stream is closed: an attach left open by
    /// a phone in a pocket holds the pane for nobody.
    func setAppActive(_ active: Bool) {
        appActive = active
        updateVisibility()
    }

    private func updateVisibility() {
        let now = inWindow && appActive
        guard now != visible else { return }
        visible = now
        if now {
            attachIfReady()
        } else {
            stop()
        }
    }

    func adopt(target: String) {
        guard target != self.target else {
            attachIfReady()
            return
        }
        stop()
        self.target = target
        scrolledBack = false
        terminalView.feed(text: "\u{1b}c")
        attachIfReady()
    }

    func reconnectNow() {
        stop(keepInput: true)
        reconnectStreak = 0
        attachIfReady()
    }

    func stop(keepInput: Bool = false) {
        // The server keeps its own end of the stream until told; cancelling
        // only closes ours.
        if !streamID.isEmpty {
            let id = streamID
            Task { [api] in try? await api.closeStream(streamId: id) }
        }
        streamGeneration &+= 1
        streamTask?.cancel()
        streamTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        heartbeat?.cancel()
        heartbeat = nil
        reconnect?.cancel()
        reconnect = nil
        reattach?.cancel()
        reattach = nil
        if keepInput {
            inputQueue.removeAll(where: Self.isTerminalReply)
        } else {
            inputQueue.removeAll()
        }
        streamID = ""
        connected = false
    }

    private func attachIfReady() {
        guard visible, laidOut, !target.isEmpty, cols > 0, rows > 0,
              streamTask == nil, reconnect == nil
        else { return }
        attach()
    }

    private func attach() {
        guard let request = api.streamRequest(target: target, cols: cols, rows: rows) else { return }
        streamGeneration &+= 1
        let generation = streamGeneration
        let delegate = PtyStreamDelegate(
            onResponse: { [weak self] http in
                guard let self, generation == self.streamGeneration else { return }
                guard http.statusCode == 200 else {
                    self.error = "Pane unavailable (\(http.statusCode))"
                    return
                }
                self.streamID = http.value(forHTTPHeaderField: "X-Loom-Terminal-Stream") ?? ""
                self.mouseFilter.reset()
                // A clean screen for tmux's opening redraw, so nothing of the
                // previous attachment is left under it.
                self.terminalView.feed(text: "\u{1b}c")
                self.connected = true
                self.error = ""
                self.reconnectStreak = 0
                self.startHeartbeat()
                self.pumpInput()
            },
            onChunk: { [weak self] data in
                guard let self, generation == self.streamGeneration, self.connected else { return }
                let bytes = self.mouseFilter.filter(data)
                if !bytes.isEmpty { self.terminalView.feed(byteArray: bytes[...]) }
            },
            onComplete: { [weak self] failure in
                guard let self, generation == self.streamGeneration else { return }
                self.streamTask = nil
                self.streamSession?.finishTasksAndInvalidate()
                self.streamSession = nil
                self.heartbeat?.cancel()
                self.heartbeat = nil
                self.streamID = ""
                self.connected = false
                let cancelled = (failure as NSError?)?.code == NSURLErrorCancelled
                if let failure, !cancelled { self.error = failure.localizedDescription }
                if !cancelled { self.scheduleReconnect() }
            }
        )
        let session = URLSession(configuration: Self.streamConfiguration, delegate: delegate, delegateQueue: .main)
        streamSession = session
        let task = session.dataTask(with: request)
        streamTask = task
        task.resume()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let id = streamID
        guard !id.isEmpty else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.streamID == id else { return }
                try? await self.api.streamHeartbeat(streamId: id)
            }
        }
    }

    /// Longer each time, to half a minute: every attach costs the server a pty
    /// and a `tmux attach`.
    private func scheduleReconnect() {
        guard visible, !target.isEmpty, reconnect == nil else { return }
        reconnectStreak += 1
        let delay = min(pow(2.0, Double(min(reconnectStreak, 5))), 30)
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnect = nil
            self.attachIfReady()
        }
    }

    /// A new grid is a new attach — tmux sizes the pane to the client. Held a
    /// moment, since a rotation or a font change reports several steps.
    private func resized(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        paneSize = "\(cols)×\(rows)"
        guard streamTask != nil else {
            attachIfReady()
            return
        }
        reattach?.cancel()
        reattach = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.stop(keepInput: true)
            self.attachIfReady()
        }
    }

    // MARK: Input

    /// One request at a time, with everything typed meanwhile folded into the
    /// next. One request per key, each waiting on the last, is what made
    /// typing stall: on a remote link the keys queued faster than they left.
    func sendInput(_ text: String) {
        guard !text.isEmpty else { return }
        inputQueue.append(text)
        pumpInput()
    }

    /// What the terminal answers on its own — its version, its device
    /// attributes, a cursor report, a colour — as against keys typed. An
    /// answer belongs to the tmux client that asked; delivered to the next
    /// one, which has had its own, it is read as keys and lands in the
    /// agent's prompt as text.
    private static func isTerminalReply(_ text: String) -> Bool {
        guard text.hasPrefix("\u{1b}") else { return false }
        if text.hasPrefix("\u{1b}P") || text.hasPrefix("\u{1b}]") { return true }
        guard text.hasPrefix("\u{1b}["), let last = text.last else { return false }
        let body = text.dropFirst(2)
        if body.hasPrefix("?") || body.hasPrefix(">") {
            return ["c", "y", "u", "R", "n"].contains(last)
        }
        return last == "n" || (last == "R" && body.contains(";"))
    }

    private func pumpInput() {
        guard !inputInFlight, !streamID.isEmpty, !inputQueue.isEmpty else { return }
        var chunk = ""
        var bareEscape = false
        while let next = inputQueue.first {
            // Esc alone, and a beat after it: run into the next key it reads
            // as Alt+key.
            if next == "\u{1b}" {
                if !chunk.isEmpty { break }
                inputQueue.removeFirst()
                chunk = next
                bareEscape = true
                break
            }
            if !chunk.isEmpty, chunk.utf8.count + next.utf8.count > 4000 { break }
            inputQueue.removeFirst()
            chunk += next
        }
        guard !chunk.isEmpty else { return }
        inputInFlight = true
        let id = streamID
        let pane = target
        let leaveHistory = scrolledBack
        if leaveHistory {
            scrolledBack = false
            pendingScroll = 0
        }
        Task { [weak self] in
            guard let self else { return }
            // Keys typed into tmux's copy-mode move its cursor instead of
            // reaching the agent.
            if leaveHistory { try? await self.api.scroll(target: pane, direction: "bottom", lines: 1) }
            try? await self.api.streamInput(streamId: id, text: chunk)
            if bareEscape { try? await Task.sleep(nanoseconds: 40_000_000) }
            self.inputInFlight = false
            self.pumpInput()
        }
    }

    /// Text from the composer, delivered through tmux's paste buffer: Chinese
    /// and multi-line text arrive in one piece, and Enter after it as its own
    /// keystroke.
    func paste(_ text: String, submit: Bool) {
        guard !text.isEmpty, !target.isEmpty else { return }
        let pane = target
        scrolledBack = false
        Task { [api] in try? await api.sendText(target: pane, text: text, submit: submit) }
    }

    func showKeyboard() {
        _ = terminalView.becomeFirstResponder()
    }

    func hideKeyboard() {
        _ = terminalView.resignFirstResponder()
    }

    func toggleKeyboard() {
        if typing {
            hideKeyboard()
        } else {
            showKeyboard()
        }
    }

    /// Ctrl for the next key typed on the keyboard — ctrl+r, ctrl+o in the
    /// agents' TUIs. SwiftTerm lets go of it once that key is sent.
    func toggleControl() {
        controlArmed.toggle()
        terminalView.controlModifier = controlArmed
    }

    enum Arrow {
        case up, down, left, right
    }

    /// In the form the program asked for: a TUI that put the cursor keys in
    /// application mode reads `ESC O A`, not `ESC [ A`.
    func sendArrow(_ arrow: Arrow) {
        let introducer = terminalView.getTerminal().applicationCursor ? "O" : "["
        let final: String
        switch arrow {
        case .up: final = "A"
        case .down: final = "B"
        case .right: final = "C"
        case .left: final = "D"
        }
        sendInput("\u{1b}\(introducer)\(final)")
    }

    func setFontSize(_ size: Double) {
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        if terminalView.font.pointSize != font.pointSize { terminalView.font = font }
    }

    /// The pane as text, for selecting a piece of it.
    func captureText() async -> String? {
        guard !target.isEmpty,
              let capture = try? await api.capture(target: target, lines: 500)
        else { return nil }
        var text = capture.text ?? ""
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: History

    /// Scrolling goes through the server, which picks what the pane needs:
    /// tmux's copy-mode for a shell, PgUp/PgDn or the wheel for a full-screen
    /// TUI. Left to the terminal, a drag over Claude's TUI became arrow keys —
    /// its prompt history, not its output.
    func scroll(lines: Int) {
        guard lines != 0, !target.isEmpty else { return }
        pendingScroll += lines
        if lines < 0 { scrolledBack = true }
        pumpScroll()
    }

    func page(up: Bool) {
        let step = max(5, rows - 2)
        scroll(lines: up ? -step : step)
    }

    func backToLive() {
        pendingScroll = 0
        scrolledBack = false
        guard !target.isEmpty else { return }
        let pane = target
        Task { [api] in try? await api.scroll(target: pane, direction: "bottom", lines: 1) }
    }

    private func pumpScroll() {
        guard !scrollInFlight, pendingScroll != 0, !target.isEmpty else { return }
        let amount = pendingScroll
        pendingScroll = 0
        scrollInFlight = true
        let pane = target
        Task { [weak self] in
            guard let self else { return }
            try? await self.api.scroll(target: pane, direction: amount < 0 ? "up" : "down", lines: min(80, abs(amount)))
            self.scrollInFlight = false
            self.pumpScroll()
        }
    }

    private var cellHeight: CGFloat {
        let rows = max(1, terminalView.getTerminal().rows)
        return max(8, terminalView.bounds.height / CGFloat(rows))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !terminalView.hasActiveSelection else {
            panRemainder = 0
            return
        }
        switch gesture.state {
        case .began:
            panRemainder = 0
        case .changed:
            panRemainder += gesture.translation(in: terminalView).y
            gesture.setTranslation(.zero, in: terminalView)
            let lines = Int(panRemainder / cellHeight)
            if lines != 0 {
                panRemainder -= CGFloat(lines) * cellHeight
                scroll(lines: -lines)
            }
        case .ended:
            let velocity = gesture.velocity(in: terminalView).y
            if abs(velocity) > 900 {
                let fling = Int((velocity / 300).rounded())
                scroll(lines: -max(-30, min(30, fling)))
            }
            panRemainder = 0
        default:
            panRemainder = 0
        }
    }
}

extension TerminalController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension TerminalController: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let text = String(decoding: data, as: UTF8.self)
        MainActor.assumeIsolated {
            // Nobody asked, with no client attached; the next attach asks again.
            if self.streamID.isEmpty && Self.isTerminalReply(text) { return }
            if self.controlArmed && !Self.isTerminalReply(text) { self.controlArmed = false }
            self.sendInput(text)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { self.resized(cols: newCols, rows: newRows) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { Clipboard.copy(text) }
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Holds the terminal at the bottom of the space it is given, and keeps the
/// grid the size it had without the keyboard while the keyboard is up.
///
/// A new height is a new tmux attach and a full redraw, every time the
/// keyboard came or went. Instead the grid slides up behind the top edge, so
/// the prompt at the bottom stays above the keyboard.
final class TerminalHostView: UIView {
    let terminal: TerminalView
    /// After each pass, with the grid already resized to the new frame.
    var onLayout: (() -> Void)?
    /// With the height already held, so what the screen adds in answer
    /// lands while the grid keeps its size.
    var onKeyboardChange: ((Bool) -> Void)?
    /// Whether the terminal is in a window — on screen, as SwiftUI's appear
    /// and disappear calls for the task screen on iPhone are not reliably.
    var onWindowChange: ((Bool) -> Void)?
    /// Set while the terminal has the keyboard. The bars under the terminal
    /// change the moment it takes focus, before the keyboard says anything.
    var holdsHeight = false {
        didSet {
            if oldValue && !holdsHeight { setNeedsLayout() }
        }
    }
    private var keyboardVisible = false
    private var settledHeight: CGFloat = 0
    private var settledWidth: CGFloat = 0

    private var holding: Bool { keyboardVisible || holdsHeight }

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = LoomColors.uiColor(TerminalTheme.background)
        addSubview(terminal)
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !holding || settledHeight == 0 || bounds.width != settledWidth {
            settledHeight = bounds.height
            settledWidth = bounds.width
        }
        let height = holding ? settledHeight : bounds.height
        let frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        if terminal.frame != frame { terminal.frame = frame }
        // SwiftTerm resizes its grid in its own layout pass; run it now, so
        // the size read after this is the one on screen.
        terminal.layoutIfNeeded()
        onLayout?()
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let bottom = window?.windowScene?.screen.bounds.maxY ?? .greatestFiniteMagnitude
        // A hardware keyboard leaves only a slim bar on screen, nothing to
        // make room for.
        let visible = end.height > 120 && end.minY < bottom - 1
        guard visible != keyboardVisible else { return }
        keyboardVisible = visible
        if !visible { setNeedsLayout() }
        onKeyboardChange?(visible)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        let changed = keyboardVisible
        keyboardVisible = false
        setNeedsLayout()
        if changed { onKeyboardChange?(false) }
    }
}

/// SwiftTerm's view, saying when it takes the keyboard and when it lets go.
final class LoomTerminalView: TerminalView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Drops the sequences that turn mouse reporting on, as the web console's
/// terminal does. Kept, they would turn a touch into a click sent to the
/// agent's TUI. A sequence split across two chunks is held for the next.
struct MouseModeFilter {
    private static let modes: Set<Int> = [1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016]
    private var carry: [UInt8] = []

    mutating func reset() { carry.removeAll() }

    mutating func filter(_ chunk: Data) -> [UInt8] {
        let bytes = carry + [UInt8](chunk)
        carry.removeAll(keepingCapacity: true)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            guard byte == 0x1B else {
                out.append(byte)
                i += 1
                continue
            }
            let rest = bytes.count - i
            if rest < 3 {
                if rest == 1 || bytes[i + 1] == 0x5B {
                    carry = Array(bytes[i...])
                    break
                }
                out.append(byte)
                i += 1
                continue
            }
            guard bytes[i + 1] == 0x5B, bytes[i + 2] == 0x3F else {
                out.append(byte)
                i += 1
                continue
            }
            var j = i + 3
            while j < bytes.count, bytes[j] == 0x3B || (0x30...0x39).contains(bytes[j]) { j += 1 }
            if j == bytes.count {
                if j - i < 32 {
                    carry = Array(bytes[i...])
                    break
                }
                out.append(byte)
                i += 1
                continue
            }
            if bytes[j] == 0x68 || bytes[j] == 0x6C {
                let params = String(decoding: bytes[(i + 3)..<j], as: UTF8.self)
                    .split(separator: ";")
                    .compactMap { Int($0) }
                if !params.isEmpty, params.allSatisfy(Self.modes.contains) {
                    i = j + 1
                    continue
                }
            }
            out.append(byte)
            i += 1
        }
        return out
    }
}

/// Chunked reader for the pty stream; callbacks land on the main queue.
private final class PtyStreamDelegate: NSObject, URLSessionDataDelegate {
    private let onResponse: (HTTPURLResponse) -> Void
    private let onChunk: (Data) -> Void
    private let onComplete: (Error?) -> Void

    init(
        onResponse: @escaping (HTTPURLResponse) -> Void,
        onChunk: @escaping (Data) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        self.onResponse = onResponse
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse { onResponse(http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error)
    }
}
