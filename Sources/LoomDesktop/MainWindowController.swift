import AppKit
import SwiftUI

/// The main window — the project/task browser. Created on demand and kept
/// around; showing it again reuses the same window.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?

    /// Whether the task on screen is actually on screen — the window is kept
    /// around after it closes, so its existence says nothing.
    var isVisible: Bool { window?.isVisible == true }

    /// Content size, sized like the web console in a browser window.
    private static let defaultSize = NSSize(width: 1280, height: 860)

    func show(store: TaskStore) {
        if window == nil {
            // Sized like the web console in a browser window, not like a
            // utility palette — the sidebar alone is 320pt.
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loom"
            window.subtitle = "projects"
            window.minSize = NSSize(width: 940, height: 640)
            window.isReleasedWhenClosed = false
            // Versioned: an autosaved frame from an older, much smaller
            // layout would otherwise override the default size forever.
            window.setFrameAutosaveName("loom-main-v2")
            // sizingOptions = [] or the hosting view drives the window to the
            // content's *ideal* size, which for this layout is its minimum —
            // the window would open at 940×640 no matter what we ask for.
            let hosting = NSHostingView(rootView: ProjectPickerView(store: store))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.delegate = self
            // Fit the screen the pointer is on; 1280×860 overflows a laptop
            // display, and a window taller than the screen cannot be resized
            // back by dragging its (offscreen) bottom edge.
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main {
                let visible = screen.visibleFrame
                // From the intended content size, never from `window.frame`:
                // frame includes the title bar, so feeding it back through
                // setContentSize grew the window by 28pt on every launch.
                var size = NSSize(
                    width: min(Self.defaultSize.width, visible.width - 80),
                    height: min(Self.defaultSize.height, visible.height - 80)
                )
                // Dev hook: LOOM_DESKTOP_WINDOW=900x620 opens at that content
                // size, so cramped layouts can be checked without a person
                // dragging a corner.
                if let spec = ProcessInfo.processInfo.environment["LOOM_DESKTOP_WINDOW"] {
                    let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 {
                        size = NSSize(width: parts[0], height: parts[1])
                    }
                }
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                ))
            } else {
                window.center()
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // The window object is kept for reuse; the app stays alive in the menu
        // bar. Its views are not torn down with it, though, so a terminal
        // would go on holding its attachment — and an attached client keeps
        // the pane sized to it for everyone else, including the browser.
        TerminalSession.stopAll()
    }
}
