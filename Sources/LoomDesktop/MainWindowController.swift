import AppKit
import Combine
import SwiftUI

/// What the window's toolbar and its SwiftUI content share. The toolbar is
/// AppKit — a unified toolbar is only had that way — and the view is SwiftUI;
/// this is the one object both can see.
@MainActor
final class MainWindowState: ObservableObject {
    /// The toolbar's search field, filtering the sidebar as it is typed.
    @Published var filter = ""
    /// Counters rather than flags: the view presents a sheet when one ticks
    /// and does not have to reset anything afterwards.
    @Published var newTaskRequests = 0
    @Published var addProjectRequests = 0
    @Published var toggleSidebarRequests = 0
    @Published var quickOpenRequests = 0
    /// Secondary context beneath the persistent wordmark in the title bar.
    @Published var titleContext = "Workspace"
}

/// The main window — the project/task browser. Created on demand and kept
/// around; showing it again reuses the same window.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?
    private weak var store: TaskStore?
    private let windowState = MainWindowState()
    private var subtitleSink: AnyCancellable?

    /// Whether the task on screen is actually on screen — the window is kept
    /// around after it closes, so its existence says nothing.
    var isVisible: Bool { window?.isVisible == true }

    /// Content size, sized like the web console in a browser window.
    private static let defaultSize = NSSize(width: 1280, height: 860)

    func show(store: TaskStore) {
        self.store = store
        if window == nil {
            // Sized like the web console in a browser window, not like a
            // utility palette — the sidebar alone is 300pt.
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loom"
            // Keep the semantic window title for the Window menu and
            // accessibility; the toolbar draws a larger, consistent wordmark.
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 940, height: 640)
            window.isReleasedWhenClosed = false
            // Versioned: an autosaved frame from an older, much smaller
            // layout would otherwise override the default size forever.
            window.setFrameAutosaveName("loom-main-v2")
            // sizingOptions = [] or the hosting view drives the window to the
            // content's *ideal* size, which for this layout is its minimum —
            // the window would open at 940×640 no matter what we ask for.
            let hosting = NSHostingView(
                rootView: ProjectPickerView(store: store, windowState: windowState)
            )
            hosting.sizingOptions = []
            window.contentView = hosting
            window.delegate = self
            installToolbar(on: window)
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
            // The title bar names the task in front, the way Mail's names the
            // mailbox: task as the title, its project underneath. With
            // nothing selected it is the app's name over the fleet's size.
            subtitleSink = store.$selection
                .combineLatest(store.$tasksByProject)
                .receive(on: RunLoop.main)
                .sink { [weak self, weak store] selection, tasksByProject in
                    guard let self, let store, let window = self.window else { return }
                    if let selection, let (project, meta) = store.meta(forSelection: selection) {
                        window.title = meta.title ?? meta.slug
                        window.subtitle = project.label
                        self.windowState.titleContext = project.label
                    } else {
                        window.title = "Loom"
                        let count = tasksByProject.values.reduce(0) { $0 + $1.count }
                        window.subtitle = count == 0 ? "" : (count == 1 ? "1 task" : "\(count) tasks")
                        self.windowState.titleContext = count == 0 ? "Workspace" : "Workspace · \(count) tasks"
                    }
                }
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

    // MARK: Toolbar

    /// The window's own toolbar, in the title bar: new, refresh, search. These
    /// used to sit at the foot of the sidebar with the search box inline
    /// above the list, which is where a web page keeps them; a Mac window
    /// keeps them up here.
    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "loom-main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.loomBrand, .flexibleSpace, .loomSidebar, .loomQuickOpen, .loomNew, .loomRefresh, .loomSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .loomBrand:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Loom"
            item.toolTip = "Workspace overview (⇧⌘H)"
            item.visibilityPriority = .high
            let brand = NSHostingView(rootView: WindowBrandView(state: windowState) { [weak self] in
                self?.showOverview()
            })
            brand.sizingOptions = []
            brand.frame = NSRect(x: 0, y: 0, width: 184, height: 40)
            NSLayoutConstraint.activate([
                brand.widthAnchor.constraint(equalToConstant: 184),
                brand.heightAnchor.constraint(equalToConstant: 40),
            ])
            item.view = brand
            return item
        case .loomSidebar, .loomQuickOpen:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let sidebar = identifier == .loomSidebar
            item.label = sidebar ? "Toggle Sidebar" : "Quick Switch"
            item.image = NSImage(systemSymbolName: sidebar ? "sidebar.left" : "command", accessibilityDescription: item.label)
            item.toolTip = sidebar ? "Toggle sidebar (⌃⌘S)" : "Quick switch tasks (⌘K or ⌘P)"
            item.target = self
            item.action = sidebar ? #selector(toggleSidebar) : #selector(requestQuickOpen)
            item.isBordered = true
            return item
        case .loomNew:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
            item.label = "New"
            item.toolTip = "New task (⌘N) or add a project"
            let menu = NSMenu()
            let task = NSMenuItem(title: "New Task…", action: #selector(requestNewTask), keyEquivalent: "")
            task.target = self
            menu.addItem(task)
            let project = NSMenuItem(title: "Add Project…", action: #selector(requestAddProject), keyEquivalent: "")
            project.target = self
            menu.addItem(project)
            item.menu = menu
            item.showsIndicator = true
            return item
        case .loomRefresh:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.label = "Refresh"
            item.toolTip = "Refresh (⌘R)"
            item.target = self
            item.action = #selector(refresh)
            item.isBordered = true
            return item
        case .loomSearch:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Filter"
            item.preferredWidthForSearchField = 200
            item.searchField.placeholderString = "Filter tasks"
            // Live: the list narrows as you type, not on Return.
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(filterChanged(_:))
            return item
        default:
            return nil
        }
    }

    @objc private func toggleSidebar() { windowState.toggleSidebarRequests += 1 }
    @objc private func showOverview() { store?.selection = nil }
    @objc private func requestQuickOpen() { windowState.quickOpenRequests += 1 }
    @objc private func requestNewTask() { windowState.newTaskRequests += 1 }
    @objc private func requestAddProject() { windowState.addProjectRequests += 1 }
    @objc private func refresh() { store?.refreshNow() }

    @objc private func filterChanged(_ field: NSSearchField) {
        if windowState.filter != field.stringValue {
            windowState.filter = field.stringValue
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let loomBrand = NSToolbarItem.Identifier("loom.brand")
    static let loomSidebar = NSToolbarItem.Identifier("loom.sidebar")
    static let loomQuickOpen = NSToolbarItem.Identifier("loom.quickOpen")
    static let loomNew = NSToolbarItem.Identifier("loom.new")
    static let loomRefresh = NSToolbarItem.Identifier("loom.refresh")
    static let loomSearch = NSToolbarItem.Identifier("loom.search")
}

private struct WindowBrandView: View {
    @ObservedObject var state: MainWindowState
    let onOpenWorkspace: () -> Void

    var body: some View {
        Button(action: onOpenWorkspace) {
            HStack(spacing: 9) {
                LoomMark(size: 30, opacity: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Loom")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .tracking(-0.6)
                        .foregroundStyle(.primary)
                    Text(state.titleContext)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 184, height: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Loom, \(state.titleContext), open workspace")
    }
}
