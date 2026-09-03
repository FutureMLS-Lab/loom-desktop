import AppKit
import SwiftUI
import WebKit

/// The agent's pane, rendered by xterm — the same terminal the Loom web
/// console uses, with the same theme.
///
/// The previous implementation polled `capture-pane` and drew the result as
/// plain text. That threw away everything a terminal is: colour, the cursor,
/// and the pane's own width. Claude's TUI is drawn for a specific column
/// count, so a capture from a 299-column pane displayed in an 88-column view
/// arrives as wrapped soup.
///
/// Attaching to the pty instead fixes all three at once. The stream carries
/// raw bytes, tmux sizes the pane to the columns we ask for, and keystrokes
/// go back as the bytes a terminal actually sends.
@MainActor
final class TerminalSession: NSObject, ObservableObject {
    /// One terminal for the app, reused as you move between tasks and tabs.
    ///
    /// Building it is not cheap — measured at 270ms to create the web view and
    /// parse xterm — and only one terminal is ever on screen. Rebuilding it per
    /// task meant paying that on every switch, which is precisely the stutter
    /// you feel when moving around. Switching now only changes `target`, which
    /// costs a reattach and no page load.
    static let shared = TerminalSession()

    @Published private(set) var connected = false
    @Published private(set) var error = ""
    /// The size this client asked tmux for. Worth showing, because the session
    /// is set to `window-size smallest`: every attached client — other browser
    /// tabs, a terminal running `tmux attach` — shrinks the pane for everyone,
    /// and the symptom is a small screen adrift in a large window with no
    /// indication of why.
    @Published private(set) var paneSize = ""

    /// Bumped by the pane to re-attach after a Start/Stop.
    var target = "" {
        didSet { if target != oldValue { restart() } }
    }

    /// Which task's pane is currently showing this terminal.
    private(set) var owner = ""

    /// Take over the terminal for a task. Switching tasks reuses the same web
    /// view, so this replaces `target` rather than building anything.
    func adopt(owner: String, target: String) {
        self.owner = owner
        if self.target == target {
            // Same pane as before, coming back after a detach.
            if ready, streamTask == nil { restart() }
        } else {
            self.target = target
        }
    }

    /// Give it up, but only if this task is still the one holding it. SwiftUI
    /// brings the next view on screen before retiring the last, so an
    /// unconditional stop here would kill the stream the new task just began.
    func release(owner: String) {
        guard self.owner == owner else { return }
        self.owner = ""
        stop()
    }

    /// What the page is first built with. It has to match the stored default
    /// the pane pushes on appear: differ, and which one you saw depended on
    /// whether the web view or the view's `onAppear` ran first, at the cost of
    /// a re-fit and a tmux resize on every launch.
    static let defaultFontSize: Double = 14

    var fontSize: Double = TerminalSession.defaultFontSize {
        didSet {
            guard fontSize != oldValue else { return }
            call("window.__loomFontSize(\(fontSize))")
        }
    }

    private(set) lazy var webView: WKWebView = makeWebView()

    /// ⌘F with the pane focused. The pane has no find of its own, but the
    /// plan under it does; the tab points this at the plan's find bar while
    /// it is on screen, so the shortcut lands somewhere useful instead of
    /// dying in the terminal.
    var onFindRequested: (() -> Void)? {
        get { (webView as? TerminalWebViewHost)?.onFindRequested }
        set { (webView as? TerminalWebViewHost)?.onFindRequested = newValue }
    }
    private var streamTask: URLSessionDataTask?
    private var streamSession: URLSession?
    private(set) var streamID = ""
    private var cols = 80
    private var rows = 24
    private var ready = false
    /// Bytes arrive faster than it is worth crossing into JavaScript for, so
    /// they are batched and flushed on a display-rate timer.
    private var pending = Data()
    private var flushTimer: Timer?
    private var reattach: Task<Void, Never>?
    /// Signed pending scroll, negative for older output.
    private var pendingScroll = 0
    private var scrollInFlight = false
    private var inputQueue = ""
    private var inputInFlight = false
    /// Which attachment a callback belongs to.
    ///
    /// Cancelling a `URLSession` task is not instant: chunks already in flight
    /// still arrive, and a completion still fires. After switching task that
    /// meant the previous pane's last bytes being painted into the terminal
    /// just reset for the new one — two agents' screens at once — and its
    /// completion clearing the bookkeeping for the attachment that had
    /// replaced it, which let a second one start alongside.
    private var streamGeneration = 0
    /// The pane the wheel last pushed into tmux's copy-mode, tracked per pane
    /// so returning to a different task does not scroll the wrong one.
    private var scrolledBackPane = ""
    private var reconnect: Task<Void, Never>?
    private var reconnectStreak = 0

