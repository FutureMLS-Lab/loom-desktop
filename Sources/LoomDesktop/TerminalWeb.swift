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
    private var streamTask: Task<Void, Never>?
    private var streamID = ""
    private var cols = 80
    private var rows = 24
    private var ready = false
    /// Bytes arrive faster than it is worth crossing into JavaScript for, so
    /// they are batched and flushed on a display-rate timer.
    private var pending = Data()
    private var flushTimer: Timer?
    private var reattach: Task<Void, Never>?

    private let api = LoomAPI()

    /// A stream stays open for as long as the pane is on screen, so it cannot
    /// use the short timeouts the request/response API wants.
    private static let streamSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 86_400
        config.networkServiceType = .responsiveData
        return URLSession(configuration: config)
    }()

    deinit {
        streamTask?.cancel()
        reattach?.cancel()
        flushTimer?.invalidate()
    }

    // MARK: Lifecycle

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        reattach?.cancel()
        reattach = nil
        flushTimer?.invalidate()
        flushTimer = nil
        streamID = ""
        connected = false
    }

    func restart() {
        stop()
        guard ready, !target.isEmpty else { return }
        call("window.__loomReset()")
        streamTask = Task { [weak self] in await self?.attach() }
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

    private func attach() async {
        guard let request = api.streamRequest(target: target, cols: cols, rows: rows) else { return }
        do {
            let (bytes, response) = try await Self.streamSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard http.statusCode == 200 else {
                error = "Pane unavailable (\(http.statusCode))"
                connected = false
                return
            }
            streamID = http.value(forHTTPHeaderField: "X-Loom-Terminal-Stream") ?? ""
            connected = true
            error = ""
            startFlushing()

            var buffer = Data()
            buffer.reserveCapacity(8192)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 4096 {
                    pending.append(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if Task.isCancelled { break }
            }
            if !buffer.isEmpty { pending.append(buffer) }
        } catch is CancellationError {
            // Expected on teardown.
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
        connected = false
    }

    // MARK: Feeding xterm

    private func startFlushing() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
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
        term.open(document.getElementById('host'));

        function post(msg) {
          try { window.webkit.messageHandlers.loom.postMessage(msg); } catch (e) {}
        }
        term.onData(function (data) { post({ type: 'input', data: data }); });

        var lastCols = 0, lastRows = 0;
        function doFit() {
          if (!fit) return;
          try { fit.fit(); } catch (e) { return; }
          if (term.cols !== lastCols || term.rows !== lastRows) {
            lastCols = term.cols; lastRows = term.rows;
            post({ type: 'resize', cols: term.cols, rows: term.rows });
          }
        }
        var fitTimer = null;
        window.addEventListener('resize', function () {
          if (fitTimer) clearTimeout(fitTimer);
          fitTimer = setTimeout(doFit, 90);
        });

        window.__loomWrite = function (b64) {
          var raw = atob(b64);
          var bytes = new Uint8Array(raw.length);
          for (var i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }
          term.write(bytes);
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
            default:
                break
            }
        }
    }

    /// tmux resizes the pane to the client, so a new size means a new
    /// attachment. Debounced, because a drag reports every step.
    private func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != self.cols || rows != self.rows || streamTask == nil else { return }
        self.cols = cols
        self.rows = rows
        reattach?.cancel()
        reattach = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.streamTask?.cancel()
            self.streamTask = Task { [weak self] in await self?.attach() }
        }
    }
}

/// Hosts the terminal's web view. The view is owned by the session so it
/// survives SwiftUI rebuilding this struct.
struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}
