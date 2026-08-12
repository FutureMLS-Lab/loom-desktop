import AppKit

/// Menu-bar entry: show/hide the floating dock, jump to a task, open Settings,
/// quit. Lives next to the clock so the dock can be hidden without losing the
/// app.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: TaskStore
    private weak var panel: PanelWindow?

    init(store: TaskStore, panel: PanelWindow?) {
        self.store = store
        self.panel = panel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "circle.hexagongrid.fill",
                accessibilityDescription: "Loom"
            )
            button.image?.isTemplate = true
            button.toolTip = "Loom Desktop"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if store.pills.isEmpty {
            let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for pill in store.pills {
                let title = "\(statePrefix(pill.state))  \(pill.projectLabel) · \(pill.displayTitle)"
                let item = NSMenuItem(title: title, action: #selector(openPill(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pill.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let browse = NSMenuItem(title: "Open Task", action: nil, keyEquivalent: "")
        let browseMenu = NSMenu()
        for project in store.projects {
            let projectItem = NSMenuItem(title: project.label, action: nil, keyEquivalent: "")
            let taskMenu = NSMenu()
            for meta in store.tasksByProject[project.id] ?? [] {
                let item = NSMenuItem(
                    title: meta.title ?? meta.slug,
                    action: #selector(openTask(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = [project.id, meta.slug]
                taskMenu.addItem(item)
            }
            if taskMenu.items.isEmpty {
                let none = NSMenuItem(title: "No tasks", action: nil, keyEquivalent: "")
                none.isEnabled = false
                taskMenu.addItem(none)
            }
            projectItem.submenu = taskMenu
            browseMenu.addItem(projectItem)
        }
        if browseMenu.items.isEmpty {
            let none = NSMenuItem(title: "No projects", action: nil, keyEquivalent: "")
            none.isEnabled = false
            browseMenu.addItem(none)
        }
        browse.submenu = browseMenu
        menu.addItem(browse)

        menu.addItem(.separator())
        let main = NSMenuItem(title: "Open Loom (Projects)", action: #selector(openMain), keyEquivalent: "o")
        main.target = self
        menu.addItem(main)
        let notes = NSMenuItem(title: "Project Notes…", action: #selector(openNotes), keyEquivalent: "n")
        notes.keyEquivalentModifierMask = [.command, .shift]
        notes.target = self
        menu.addItem(notes)
        let panelToggle = NSMenuItem(
            title: (panel?.isPanelHidden ?? false) ? "Show Dock Panel" : "Hide Dock Panel",
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        panelToggle.target = self
        menu.addItem(panelToggle)
        if store.unseenCount > 0 {
            let seen = NSMenuItem(
                title: "Mark All \(store.unseenCount) as Seen",
                action: #selector(markAllSeen),
                keyEquivalent: ""
            )
            seen.target = self
            menu.addItem(seen)
        }
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Loom Desktop", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var emptyTitle: String {
        switch store.connection {
        case .connecting: return "Connecting to Loom…"
        case .offline: return "Loom unreachable — check Settings"
        case .online: return "No active agents"
        }
    }

    private func statePrefix(_ state: TaskPill.State) -> String {
        switch state {
        case .working: return "⟳"
        case .finished: return "●"
        case .idle: return "○"
        }
    }

    @objc private func openPill(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let pill = store.pills.first(where: { $0.id == id })
        else { return }
        store.select(projectId: pill.projectId, slug: pill.slug)
        MainWindowController.shared.show(store: store)
    }

    @objc private func openTask(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count >= 2 else { return }
        store.select(projectId: parts[0], slug: parts[1])
        MainWindowController.shared.show(store: store)
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        panel.setPanelHidden(!panel.isPanelHidden)
    }

    @objc private func openMain() {
        MainWindowController.shared.show(store: store)
    }

    @objc private func openNotes() {
        NotesWindowController.shared.show(store: store)
    }

    @objc private func markAllSeen() { store.markAllSeen() }
    @objc private func refreshNow() { store.refreshNow() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