    private let api = LoomAPI()

    /// Every live session, so quitting can close its stream. The server ends
    /// the `tmux attach` when the HTTP connection closes; if the app is killed
    /// outright that close can be missed, and the orphaned client keeps
    /// constraining the pane's size for everyone else until it is reaped.
    private static let live = NSHashTable<TerminalSession>.weakObjects()

    static var liveSessions: [TerminalSession] { live.allObjects }

    /// Quitting. The close has to go out before the process does, so it is
    /// sent and waited on rather than handed to a task that will not survive.
    static func stopAll() {
        let api = LoomAPI()
        for session in live.allObjects {
            let id = session.streamID
            session.stop()
            if !id.isEmpty { api.closeStreamNow(streamId: id) }
        }
    }

    override init() {
        super.init()
        Self.live.add(self)
        NotificationCenter.default.addObserver(
            forName: LoomSettings.serverDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // The stream, and the pane it names, belong to the Loom we
                // just left.
                self?.owner = ""
                self?.target = ""
                self?.stop()
                self?.call("window.__loomReset()")
            }
        }
    }

    /// A stream stays open for as long as the pane is on screen, so it cannot
    /// use the short timeouts the request/response API wants.
    private static var streamConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 86_400
        config.networkServiceType = .responsiveData
        return config
    }

    deinit {
        streamTask?.cancel()
        streamSession?.invalidateAndCancel()
        reattach?.cancel()
        flushTimer?.invalidate()
    }

    // MARK: Lifecycle

    func stop() {
        // Tell the server first: cancelling the request only closes our leg of
        // it, and the gateway keeps its own open, so without this the attach
        // behind this stream survives — one left behind per terminal opened.
        if !streamID.isEmpty {
            let id = streamID
            Task { [api] in try? await api.closeStream(streamId: id) }
        }
        streamGeneration &+= 1
        streamTask?.cancel()
        streamTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        reattach?.cancel()
        reattach = nil
        reconnect?.cancel()
        reconnect = nil
        flushTimer?.invalidate()
        flushTimer = nil
        pending.removeAll(keepingCapacity: false)
        // Keys typed at a stream that is going away belong to nothing.
        inputQueue.removeAll()
        streamID = ""
        connected = false
    }

    func restart() {
        stop()
        guard ready, !target.isEmpty else { return }
        call("window.__loomReset()")
        attach()
        // Coming back to a pane left in copy-mode: show the agent where it
        // is now, not where the wheel left it.
        Task { [weak self] in await self?.returnToPrompt() }
    }

    /// Back to the live screen, from however far back the wheel went.
    ///
    /// Both halves are needed: the page's own viewport, and the pane's
    /// copy-mode, which is what the wheel actually moves and which nothing
    /// else here would clear while you are only reading.
    func scrollToBottom() {
        call("window.__loomBottom()")
        Task { [weak self] in await self?.returnToPrompt(force: true) }
    }

    /// Re-measure and re-attach at this window's size.
    ///
    /// Worth having as something you can ask for: tmux keeps a window at the
    /// size of the smallest client that was ever attached, and does not grow
    /// back when that client leaves. So opening a task once in a small window
    /// leaves the agent on a small screen afterwards, with nothing attached to
    /// explain why.
    func refit() {
        call("window.__loomRefit()")
    }

    /// Compose-box text, which is a paste rather than keystrokes.
    func paste(_ text: String, submit: Bool) {
        guard !text.isEmpty, !target.isEmpty else { return }
        let pane = target
        // `send-text` leaves copy-mode server-side, so the pane is at the
        // prompt again whether or not the wheel had moved it.
        if scrolledBackPane == pane { scrolledBackPane = "" }
        Task { [api] in
            try? await api.sendText(target: pane, text: text, submit: submit)
        }
    }

    func copySelection() {
        guard ready else { return }
        webView.evaluateJavaScript("window.__loomSelection()") { value, _ in
            guard let text = value as? String, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Keys a terminal sends as bytes. With a pty there is no key-name table to
    /// get wrong — `\u{7F}` really is backspace.
    func send(_ text: String) {
        guard !text.isEmpty else { return }
        inputQueue += text
        pumpInput()
    }

    /// One request at a time, in order, like the wheel below.
    ///
    /// Every keystroke used to be its own request to a gateway a further
    /// 150ms away, with nothing holding them in sequence: type quickly and
    /// the characters could arrive shuffled. Queueing also means a burst
    /// crosses in one request instead of one per key.
    private func pumpInput() {
        guard !inputInFlight, !inputQueue.isEmpty, !streamID.isEmpty else { return }
        let chunk = inputQueue
        let id = streamID
        inputQueue = ""
        inputInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.returnToPrompt()
            try? await self.api.streamInput(streamId: id, text: chunk)
            self.inputInFlight = false
            self.pumpInput()
        }
    }

    /// Bring the pane back to the live prompt, out of tmux's copy-mode.
    ///
    /// The wheel scrolls by putting the pane into copy-mode, and it stays
    /// there: tmux then takes keys as copy-mode commands instead of passing
    /// them to the agent, so after scrolling up the caret never returns to
    /// the prompt — and leaving the tab and coming back does not clear it,
    /// because the mode belongs to the pane, not to us. The server enters
    /// copy-mode with `copy-mode -e`, which exits on reaching the bottom, so
    /// scrolling down past it is the way out.
    private func returnToPrompt(force: Bool = false) async {
        guard force || scrolledBackPane == target, !target.isEmpty else { return }
        scrolledBackPane = ""
        pendingScroll = 0
        try? await api.scroll(target: target, direction: "down", lines: 80)
    }

    /// Delivered in chunks by a delegate rather than pulled a byte at a time
    /// through `URLSession.bytes`. A screen redraw is tens of kilobytes, and
    /// one async iteration per byte is tens of thousands of hops for a single
    /// frame of output — which is felt most while scrolling, since that is
    /// exactly when the app repaints everything.
    private func attach() {
        // One stream at a time, always. Two would both feed the same terminal,
        // so every byte the agent wrote would be rendered twice — typing and
        // backspace would each appear to happen more than once.
        guard streamTask == nil else { return }
        guard let request = api.streamRequest(target: target, cols: cols, rows: rows) else { return }
        streamGeneration &+= 1
        let generation = streamGeneration
        let delegate = PtyStreamDelegate(
            onResponse: { [weak self] http in
                guard let self, generation == self.streamGeneration else { return }
                guard http.statusCode == 200 else {
                    self.error = "Pane unavailable (\(http.statusCode))"
                    self.connected = false
                    return
                }
                self.streamID = http.value(forHTTPHeaderField: "X-Loom-Terminal-Stream") ?? ""
                // Clear the screen here, not before attaching. Anything the
                // previous pane managed to deliver in between is wiped by
                // this, and tmux's opening redraw lands on an empty screen —
                // without it a switch could leave a line of the last agent's
                // footer under the new one's.
                self.call("window.__loomReset()")
                self.connected = true
                self.error = ""
                self.reconnectStreak = 0
                self.startFlushing()
            },
            onChunk: { [weak self] data in
                guard let self, generation == self.streamGeneration else { return }
                // Only a stream that was accepted feeds the screen. A non-200
                // body is JSON saying why the pane is unavailable, not pty
                // bytes; the toolbar already carries that message, and left in
                // the buffer it was painted into the terminal as junk the
                // moment a flush ran.
                guard self.connected else { return }
                self.pending.append(data)
                self.startFlushing()
            },
            onComplete: { [weak self] failure in
                guard let self, generation == self.streamGeneration else { return }
                // Let go of the finished stream. `attach()` refuses to start a
                // second one while this is set, so leaving it behind made the
                // reconnect below a no-op: one drop and the terminal stayed
                // dead until the tab was reopened. It also strands the
                // session, which holds its delegate until invalidated.
                self.streamTask = nil
                self.streamSession?.finishTasksAndInvalidate()
                self.streamSession = nil
                self.connected = false
                let cancelled = (failure as NSError?)?.code == NSURLErrorCancelled
                if let failure, !cancelled {
                    self.error = failure.localizedDescription
                }
                // A stream that ends on its own — the server restarted, the
                // network dropped, the pane died — used to leave a dead
                // terminal until the tab was reopened. Reconnect, backing off
                // so an outage is waited out rather than hammered.
                if !cancelled { self.scheduleReconnect() }
            }
        )
        let session = URLSession(
            configuration: Self.streamConfiguration,
            delegate: delegate,
            delegateQueue: .main
        )
        streamSession = session
        let task = session.dataTask(with: request)
        streamTask = task
        task.resume()
    }

    // MARK: Feeding xterm

    /// Runs only while there are bytes to hand over. Left running it is sixty
    /// wakeups a second finding nothing, for a pane that spends most of every
    /// session sitting at a prompt; the first chunk to arrive starts it again.
    private func startFlushing() {
        guard flushTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        // Display-rate output does not need wall-clock precision; let the
        // system coalesce the wakeups it can.
        timer.tolerance = 1.0 / 120.0
        flushTimer = timer
    }

    private func flush() {
        guard ready else { return }
        guard !pending.isEmpty else {
            flushTimer?.invalidate()
            flushTimer = nil
            return
        }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        call("window.__loomWrite('\(chunk.base64EncodedString())')")
    }

    private func call(_ javaScript: String) {
        guard ready else { return }
        webView.evaluateJavaScript(javaScript, completionHandler: nil)
    }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let web = TerminalWebViewHost(frame: .zero, configuration: config)
        // Through a proxy, because a content controller retains its message
        // handlers: registering `self` here would close a loop back through
        // the web view this session owns, and the session — with its open
        // stream — would never be released.
        controller.add(
            ScriptMessageProxy { [weak self] message in
                MainActor.assumeIsolated { self?.handle(message) }
            },
            name: "loom"
        )
        web.navigationDelegate = self
        #if DEBUG
        if #available(macOS 13.3, *) { web.isInspectable = true }
        #endif
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(Self.page(fontSize: fontSize), baseURL: nil)
        return web
    }

    private static func asset(_ name: String, _ ext: String) -> String {
        LoomResource.text(name, ext) ?? ""
    }

    /// The web console's terminal, verbatim: same theme, same font stack, same
    /// scrollback. Claude's TUI assumes a dark terminal, so bright text needs
    /// a dark ground to stay readable — hence a dark ground rather than the
    /// parchment the rest of the app uses. Keep these colours in step with
    /// `TerminalTheme`, which paints the card around this page.
    private static func page(fontSize: Double) -> String {
        guard let page = LoomResource.text("terminal", "html") else {
            return "<!doctype html><html><body></body></html>"
        }
        // xterm and its fit addon are inlined rather than linked: the page is
        // loaded from a string with no base URL, so it has no origin to
        // resolve a relative script against.
        return page
            .replacingOccurrences(of: "__LOOM_FONT_SIZE__", with: String(Int(fontSize)))
            .replacingOccurrences(of: "/*xterm.css*/", with: asset("xterm", "css"))
            .replacingOccurrences(of: "/*xterm.js*/", with: asset("xterm", "js"))
            .replacingOccurrences(of: "/*addon-fit.js*/", with: asset("addon-fit", "js"))
    }
}

