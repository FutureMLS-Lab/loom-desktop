import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TaskStore()
    var panel: PanelWindow!

    static let summonNotification = "com.loom.desktop.summon"
    static let showPanelNotification = "com.loom.desktop.show-panel"

    func applicationDidFinishLaunching(_ notification: Notification) {
        loomBoot("applicationDidFinishLaunching entered")
        defer {
            loomBoot("didFinishLaunching done; policy=\(NSRunningApplication.current.activationPolicy.rawValue) finished=\(NSRunningApplication.current.isFinishedLaunching)")
        }
        // Single instance: a second launch (e.g. double-clicking the app in
        // Finder while it is already running) pokes the first instance to
        // summon everything to the current screen, then exits.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            DistributedNotificationCenter.default().postNotificationName(
                .init(Self.summonNotification), object: nil, userInfo: nil,
                deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init(Self.summonNotification), object: nil, queue: .main
        ) { [weak self] _ in
            self?.summon()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init(Self.showPanelNotification), object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel.setPanelHidden(false)
        }

        // A regular app: Dock icon, ⌘Tab, ordinary activation. `.accessory`
        // looks tidier for a dock utility, but an accessory app launched
        // outside LaunchServices is not a registered application — its
        // windows then draw fine yet never receive clicks, resize, or focus,
        // which is exactly the "nothing works" symptom.
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        // Every mouse-down the app receives is appended to a small log, so
        // "my click did nothing" reports can be told apart from "the click
        // never reached the app" without a special debug build.
        installClickLog()

        SettingsWindowController.shared.store = store

        panel = PanelWindow(store: store)
        if !panel.isPanelHidden {
            panel.orderFrontRegardless()
        }

        store.start()

        // First run: the main window opens so there is something to land on.
        if UserDefaults.standard.bool(forKey: "showMainOnLaunch") {
            MainWindowController.shared.show(store: store)
        }

        // Dev hook: LOOM_DESKTOP_DEBUG_EVENTS=1 logs every mouse-down the app
        // receives, to tell "click never arrived" apart from "click arrived
        // but the control ignored it".
        if ProcessInfo.processInfo.environment["LOOM_DESKTOP_DEBUG_EVENTS"] == "1" {
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                let win = event.window?.windowNumber ?? -1
                FileHandle.standardError.write(
                    "mouseDown window=\(win) loc=\(event.locationInWindow)\n".data(using: .utf8)!
                )
                return event
            }
        }

        // Dev hook: LOOM_DESKTOP_SNAPSHOT_DIR=<dir> renders every window's
        // content to PNGs there a few seconds after launch, so UI states can
        // be inspected headlessly (no screen-recording permission needed).
        if let dir = ProcessInfo.processInfo.environment["LOOM_DESKTOP_SNAPSHOT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let name = "window-\(i)-\(Int(view.bounds.width))x\(Int(view.bounds.height)).png"
                        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                    }
                }
            }
        }

        // Dev hook: LOOM_DESKTOP_OPEN_CHAT="<projectId>/<slug>" selects that
        // task on launch (handy when iterating on the task pane).
        if let key = ProcessInfo.processInfo.environment["LOOM_DESKTOP_OPEN_CHAT"],
           key.contains("/") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [store] in
                store.selection = key
                MainWindowController.shared.show(store: store)
            }
        }
    }

    /// Clicking the Dock icon of a running app: bring everything back to the
    /// screen the pointer is on. This is the only entry point now that the
    /// menu-bar item is gone — one Loom, not two.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        summon()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// "Relaunch me" — show the panel and the main window wherever the user
    /// currently is. This is what a Finder double-click means for an app that
    /// is already running.
    private func summon() {
        panel.setPanelHidden(false)
        if let store = SettingsWindowController.shared.store {
            MainWindowController.shared.show(store: store)
        }
    }

    private func installClickLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LoomDesktop-events.log")
        // Start fresh when it grows past ~100 KB; this is a diagnostics
        // breadcrumb, not an archive.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int,
           size > 100_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let stamp = ISO8601DateFormatter().string(from: Date())
            let window = event.window.map { type(of: $0) == PanelWindow.self ? "panel" : "window#\($0.windowNumber)" } ?? "none"
            let line = "\(stamp) \(event.type == .leftMouseDown ? "L" : "R")down \(window) loc=\(event.locationInWindow)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: logURL)
                }
            }
            return event
        }
    }

    /// Accessory apps get no menu bar of their own, but a main menu is still
    /// what routes the standard key equivalents — without it there is no ⌘Q,
    /// no ⌘W, and (worst of all) no ⌘C/⌘V in the chat composer.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Loom Desktop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        let showMain = NSMenuItem(
            title: "Loom Projects", action: #selector(openMainWindow), keyEquivalent: "0"
        )
        showMain.target = self
        windowMenu.addItem(showMain)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show(store: store)
    }
}

/// Boot trace, off unless `LOOM_DESKTOP_TRACE=1`. An app that fails to become
/// a registered application shows no windows and takes no clicks, which from
/// the outside is indistinguishable from a hang; this records how far a launch
/// actually got. Kept because that failure mode is a property of the machine,
/// not of this code, so it can recur.
func loomBoot(_ message: String) {
    guard ProcessInfo.processInfo.environment["LOOM_DESKTOP_TRACE"] == "1"
        || ProcessInfo.processInfo.environment["LOOM_DESKTOP_TRACE_LAYOUT"] == "1"
    else { return }
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    let path = "/tmp/loom-boot.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

@main
@MainActor
enum LoomDesktopMain {
    static func main() {
        loomBoot("main() entered, bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
        let app = NSApplication.shared
        loomBoot("NSApplication.shared ok")
        let ok = app.setActivationPolicy(.regular)
        loomBoot("setActivationPolicy(.regular) -> \(ok); current policy=\(NSRunningApplication.current.activationPolicy.rawValue)")
        let delegate = AppDelegate()
        app.delegate = delegate
        loomBoot("delegate set, calling run()")
        app.run()
    }
}
