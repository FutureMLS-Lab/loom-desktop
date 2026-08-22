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

/// Serves `loom-asset://` requests from the markdown preview by fetching the
/// figure through the API, which is the only party holding the token.
private final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let api = LoomAPI()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            task.didFailWithError(LoomAPIError(message: "bad asset url", status: 0))
            return
        }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }
        let path = value("path"), project = value("project"), slug = value("task")
        Task { [api] in
            do {
                let (data, type) = try await api.asset(projectId: project, task: slug, path: path)
                let response = URLResponse(
                    url: url, mimeType: type,
                    expectedContentLength: data.count, textEncodingName: nil
                )
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch {
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Browser-style Markdown preview: `marked` → HTML inside a WKWebView, with
/// article typography. Used by the digest under the terminal and the notes
/// window, so large documents stay readable without the old SwiftUI markdown
/// path that froze the UI.
struct MarkdownPreview: NSViewRepresentable {
    /// Our own scheme, so `<img>` can reach a figure the server holds.
    static let assetScheme = "loom-asset"
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
    /// Where a relative image path in the document resolves to. Figures live
    /// next to the markdown on the server, so they are fetched rather than
    /// read from disk; without a task the base is the project's `.RUD/`.
    var assetProject = ""
    var assetTask = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController = controller
        // Images come from the server, behind the same bearer token as
        // everything else, which an <img> cannot send for itself. A scheme of
        // our own lets the fetch happen in Swift and hands the bytes back.
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: MarkdownPreview.assetScheme)
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
        context.coordinator.assetProject = assetProject
        context.coordinator.assetTask = assetTask
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.measuredHeight = measuredHeight
        (webView as? PassThroughWebView)?.forwardsScrollWheel = measuredHeight != nil
        if context.coordinator.assetProject != assetProject
            || context.coordinator.assetTask != assetTask {
            context.coordinator.assetProject = assetProject
            context.coordinator.assetTask = assetTask
            context.coordinator.applyAssetScope()
        }
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
        var assetProject = ""
        var assetTask = ""
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
            applyAssetScope()
            render(pendingMarkdown, immediate: true)
        }

        func applyAssetScope() {
            guard let webView, ready else { return }
            let project = assetProject.replacingOccurrences(of: "'", with: "")
            let task = assetTask.replacingOccurrences(of: "'", with: "")
            webView.evaluateJavaScript(
                "window.__loomAssetScope('\(project)', '\(task)');",
                completionHandler: nil
            )
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

    /// The page itself lives in `Resources/markdown-preview.html`, where its
    /// CSS and JS can be read and edited as CSS and JS. `marked` is spliced in
    /// at the placeholder when the bundle has it; without it the page falls
    /// back to escaping into a `<pre>` rather than going blank.
    private static let shellHTML: String = {
        guard let page = LoomResource.text("markdown-preview", "html") else {
            return "<!doctype html><html><body></body></html>"
        }
        let marked = LoomResource.text("marked.min", "js") ?? ""
        return page.replacingOccurrences(
            of: "<!--marked-->",
            with: marked.isEmpty ? "" : "<script>\(marked)</script>"
        )
    }()

}
