#!/usr/bin/env swift
import AppKit
import WebKit

/// Hands the page what the app's asset scheme would: the bundled scripts it
/// loads on demand. Figures have no server here and fail, as they should.
final class BundledScripts: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "bundle",
              let data = try? Data(contentsOf: root.appendingPathComponent("Resources/\(url.lastPathComponent)"))
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: "text/javascript", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// Run from the repository root. Exercises the shipping HTML in WebKit,
// without opening a window, contacting the gateway, or moving the pointer.
final class PreviewTests: NSObject, WKNavigationDelegate {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    lazy var web: WKWebView = {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundledScripts(root: root), forURLScheme: "loom-asset")
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 700), configuration: config)
    }()
    func run() throws {
        let page = try String(contentsOf: root.appendingPathComponent("Resources/markdown-preview.html"), encoding: .utf8)
        let marked = try String(contentsOf: root.appendingPathComponent("Resources/marked.min.js"), encoding: .utf8)
        web.navigationDelegate = self
        web.loadHTMLString(page.replacingOccurrences(of: "<!--marked-->", with: "<script>\(marked)</script>"), baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let tests = try String(contentsOf: root.appendingPathComponent("Tests/MarkdownPreviewTests.js"), encoding: .utf8)
            let diagrams = try String(contentsOf: root.appendingPathComponent("Tests/MarkdownPreviewDiagramTests.js"), encoding: .utf8)
            web.evaluateJavaScript(tests) { result, error in
                if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
                self.web.callAsyncJavaScript(diagrams, arguments: [:], in: nil, in: .page) { outcome in
                    switch outcome {
                    case .failure(let error):
                        fputs("FAIL (diagrams): \(error)\n", stderr)
                        exit(1)
                    case .success(let diagramResult):
                        let combined: [String: Any] = ["preview": result ?? NSNull(), "diagrams": diagramResult ?? NSNull()]
                        guard let data = try? JSONSerialization.data(withJSONObject: combined, options: [.prettyPrinted, .sortedKeys]),
                              let output = String(data: data, encoding: .utf8) else { exit(2) }
                        print(output)
                        exit(0)
                    }
                }
            }
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let tests = PreviewTests()
try tests.run()
DispatchQueue.global().asyncAfter(deadline: .now() + 60) { fputs("FAIL: preview timed out\n", stderr); exit(2) }
app.run()
