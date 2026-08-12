import AppKit
import WebKit

/// Renders a window to a PNG for headless UI inspection.
///
/// `cacheDisplay(in:to:)` alone is not enough. It replays AppKit's drawing
/// path, and a `WKWebView` draws nothing there: its content lives in another
/// process and reaches the screen through the compositor. Windows captured
/// that way come back with the terminal and every markdown preview as blank
/// white rectangles, which is indistinguishable from a genuinely broken view.
///
/// So: capture the AppKit chrome as before, ask each web view for its own
/// snapshot, and paint those into place. `CGWindowListCreateImage` would be
/// simpler but needs Screen Recording permission, which defeats the point of
/// a hook you can run from a script.
///
/// One hole remains, and it is worth knowing about before reading a capture as
/// evidence: `takeSnapshot` returns DOM content, not canvas pixels, so the
/// terminal is still an empty rectangle here however healthy it is. Use
/// `LOOM_DESKTOP_DUMP_TERM=1` to see what it holds.
enum Snapshotter {
    static func capture(window: NSWindow, index: Int, into dir: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let webViews = webViews(in: view).filter {
            $0.bounds.width > 1 && $0.bounds.height > 1 && !$0.isHidden
        }
        let group = DispatchGroup()
        var overlays: [(NSRect, NSImage)] = []
        for web in webViews {
            var r = web.convert(web.bounds, to: view)
            // NSImage draws from the bottom left; the content view of a
            // SwiftUI window is flipped.
            if view.isFlipped {
                r.origin.y = view.bounds.height - r.maxY
            }
            let rect = r
            let config = WKSnapshotConfiguration()
            config.rect = web.bounds
            config.afterScreenUpdates = true
            group.enter()
            web.takeSnapshot(with: config) { image, _ in
                if let image { overlays.append((rect, image)) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let name = "window-\(index)-\(Int(view.bounds.width))x\(Int(view.bounds.height)).png"
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard !overlays.isEmpty else {
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                }
                return
            }
            // Compose into a bitmap of our own: the rep `cacheDisplay` hands
            // back is not in a format `NSGraphicsContext` will draw into, and
            // it fails by returning nil rather than complaining.
            guard let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: rep.pixelsWide,
                pixelsHigh: rep.pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return }
            // Before building the context, so its user space is points rather
            // than pixels and everything below can draw in view coordinates.
            canvas.size = view.bounds.size
            guard let ctx = NSGraphicsContext(bitmapImageRep: canvas) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let full = NSRect(origin: .zero, size: view.bounds.size)
            rep.draw(in: full)
            for (rect, image) in overlays {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let data = canvas.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
        }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let web = view as? WKWebView { found.append(web) }
        for sub in view.subviews { found.append(contentsOf: webViews(in: sub)) }
        return found
    }
}
