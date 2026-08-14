import AppKit
import SwiftUI
import WebKit

/// A web view that can hand the wheel to whatever is scrolling around it.
final class PassThroughWebView: WKWebView {
    var forwardsScrollWheel = false

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrollWheel {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// ⌘F and friends, answered by the find bar inside the page.
    ///
    /// The same Edit ▸ Find menu drives this and the source editor; whichever
    /// of them holds focus is the one the responder chain reaches.
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .showFindInterface, .showReplaceInterface:
            showFind()
        case .nextMatch:
            evaluateJavaScript("window.__loomFindStep(1);", completionHandler: nil)
        case .previousMatch:
            evaluateJavaScript("window.__loomFindStep(-1);", completionHandler: nil)
        case .hideFindInterface:
            evaluateJavaScript("window.__loomFindHide();", completionHandler: nil)
        default:
            break
        }
    }

    func showFind() {
        window?.makeFirstResponder(self)
        evaluateJavaScript("window.__loomFindShow();", completionHandler: nil)
    }
}

/// Browser-style Markdown preview: `marked` → HTML inside a WKWebView, with
/// article typography. Used by the Files tab, the digest under the terminal,
/// and the notes window, so large documents stay readable without the old
/// SwiftUI markdown path that froze the UI.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let documentID: String
    /// Smaller type and tighter margins, for the digest under the terminal.
    var compact = false
    /// Report the rendered document's height instead of scrolling internally,
    /// so the plan can lay out as part of a page rather than as a box with its
    /// own scrollbar inside another scroll view.
    var measuredHeight: Binding<CGFloat>?
    /// Bumped by the owner to open the find bar — for the digest under the
    /// terminal, where focus is usually in the pane rather than in here, so
    /// ⌘F alone would never reach this view.
    var findRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController = controller
        let web = PassThroughWebView(frame: .zero, configuration: config)
        // Sized to its content, this view has nothing of its own to scroll, so
        // the wheel belongs to the page around it. A web view swallows wheel
        // events regardless, which left the plan a dead zone: the page scrolled
        // everywhere except over the thing you were reading.
        web.forwardsScrollWheel = measuredHeight != nil
        controller.add(context.coordinator, name: "preview")
        #if DEBUG
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        #endif
        web.navigationDelegate = context.coordinator
        web.loadHTMLString(Self.shellHTML, baseURL: nil)
        context.coordinator.webView = web
        context.coordinator.pendingMarkdown = markdown
        context.coordinator.documentID = documentID
        context.coordinator.compact = compact
        context.coordinator.measuredHeight = measuredHeight
        context.coordinator.autosize = measuredHeight != nil
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.measuredHeight = measuredHeight
        (webView as? PassThroughWebView)?.forwardsScrollWheel = measuredHeight != nil
        let docChanged = context.coordinator.documentID != documentID
        if docChanged {
            context.coordinator.documentID = documentID
        }
        if context.coordinator.compact != compact {
            context.coordinator.compact = compact
            context.coordinator.applyCompact()
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            (webView as? PassThroughWebView)?.showFind()
        }
        context.coordinator.scheduleRender(markdown, force: docChanged)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var documentID = ""
        var findRequest = 0
        var pendingMarkdown = ""
        var ready = false
        var compact = false
        var autosize = false
        var measuredHeight: Binding<CGFloat>?

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // A measurement taken mid-layout can come back implausibly small;
            // keeping the previous height is better than clipping the document
            // to something nothing can scroll past.
            guard let height = message.body as? Double, height > 40 else { return }
            DispatchQueue.main.async {
                let rounded = CGFloat(height.rounded(.up))
                // Ignore sub-pixel churn, which would otherwise relayout the
                // page on every render.
                if abs((self.measuredHeight?.wrappedValue ?? 0) - rounded) > 1 {
                    self.measuredHeight?.wrappedValue = rounded
                }
            }
        }
        private var workItem: DispatchWorkItem?
        private var lastRendered = ""
        /// Which document the page is currently showing, so a re-render for the
        /// same file can keep the reader's place.
        private var renderedDocumentID: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if autosize {
                webView.evaluateJavaScript("window.__loomAutosize(true);", completionHandler: nil)
            }
            applyCompact()
            render(pendingMarkdown, immediate: true)
        }

        func applyCompact() {
            guard let webView, ready else { return }
            webView.evaluateJavaScript(
                "window.__loomSetCompact(\(compact));",
                completionHandler: nil
            )
        }

        func scheduleRender(_ markdown: String, force: Bool) {
            pendingMarkdown = markdown
            guard ready else { return }
            workItem?.cancel()
            if force {
                render(markdown, immediate: true)
                return
            }
            let item = DispatchWorkItem { [weak self] in
                self?.render(markdown, immediate: false)
            }
            workItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
        }

        private func render(_ markdown: String, immediate: Bool) {
            guard let webView, ready else { return }
            if !immediate, markdown == lastRendered { return }
            lastRendered = markdown
            // Jumping to the top belongs to opening a *different* document.
            // Doing it on every render would yank the page away while you type
            // in Split view, or each time the agent rewrites the plan.
            let resetScroll = renderedDocumentID != documentID
            renderedDocumentID = documentID
            // NSJSONSerialization rejects a bare String as the top-level value
            // (throws NSInvalidArgumentException → app abort). Wrap it.
            guard let data = try? JSONSerialization.data(withJSONObject: ["md": markdown]),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript(
                "window.__loomRender((\(json)).md, \(resetScroll));",
                completionHandler: nil
            )
        }
    }

    /// Self-contained shell: embeds `marked` when available, falls back to
    /// escaping into a `<pre>` so the pane never goes blank.
    private static let shellHTML: String = {
        let marked = loadMarkedJS() ?? ""
        let markedTag = marked.isEmpty
            ? ""
            : "<script>\(marked)</script>"
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <style>
          :root {
            --bg: #fffdf7;
            --ink: #1f1a14;
            --muted: #6b6358;
            --rule: #e7e0d2;
            --code-bg: #f4efe3;
            --accent: #4f46e5;
            --quote: #8a7f6a;
          }
          html, body {
            margin: 0; padding: 0;
            background: var(--bg);
            color: var(--ink);
            font: 16px/1.65 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          #wrap {
            max-width: 760px;
            margin: 0 auto;
            padding: 28px 36px 64px;
          }
          #content > :first-child { margin-top: 0; }
          h1, h2, h3, h4 {
            line-height: 1.25;
            font-weight: 650;
            letter-spacing: -0.015em;
            margin: 1.6em 0 0.55em;
          }
          h1 { font-size: 1.85em; border-bottom: 1px solid var(--rule); padding-bottom: 0.35em; }
          h2 { font-size: 1.4em; border-bottom: 1px solid var(--rule); padding-bottom: 0.25em; }
          h3 { font-size: 1.15em; }
          p, ul, ol, blockquote, pre, table { margin: 0.85em 0; }
          ul, ol { padding-left: 1.4em; }
          li { margin: 0.25em 0; }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            padding: 0.12em 0.4em;
            border-radius: 4px;
          }
          pre {
            background: var(--code-bg);
            border: 1px solid var(--rule);
            border-radius: 8px;
            padding: 14px 16px;
            overflow-x: auto;
            line-height: 1.5;
          }
          pre code { background: none; padding: 0; font-size: 0.86em; }
          blockquote {
            margin-left: 0;
            padding: 0.2em 0 0.2em 1em;
            border-left: 3px solid var(--rule);
            color: var(--quote);
          }
          hr {
            border: 0; border-top: 1px solid var(--rule);
            margin: 2em 0;
          }
          table {
            border-collapse: collapse;
            width: 100%;
            font-size: 0.95em;
          }
          th, td {
            border: 1px solid var(--rule);
            padding: 0.45em 0.7em;
            text-align: left;
          }
          th { background: var(--code-bg); }
          img { max-width: 100%; }
          #empty {
            color: var(--muted);
            text-align: center;
            padding: 80px 20px;
            font-size: 15px;
          }
          /* Digest under the terminal: same document, less room. */
          body.compact { font-size: 13px; line-height: 1.55; }
          body.compact #wrap { max-width: none; padding: 14px 20px 30px; }
          body.compact h1 { font-size: 1.5em; }
          body.compact h2 { font-size: 1.22em; }
          body.compact h3 { font-size: 1.05em; }
          body.compact h1, body.compact h2,
          body.compact h3, body.compact h4 { margin: 1.1em 0 0.4em; }
          body.compact p, body.compact ul, body.compact ol,
          body.compact blockquote, body.compact pre { margin: 0.6em 0; }
          body.compact pre { padding: 10px 12px; }
          body.compact #empty { padding: 34px 20px; font-size: 13px; }
          /* Laid out as part of a page: no scrollbar of its own, and no
             bottom padding reserved for one. */
          body.autosize { overflow: hidden; }
          body.autosize #wrap { padding-bottom: 18px; }
          /* Find. Sits over the text rather than above it, so showing it
             never reflows the document you are reading. */
          #find {
            position: fixed; top: 8px; right: 14px; display: none;
            align-items: center; gap: 6px; z-index: 20;
            background: #fffdf7; border: 1px solid var(--rule);
            border-radius: 7px; padding: 4px 6px;
            box-shadow: 0 4px 14px rgba(31, 26, 20, 0.13);
            font: 12px -apple-system, BlinkMacSystemFont, sans-serif;
          }
          #find.on { display: flex; }
          #find input {
            border: 0; outline: 0; background: transparent; width: 150px;
            font: 12px -apple-system, BlinkMacSystemFont, sans-serif;
            color: var(--ink);
          }
          #find button {
            border: 0; background: transparent; cursor: pointer;
            color: var(--muted); padding: 1px 4px; border-radius: 4px;
            font: 12px -apple-system, BlinkMacSystemFont, sans-serif;
          }
          #find button:hover { background: var(--code-bg); color: var(--ink); }
          #findCount { color: var(--muted); min-width: 34px; text-align: right; }
          mark.loom-hit { background: #fde68a; color: inherit; padding: 0; }
          mark.loom-hit.current { background: #f59e0b; color: #1f1a14; }
        </style>
        </head>
        <body>
          <div id="find">
            <input id="findInput" type="text" placeholder="Find" spellcheck="false"/>
            <span id="findCount"></span>
            <button id="findPrev" title="Previous (⇧⌘G)">‹</button>
            <button id="findNext" title="Next (⌘G)">›</button>
            <button id="findDone" title="Done (esc)">Done</button>
          </div>
          <div id="wrap"><div id="content"><div id="empty">Nothing to preview</div></div></div>
          \(markedTag)
          <script>
            function escapeHtml(s) {
              return s.replace(/[&<>"']/g, function(c) {
                return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]);
              });
            }
            window.__loomSetCompact = function(on) {
              document.body.classList.toggle('compact', !!on);
              reportHeight();
            };
            var autosize = false;
            window.__loomAutosize = function (on) {
              autosize = !!on;
              document.body.classList.toggle('autosize', autosize);
              reportHeight();
            };
            function reportHeight() {
              if (!autosize) return;
              // Measure after layout settles, or the first reading is of a
              // half-built document.
              requestAnimationFrame(function () {
                // The content's own box, not the document's: scrollHeight is
                // floored at the viewport, so once the view had been sized to
                // a long plan it could never report a shorter one again.
                var wrap = document.getElementById('wrap');
                var h = wrap
                  ? Math.ceil(wrap.getBoundingClientRect().height)
                  : document.documentElement.scrollHeight;
                try { window.webkit.messageHandlers.preview.postMessage(h); } catch (e) {}
              });
            }
            window.addEventListener('resize', reportHeight);

            // Find. `WKWebView.find` would highlight but gives no count and no
            // field to type into, so the whole thing lives in the page: wrap
            // matches in <mark>, step through them, and put the document back
            // exactly as it was on the way out.
            var findHits = [], findAt = -1, findClean = null;
            function findClear() {
              var root = document.getElementById('content');
              if (findClean !== null && root) { root.innerHTML = findClean; }
              findClean = null; findHits = []; findAt = -1;
            }
            function findRun(query) {
              var root = document.getElementById('content');
              if (!root) return;
              if (findClean === null) { findClean = root.innerHTML; }
              else { root.innerHTML = findClean; }
              findHits = []; findAt = -1;
              var needle = String(query || '').toLowerCase();
              if (!needle) { findPaint(); return; }
              var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
              var targets = [], node;
              while ((node = walker.nextNode())) {
                if (node.nodeValue.toLowerCase().indexOf(needle) !== -1) { targets.push(node); }
              }
              targets.forEach(function (text) {
                var parts = text.nodeValue.split(new RegExp('(' + needle.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + ')', 'ig'));
                var frag = document.createDocumentFragment();
                parts.forEach(function (part) {
                  if (part.toLowerCase() === needle) {
                    var m = document.createElement('mark');
                    m.className = 'loom-hit';
                    m.textContent = part;
                    frag.appendChild(m);
                  } else if (part) {
                    frag.appendChild(document.createTextNode(part));
                  }
                });
                text.parentNode.replaceChild(frag, text);
              });
              findHits = Array.prototype.slice.call(root.querySelectorAll('mark.loom-hit'));
              if (findHits.length) { findAt = 0; }
              findPaint(true);
            }
            function findPaint(scroll) {
              findHits.forEach(function (hit, i) {
                hit.classList.toggle('current', i === findAt);
              });
              var count = document.getElementById('findCount');
              if (count) {
                count.textContent = findHits.length ? (findAt + 1) + '/' + findHits.length : '0';
              }
              if (scroll && findAt >= 0 && findHits[findAt]) {
                findHits[findAt].scrollIntoView({ block: 'center' });
              }
            }
            window.__loomFindStep = function (delta) {
              if (!findHits.length) return;
              findAt = (findAt + delta + findHits.length) % findHits.length;
              findPaint(true);
            };
            window.__loomFindShow = function () {
              var bar = document.getElementById('find');
              var input = document.getElementById('findInput');
              if (!bar || !input) return;
              bar.classList.add('on');
              input.focus();
              input.select();
              if (input.value) { findRun(input.value); }
            };
            window.__loomFindHide = function () {
              var bar = document.getElementById('find');
              if (bar) { bar.classList.remove('on'); }
              findClear();
            };
            document.addEventListener('DOMContentLoaded', function () {
              var input = document.getElementById('findInput');
              input.addEventListener('input', function () { findRun(input.value); });
              input.addEventListener('keydown', function (e) {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  window.__loomFindStep(e.shiftKey ? -1 : 1);
                } else if (e.key === 'Escape') {
                  e.preventDefault();
                  window.__loomFindHide();
                }
              });
              document.getElementById('findNext').onclick = function () { window.__loomFindStep(1); };
              document.getElementById('findPrev').onclick = function () { window.__loomFindStep(-1); };
              document.getElementById('findDone').onclick = function () { window.__loomFindHide(); };
            });
            window.__loomRender = function(md, resetScroll) {
              var root = document.getElementById('content');
              // The find snapshot describes the document being replaced; kept,
              // it would put the old text back the next time find closed.
              findClean = null; findHits = []; findAt = -1;
              if (!md || !String(md).trim()) {
                root.innerHTML = '<div id="empty">Nothing to preview</div>';
                return;
              }
              var keepY = resetScroll ? 0 : window.scrollY;
              try {
                if (typeof marked !== 'undefined') {
                  if (marked.setOptions) {
                    marked.setOptions({ gfm: true, breaks: false, headerIds: true, mangle: false });
                  }
                  var html = (marked.parse ? marked.parse(md) : marked(md));
                  root.innerHTML = html;
                } else {
                  root.innerHTML = '<pre>' + escapeHtml(md) + '</pre>';
                }
              } catch (e) {
                root.innerHTML = '<pre>' + escapeHtml(md) + '</pre>';
              }
              window.scrollTo(0, keepY);
              reportHeight();
            };
          </script>
        </body>
        </html>
        """
    }()

    private static func loadMarkedJS() -> String? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "marked.min", withExtension: "js"),
            Bundle.main.resourceURL?.appendingPathComponent("marked.min.js"),
            // Running the bare binary from a source checkout, where there is
            // no .app to hold resources.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Sources/LoomDesktop
                .deletingLastPathComponent()   // Sources
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("Resources/marked.min.js"),
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
