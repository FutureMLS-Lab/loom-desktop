#!/usr/bin/env swift
// Render `Resources/markdown-preview.html` to a PNG, so a change to its
// typography can be looked at instead of guessed at. Loads the real page with
// the real renderer, so what comes out is what the digest and the notes window
// will draw.
//
//   swift scripts/preview-shot.swift <markdown-file> <out.png> [width] [compact]
//
// Nothing here touches the running app or the server.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: preview-shot.swift <markdown-file> <out.png> [width] [compact]")
    exit(2)
}
let markdownPath = args[1]
let outPath = args[2]
let width = args.count > 3 ? Double(args[3]) ?? 720 : 720
let compact = args.count > 4 && args[4] == "compact"

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // scripts
    .deletingLastPathComponent()      // package root
guard let page = try? String(contentsOf: root.appending(path: "Resources/markdown-preview.html"),
                             encoding: .utf8),
      let markdown = try? String(contentsOf: URL(fileURLWithPath: markdownPath), encoding: .utf8)
else {
    print("cannot read the page or the markdown")
    exit(1)
}
let marked = (try? String(contentsOf: root.appending(path: "Resources/marked.min.js"),
                          encoding: .utf8)) ?? ""
let html = page.replacingOccurrences(
    of: "<!--marked-->",
    with: marked.isEmpty ? "" : "<script>\(marked)</script>"
)

final class Shooter: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let markdown: String
    let out: String
    let compact: Bool

    init(width: Double, markdown: String, out: String, compact: Bool) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        self.markdown = markdown
        self.out = out
        self.compact = compact
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let payload = (try? JSONSerialization.data(withJSONObject: ["md": markdown]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let setup = compact ? "window.__loomSetCompact(true);" : ""
        webView.evaluateJavaScript("\(setup) window.__loomRender(\(payload).md);") { _, _ in
            // One runloop turn for layout, then grow to the whole document so
            // nothing interesting is cropped away below the fold.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.resizeAndShoot() }
        }
    }

    private func resizeAndShoot() {
        web.evaluateJavaScript("document.getElementById('wrap').scrollHeight") { value, _ in
            let height = (value as? Double) ?? 900
            self.web.frame.size.height = min(max(height, 200), 4000)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.shoot() }
        }
    }

    private func shoot() {
        web.takeSnapshot(with: nil) { image, _ in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                print("snapshot failed")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: self.out))
            print("wrote \(self.out)  \(Int(image.size.width))x\(Int(image.size.height))")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shooter = Shooter(width: width, markdown: markdown, out: outPath, compact: compact)
shooter.web.loadHTMLString(html, baseURL: nil)
app.run()
