import SwiftUI
import UIKit
import WebKit

/// Serves `loom-asset://` requests from the markdown page: a figure fetched
/// through the API, which holds the token an `<img>` cannot send, or
/// `loom-asset://bundle/<file>`, a script the page loads only when a document
/// needs it.
@MainActor
private final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let api = LoomAPI()
    /// WebKit stops the task of an `<img>` that leaves the page, and answering
    /// a stopped task raises.
    private var inFlight: [ObjectIdentifier: Task<Void, Never>] = [:]

    private static let bundled = ["mermaid.min.js": ("mermaid.min", "js")]
    private static var bundledData: [String: Data] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            task.didFailWithError(LoomAPIError(message: "bad asset url", status: 0))
            return
        }
        if url.host == "bundle" {
            serveBundled(url, to: task)
            return
        }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }
        let path = value("path"), project = value("project"), slug = value("task")
        let id = ObjectIdentifier(task)
        inFlight[id] = Task { [api] in
            let result: Result<(Data, String), Error>
            do {
                result = .success(try await api.asset(projectId: project, task: slug, path: path))
            } catch {
                result = .failure(error)
            }
            guard self.inFlight.removeValue(forKey: id) != nil else { return }
            switch result {
            case .success(let (data, type)):
                task.didReceive(URLResponse(
                    url: url, mimeType: type,
                    expectedContentLength: data.count, textEncodingName: nil
                ))
                task.didReceive(data)
                task.didFinish()
            case .failure(let error):
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        inFlight.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    private func serveBundled(_ url: URL, to task: WKURLSchemeTask) {
        let file = url.lastPathComponent
        guard let (name, ext) = Self.bundled[file],
              let data = Self.bundledData[file] ?? LoomResource.data(name, ext)
        else {
            task.didFailWithError(LoomAPIError(message: "\(file) is not bundled", status: 404))
            return
        }
        Self.bundledData[file] = data
        task.didReceive(URLResponse(
            url: url, mimeType: "text/javascript",
            expectedContentLength: data.count, textEncodingName: "utf-8"
        ))
        task.didReceive(data)
        task.didFinish()
    }
}

/// The desktop's markdown page — `marked`, figures through the API, diagrams
/// drawn when a document has them, collapsible headings — in a web view. Its
/// text selects as any page's does: long press, drag the handles, Copy.
struct MarkdownWebView: UIViewRepresentable {
    static let assetScheme = "loom-asset"
    let markdown: String
    let documentID: String
    var assetProject = ""
    var assetTask = ""
    var assetDirectory = ""
    /// Bump to fetch the figures again; the text can stay the same while a
    /// figure next to it is regenerated.
    var assetRevision = 0
    /// Bump to bring up the system find bar over the page.
    var findRequest = 0
    var onRefresh: (() async -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.phoneStyle,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.add(coordinator, name: "preview")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.dataDetectorTypes = [.link]
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: Self.assetScheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.isFindInteractionEnabled = true
        web.navigationDelegate = coordinator
        #if DEBUG
        web.isInspectable = true
        #endif
        let refresh = UIRefreshControl()
        refresh.addTarget(coordinator, action: #selector(Coordinator.pulled(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh

        coordinator.webView = web
        coordinator.pendingMarkdown = markdown
        coordinator.documentID = documentID
        coordinator.assetProject = assetProject
        coordinator.assetTask = assetTask
        coordinator.assetDirectory = assetDirectory
        coordinator.assetRevision = assetRevision
        coordinator.findRequest = findRequest
        coordinator.onRefresh = onRefresh
        web.loadHTMLString(Self.shellHTML, baseURL: nil)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.webView = webView
        coordinator.onRefresh = onRefresh
        if coordinator.assetProject != assetProject
            || coordinator.assetTask != assetTask
            || coordinator.assetDirectory != assetDirectory {
            coordinator.assetProject = assetProject
            coordinator.assetTask = assetTask
            coordinator.assetDirectory = assetDirectory
            coordinator.applyAssetScope()
        }
        let documentChanged = coordinator.documentID != documentID
        if documentChanged { coordinator.documentID = documentID }
        coordinator.scheduleRender(markdown, force: documentChanged)
        if coordinator.assetRevision != assetRevision {
            coordinator.assetRevision = assetRevision
            coordinator.refreshAssets()
        }
        if coordinator.findRequest != findRequest {
            coordinator.findRequest = findRequest
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // The content controller holds its handlers strongly.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "preview")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Folded headings survive a re-render and a trip to another tab.
        private static var foldMemory: [String: [String]] = [:]
        private static var foldOrder: [String] = []
        private var foldDocumentID: String { "\(LoomSettings.activeServerID)/\(documentID)" }

        weak var webView: WKWebView?
        var documentID = ""
        var assetProject = ""
        var assetTask = ""
        var assetDirectory = ""
        var assetRevision = 0
        var findRequest = 0
        var pendingMarkdown = ""
        var onRefresh: (() async -> Void)?
        private var ready = false
        private var lastRendered = ""
        private var renderedDocumentID: String?
        private var workItem: DispatchWorkItem?

        @objc func pulled(_ control: UIRefreshControl) {
            Task {
                await onRefresh?()
                control.endRefreshing()
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let report = message.body as? [String: Any],
                  report["type"] as? String == "folds",
                  let document = report["document"] as? String,
                  document == foldDocumentID,
                  let collapsed = report["collapsed"] as? [String]
            else { return }
            Self.foldMemory[document] = collapsed
            Self.foldOrder.removeAll { $0 == document }
            Self.foldOrder.append(document)
            if Self.foldOrder.count > 64 {
                Self.foldMemory.removeValue(forKey: Self.foldOrder.removeFirst())
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            applyAssetScope()
            render(pendingMarkdown, immediate: true)
        }

        /// A link opens in Safari; the page itself never navigates away.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// iOS reclaims a web view's content process while the app is in the
        /// background, which leaves the page blank until it is loaded again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            lastRendered = ""
            renderedDocumentID = nil
            webView.loadHTMLString(MarkdownWebView.shellHTML, baseURL: nil)
        }

        func applyAssetScope() {
            guard let webView, ready,
                  let data = try? JSONSerialization.data(
                      withJSONObject: [assetProject, assetTask, assetDirectory]
                  ),
                  let args = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.__loomAssetScope.apply(null, \(args));", completionHandler: nil)
        }

        func refreshAssets() {
            guard let webView, ready else { return }
            webView.evaluateJavaScript("window.__loomRefreshAssets();", completionHandler: nil)
        }

        func scheduleRender(_ markdown: String, force: Bool) {
            guard force || markdown != pendingMarkdown else { return }
            pendingMarkdown = markdown
            guard ready else { return }
            workItem?.cancel()
            if force {
                render(markdown, immediate: true)
                return
            }
            guard markdown != lastRendered else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.render(markdown, immediate: false)
            }
            workItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: item)
        }

        private func render(_ markdown: String, immediate: Bool) {
            guard let webView, ready else { return }
            if !immediate, markdown == lastRendered { return }
            lastRendered = markdown
            // Back to the top only for a different document: the agent
            // rewriting the plan should not take the reader's place away.
            let resetScroll = renderedDocumentID != documentID
            renderedDocumentID = documentID
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "md": markdown,
                "document": foldDocumentID,
                "folds": Self.foldMemory[foldDocumentID] ?? [],
            ]),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript(
                "{ const data = \(json); window.__loomRender(data.md, \(resetScroll), data.document, data.folds); }",
                completionHandler: nil
            )
            #if DEBUG
            // Simulator runs, which cannot scroll: `-LoomPlanReveal <selector>`
            // brings the first match on screen once figures have had time.
            if resetScroll, let selector = UserDefaults.standard.string(forKey: "LoomPlanReveal"),
               let data = try? JSONSerialization.data(withJSONObject: [selector]),
               let args = String(data: data, encoding: .utf8) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak webView] in
                    webView?.evaluateJavaScript(
                        "document.querySelector(\(args)[0])?.scrollIntoView({ block: 'center' });",
                        completionHandler: nil
                    )
                }
            }
            #endif
        }
    }

    fileprivate static let shellHTML: String = {
        guard let page = LoomResource.text("markdown-preview", "html") else {
            return "<!doctype html><html><body></body></html>"
        }
        let marked = LoomResource.text("marked.min", "js") ?? ""
        let purify = LoomResource.text("purify.min", "js") ?? ""
        return page
            .replacingOccurrences(
                of: "<!--marked-->",
                with: marked.isEmpty ? "" : "<script>\(marked)</script>"
            )
            .replacingOccurrences(
                of: "<!--purify-->",
                with: purify.isEmpty ? "" : "<script>\(purify)</script>"
            )
    }()

    /// A phone's column: the desktop margins took a fifth of the width, and
    /// the fold controls were sized for a pointer, not a thumb. The left
    /// margin keeps room for the fold arrows that hang outside the text.
    private static let phoneStyle = """
    (function () {
      var style = document.createElement('style');
      style.textContent = [
        'html { -webkit-text-size-adjust: 100%; }',
        '#wrap { max-width: none; padding: 14px 18px 56px 28px; }',
        '#reading-tools { font-size: 13px; }',
        '#reading-tools button { padding: 7px 10px; }',
        '.fold-toggle { width: 24px; height: 28px; right: calc(100% + 1px); top: 0; }',
        'pre code { font-size: 0.82em; }',
        'table { font-size: 0.9em; }'
      ].join('\\n');
      document.head.appendChild(style);
    })();
    """
}
