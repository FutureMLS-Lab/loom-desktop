import AppKit
import SwiftUI
import WebKit

/// Browser-style Markdown preview: `marked` → HTML inside a WKWebView, with
/// article typography. Used by the Files tab so large PLAN.md files stay
/// readable without the old SwiftUI markdown path that froze the UI.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let documentID: String
    /// Smaller type and tighter margins, for the digest under the terminal.
    var compact = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let web = WKWebView(frame: .zero, configuration: config)
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
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        let docChanged = context.coordinator.documentID != documentID
        if docChanged {
            context.coordinator.documentID = documentID
        }
        if context.coordinator.compact != compact {
            context.coordinator.compact = compact
            context.coordinator.applyCompact()
        }
        context.coordinator.scheduleRender(markdown, force: docChanged)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var documentID = ""
        var pendingMarkdown = ""
        var ready = false
        var compact = false
        private var workItem: DispatchWorkItem?
        private var lastRendered = ""
        /// Which document the page is currently showing, so a re-render for the
        /// same file can keep the reader's place.
        private var renderedDocumentID: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
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
        </style>
        </head>
        <body>
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
            };
            window.__loomRender = function(md, resetScroll) {
              var root = document.getElementById('content');
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
