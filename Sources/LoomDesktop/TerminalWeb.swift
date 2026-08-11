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

    private let api = LoomAPI()

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
        flushTimer?.invalidate()
        flushTimer = nil
        pending.removeAll(keepingCapacity: false)
        streamID = ""
        connected = false
    }

    func restart() {
        stop()
        guard ready, !target.isEmpty else { return }
        call("window.__loomReset()")
        attach()
    }

    func focusTerminal() {
        call("window.__loomFocus()")
    }

    func scrollToBottom() {
        call("window.__loomBottom()")
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
        Task { [weak self] in
            guard let self else { return }
            let id = self.streamID
            guard !id.isEmpty else { return }
            try? await self.api.streamInput(streamId: id, text: text)
        }
    }

    /// Delivered in chunks by a delegate rather than pulled a byte at a time
    /// through `URLSession.bytes`. A screen redraw is tens of kilobytes, and
    /// one async iteration per byte is tens of thousands of hops for a single
    /// frame of output — which is felt most while scrolling, since that is
    /// exactly when the app repaints everything.
    private func attach() {
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
                self.startFlushing()
            },
            onChunk: { [weak self] data in
                self?.pending.append(data)
            },
            onComplete: { [weak self] failure in
                guard let self else { return }
                self.connected = false
                if let failure, (failure as NSError).code != NSURLErrorCancelled {
                    self.error = failure.localizedDescription
                }
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
        controller.add(self, name: "loom")
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
          // Fitting before the view has a width would pin the real tmux pane
          // to a couple of dozen columns — for every client, not just this one.
          if (host.clientWidth < 120) { setTimeout(doFit, 100); return; }
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
        window.__loomReset = function () { try { term.reset(); } catch (e) {} };
        window.__loomFocus = function () { try { term.focus(); } catch (e) {} };
        window.__loomFontSize = function (n) {
          term.options.fontSize = n;
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

extension TerminalSession: WKScriptMessageHandler {
    @MainActor
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
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
    private func scrollPane(direction: String, lines: Int) {
        pendingScroll += direction == "up" ? -lines : lines
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
            try? await Task.sleep(nanoseconds: 250_000_000)
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