extension TerminalSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.ready = true
            self.restart()
        }
    }
}

/// The pane's web view, which answers Edit ▸ Find by handing it on. A plain
/// WKWebView takes the menu's ⌘F — the responder chain stops at it — and
/// does nothing with it, so the shortcut was dead whenever the pane had
/// focus, which while reading a task it almost always does.
final class TerminalWebViewHost: WKWebView {
    var onFindRequested: (() -> Void)?

    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .showFindInterface, .showReplaceInterface:
            onFindRequested?()
        default:
            break
        }
    }
}

/// Forwards script messages without retaining their handler.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let onMessage: (WKScriptMessage) -> Void

    init(_ onMessage: @escaping (WKScriptMessage) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onMessage(message)
    }
}

extension TerminalSession {
    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }
        Task { @MainActor in
            switch type {
            case "input":
                if let data = body["data"] as? String { self.send(data) }
            case "ready", "resize":
                let cols = (body["cols"] as? Int) ?? self.cols
                let rows = (body["rows"] as? Int) ?? self.rows
                self.resize(cols: cols, rows: rows)
            case "scroll":
                let dir = (body["dir"] as? String) ?? "up"
                let lines = (body["lines"] as? Int) ?? 3
                self.scrollPane(direction: dir, lines: lines)
            default:
                break
            }
        }
    }

    /// Wait longer each time, to a minute. Attaching costs the server a pty
    /// and a `tmux attach`, so retrying hard at a server that is struggling is
    /// the worst thing a client can do.
    private func scheduleReconnect() {
        guard !target.isEmpty, reconnect == nil else { return }
        reconnectStreak += 1
        let delay = min(pow(2.0, Double(min(reconnectStreak, 5))), 60)
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnect = nil
            guard self.ready, !self.target.isEmpty, !self.connected else { return }
            self.attach()
        }
    }

    private func scrollPane(direction: String, lines: Int) {
        pendingScroll += direction == "up" ? -lines : lines
        if direction == "up" { scrolledBackPane = target }
        pumpScroll()
    }

    /// One request at a time. The gateway is remote — a round trip is around
    /// 150ms — so a flick that fires them in parallel gets them applied out of
    /// order, and the pane jumps back and forth. Holding a single request in
    /// flight and folding everything that arrives meanwhile into the next one
    /// scrolls as fast as the link allows, in order, and starts immediately
    /// rather than after a fixed delay.
    private func pumpScroll() {
        guard !scrollInFlight, pendingScroll != 0, !target.isEmpty else { return }
        let amount = pendingScroll
        pendingScroll = 0
        scrollInFlight = true
        let pane = target
        Task { [weak self] in
            guard let self else { return }
            try? await self.api.scroll(
                target: pane,
                direction: amount < 0 ? "up" : "down",
                lines: min(80, abs(amount))
            )
            self.scrollInFlight = false
            self.pumpScroll()
        }
    }

    /// tmux resizes the pane to the client, so a new size means a new
    /// attachment. Debounced, because a drag reports every step.
    private func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != self.cols || rows != self.rows || streamTask == nil else { return }
        self.cols = cols
        self.rows = rows
        paneSize = "\(cols)×\(rows)"
        reattach?.cancel()
        reattach = Task { [weak self] in
            // Each attachment is a `tmux attach` process on the server, and
            // one that fails to be torn down sticks around holding the pane's
            // size. Worth waiting out a resize rather than spawning one per
            // step of it.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.stop()
            self.attach()
        }
    }
}

