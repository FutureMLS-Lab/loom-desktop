#!/usr/bin/env swift
import AppKit
import WebKit

/// Hands the page what the app's asset scheme would: what it loads on demand,
/// typed as the app types it. Figures have no server here and fail, as they
/// should.
final class BundledScripts: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    static let types = ["js": "text/javascript", "css": "text/css", "woff2": "font/woff2"]
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "bundle",
              let type = Self.types[url.pathExtension],
              let data = try? Data(contentsOf: root.appendingPathComponent("Resources" + url.path))
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count,
                                    textEncodingName: type.hasPrefix("text/") ? "utf-8" : nil))
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
        let purify = try String(contentsOf: root.appendingPathComponent("Resources/purify.min.js"), encoding: .utf8)
        web.navigationDelegate = self
        web.loadHTMLString(
            page
                .replacingOccurrences(of: "<!--marked-->", with: "<script>\(marked)</script>")
                .replacingOccurrences(of: "<!--purify-->", with: "<script>\(purify)</script>"),
            baseURL: nil
        )
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let tests = try String(contentsOf: root.appendingPathComponent("Tests/MarkdownPreviewTests.js"), encoding: .utf8)
            let waiting = try [("diagrams", "Diagram"), ("math", "Math")].map { name, file in
                (name, try String(contentsOf: root.appendingPathComponent("Tests/MarkdownPreview\(file)Tests.js"), encoding: .utf8))
            }
            web.evaluateJavaScript(tests) { result, error in
                if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
                self.runWaiting(waiting, results: ["preview": result ?? NSNull()])
            }
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    /// The suites that wait for something the page fetches — the diagram
    /// renderer, KaTeX — one after another.
    func runWaiting(_ suites: [(String, String)], results: [String: Any]) {
        guard let suite = suites.first else {
            guard let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]),
                  let output = String(data: data, encoding: .utf8) else { exit(2) }
            print(output)
            exit(0)
        }
        web.callAsyncJavaScript(suite.1, arguments: [:], in: nil, in: .page) { outcome in
            switch outcome {
            case .failure(let error):
                fputs("FAIL (\(suite.0)): \(error)\n", stderr)
                exit(1)
            case .success(let value):
                var results = results
                results[suite.0] = value ?? NSNull()
                self.runWaiting(Array(suites.dropFirst()), results: results)
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let tests = PreviewTests()
try tests.run()
DispatchQueue.global().asyncAfter(deadline: .now() + 60) { fputs("FAIL: preview timed out\n", stderr); exit(2) }
app.run()
