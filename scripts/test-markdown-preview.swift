#!/usr/bin/env swift
import AppKit
import WebKit

// Run from the repository root. Exercises the shipping HTML in WebKit,
// without opening a window, contacting the gateway, or moving the pointer.
final class PreviewTests: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 700))
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    func run() throws {
        let page = try String(contentsOf: root.appendingPathComponent("Resources/markdown-preview.html"), encoding: .utf8)
        let marked = try String(contentsOf: root.appendingPathComponent("Resources/marked.min.js"), encoding: .utf8)
        web.navigationDelegate = self
        web.loadHTMLString(page.replacingOccurrences(of: "<!--marked-->", with: "<script>\(marked)</script>"), baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let tests = try String(contentsOf: root.appendingPathComponent("Tests/MarkdownPreviewTests.js"), encoding: .utf8)
            web.evaluateJavaScript(tests) { result, error in
                if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
                guard let result, let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                      let output = String(data: data, encoding: .utf8) else { exit(2) }
                print(output)
                exit(0)
            }
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let tests = PreviewTests()
try tests.run()
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { fputs("FAIL: preview timed out\n", stderr); exit(2) }
app.run()
