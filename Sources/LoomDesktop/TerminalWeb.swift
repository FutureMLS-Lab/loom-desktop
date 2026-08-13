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

    var fontSize: Double = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            call("window.__loomFontSize(\(fontSize))")
        }
    }

    private(set) lazy var webView: WKWebView = makeWebView()
    private var streamTask: URLSessionDataTask?
    private var streamSession: URLSession?
    private var streamID = ""
    private var cols = 80
    private var rows = 24
    private var ready = false
    /// Bytes arrive faster than it is worth crossing into JavaScript for, so
    /// they are batched and flushed on a display-rate timer.
    private var pending = Data()
    private var flushTimer: Timer?
    private var reattach: Task<Void, Never>?
    private var pendingScroll = 0
    private var scrollInFlight = false
    private var inputQueue = ""
    private var inputInFlight = false
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

    static func stopAll() {
        for session in live.allObjects { session.stop() }
    }

    override init() {
        super.init()
        Self.live.add(self)
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

    func scrollToBottom() {
        call("window.__loomBottom()")
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
    private func returnToPrompt() async {
        guard scrolledBackPane == target, !target.isEmpty else { return }
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
        let delegate = PtyStreamDelegate(
            onResponse: { [weak self] http in
                guard let self else { return }
                guard http.statusCode == 200 else {
                    self.error = "Pane unavailable (\(http.statusCode))"
                    self.connected = false
                    return
                }
                self.streamID = http.value(forHTTPHeaderField: "X-Loom-Terminal-Stream") ?? ""
                self.connected = true
                self.error = ""
                self.reconnectStreak = 0
                self.startFlushing()
            },
            onChunk: { [weak self] data in
                self?.pending.append(data)
            },
            onComplete: { [weak self] failure in
                guard let self else { return }
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

    private func startFlushing() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        guard !pending.isEmpty, ready else { return }
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
        let web = WKWebView(frame: .zero, configuration: config)
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
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).\(ext)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(name).\(ext)"),
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    /// The web console's terminal, verbatim: same theme, same font stack, same
    /// scrollback. Claude's TUI assumes a dark terminal, so bright text needs
    /// a dark ground to stay readable — hence warm charcoal rather than the
    /// parchment the rest of the app uses.
    private static func page(fontSize: Double) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"/>
        <style>\(asset("xterm", "css"))</style>
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #211d1a; overflow: hidden; }
          #host { position: absolute; inset: 0; padding: 8px 10px; background: #211d1a; }
          #host .xterm { height: 100%; padding: 0; }
          #host .xterm-viewport { background-color: transparent !important; }
          #host .xterm-viewport::-webkit-scrollbar { width: 10px; }
          #host .xterm-viewport::-webkit-scrollbar-thumb {
            background: rgba(120, 90, 40, 0.28); border-radius: 6px;
          }
          .composition-view {
            background: #fffaf0; color: #4a4036;
            border: 1px solid #d9a441; border-radius: 4px; padding: 0 3px; z-index: 10;
          }
        </style>
        </head><body><div id="host"></div>
        <script>\(asset("xterm", "js"))</script>
        <script>\(asset("addon-fit", "js"))</script>
        <script>
        var term = new Terminal({
          fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
          fontSize: \(Int(fontSize)),
          lineHeight: 1.15,
          cursorBlink: true,
          cursorInactiveStyle: 'outline',
          macOptionIsMeta: true,
          scrollback: 8000,
          theme: {
            background: '#211d1a', foreground: '#e7ddcf',
            cursor: '#f59e0b', cursorAccent: '#211d1a',
            selectionBackground: 'rgba(245,158,11,0.30)',
            black: '#2b2620', red: '#e06c5a', green: '#9ec46a', yellow: '#e0af68',
            blue: '#7aa2f7', magenta: '#c79bf0', cyan: '#79c7c7', white: '#d8cfc2',
            brightBlack: '#7a6f60', brightRed: '#f08a7a', brightGreen: '#b6d98a',
            brightYellow: '#f0c987', brightBlue: '#9bb8fa', brightMagenta: '#d4b3f5',
            brightCyan: '#9bd9d9', brightWhite: '#fdf6ea',
          },
        });
        var fit = null;
        try { fit = new FitAddon.FitAddon(); term.loadAddon(fit); } catch (e) {}
        var host = document.getElementById('host');
        term.open(host);

        function post(msg) {
          try { window.webkit.messageHandlers.loom.postMessage(msg); } catch (e) {}
        }
        term.onData(function (data) { post({ type: 'input', data: data }); });

        var lastCols = 0, lastRows = 0;
        function doFit() {
          if (!fit) return;
          // Never report a size measured mid-layout. tmux sizes the window to
          // its smallest client, so a fleeting "20 rows" while this view is
          // still settling squeezes the pane for everyone attached — and the
          // agent reflows its screen to match, which outlasts the client that
          // caused it.
          if (host.clientWidth < 120 || host.clientHeight < 120) {
            setTimeout(doFit, 100);
            return;
          }
          try { fit.fit(); } catch (e) { return; }
          if (term.cols !== lastCols || term.rows !== lastRows) {
            lastCols = term.cols; lastRows = term.rows;
            post({ type: 'resize', cols: term.cols, rows: term.rows });
          }
        }

        // Scrolling is local whenever it can be. On the normal screen the
        // history is right here in xterm's buffer, so the wheel is left alone
        // and moves instantly.
        //
        // A full-screen app is the exception: its history lives in the app,
        // not in any buffer we hold, and xterm would translate the wheel into
        // arrow keys — which a TUI reads as "previous prompt" rather than
        // "scroll up". There the wheel is intercepted and tmux does the
        // scrolling, which costs a round trip. Deltas are batched per frame,
        // and Swift keeps only one request in flight, because a flick that
        // fires a dozen overlapping requests arrives out of order and judders.
        var scrollAccum = 0, scrollFrame = null;
        host.addEventListener('wheel', function (e) {
          if (term.buffer.active.type !== 'alternate') return;
          e.preventDefault();
          e.stopPropagation();
          scrollAccum += (e.deltaMode === 1 ? e.deltaY * 18 : e.deltaY);
          if (scrollFrame) return;
          scrollFrame = requestAnimationFrame(function () {
            var total = scrollAccum;
            scrollAccum = 0;
            scrollFrame = null;
            if (!total) return;
            post({
              type: 'scroll',
              dir: total < 0 ? 'up' : 'down',
              lines: Math.max(1, Math.min(80, Math.round(Math.abs(total) / 24))),
            });
          });
        }, { passive: false, capture: true });
        var fitTimer = null;
        window.addEventListener('resize', function () {
          if (fitTimer) clearTimeout(fitTimer);
          fitTimer = setTimeout(doFit, 90);
        });

        // Drop the sequences that turn on mouse reporting, so the app cannot
        // take the pointer: with it on, xterm forwards clicks and drags to the
        // app and text can no longer be selected. Only sequences whose
        // parameters are *all* mouse modes are removed, and nothing is
        // buffered across chunks, so this cannot corrupt other escapes. One
        // split across two reads slips through and self-heals on the next
        // redraw. The trade is that clicks do not reach the app.
        var MOUSE_MODES = [1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016];
        function stripMouseModes(u8) {
          if (!u8 || u8.length < 4) return u8;
          var hit = false;
          for (var k = 0; k + 3 < u8.length; k++) {
            if (u8[k] === 0x1b && u8[k + 1] === 0x5b && u8[k + 2] === 0x3f) { hit = true; break; }
          }
          if (!hit) return u8;
          var n = u8.length, out = new Uint8Array(n), w = 0, i = 0;
          while (i < n) {
            if (i + 3 < n && u8[i] === 0x1b && u8[i + 1] === 0x5b && u8[i + 2] === 0x3f) {
              var j = i + 3, params = '';
              while (j < n && ((u8[j] >= 0x30 && u8[j] <= 0x39) || u8[j] === 0x3b)) {
                params += String.fromCharCode(u8[j]); j++;
              }
              if (j < n && (u8[j] === 0x68 || u8[j] === 0x6c)) {
                var nums = params.split(';').filter(Boolean).map(Number);
                if (nums.length && nums.every(function (x) { return MOUSE_MODES.indexOf(x) >= 0; })) {
                  i = j + 1;
                  continue;
                }
              }
            }
            out[w++] = u8[i++];
          }
          return out.subarray(0, w);
        }

        window.__loomWrite = function (b64) {
          var raw = atob(b64);
          var bytes = new Uint8Array(raw.length);
          for (var i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }
          term.write(stripMouseModes(bytes));
        };
        window.__loomTerm = term;
        window.__loomReset = function () { try { term.reset(); } catch (e) {} };
        window.__loomFocus = function () { try { term.focus(); } catch (e) {} };
        window.__loomFontSize = function (n) {
          term.options.fontSize = n;
          doFit();
        };
        // Force a measurement even if the grid works out the same, so the pane
        // can be re-sized to this window after something else shrank it.
        window.__loomRefit = function () {
          lastCols = 0;
          lastRows = 0;
          doFit();
        };
        window.__loomSelection = function () { return term.getSelection() || ''; };
        window.__loomBottom = function () { try { term.scrollToBottom(); } catch (e) {} };

        doFit();
        post({ type: 'ready', cols: term.cols, rows: term.rows });
        </script></body></html>
        """
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

    /// Signed pending scroll, negative for older output.
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