/// Chunked reader for the pty stream. Callbacks land on the main queue, which
/// is where the buffer they feed is read.
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

/// Hosts the terminal's web view. The view is owned by the session so it
/// survives SwiftUI rebuilding this struct.
struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}

extension TerminalSession {
    /// Dev hook: print what the terminal is actually showing.
    ///
    /// A screenshot cannot answer this. xterm draws into a canvas, and a
    /// canvas comes back blank from `WKWebView.takeSnapshot`, so in a captured
    /// window the pane is an empty rectangle whether it is working or not.
    @MainActor func dumpVisibleText() {
        webView.evaluateJavaScript(Self.dumpScript) { value, _ in
            NSLog("loom terminal [\(self.target)]: \(value as? String ?? "unavailable")")
        }
    }

    private static let dumpScript = """
    (function () {
      var t = window.__loomTerm;
      if (!t) { return 'no terminal'; }
      var buffer = t.buffer.active;
      var lines = [];
      for (var i = 0; i < buffer.length; i++) {
        var line = buffer.getLine(i);
        if (!line) { continue; }
        var text = line.translateToString(true).replace(/\\s+$/, '');
        if (text) { lines.push(text); }
      }
      return t.cols + 'x' + t.rows + ', ' + lines.length + ' non-empty rows\\n' + lines.join('\\n');
    })()
    """
}
