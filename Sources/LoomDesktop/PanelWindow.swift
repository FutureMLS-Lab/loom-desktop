import AppKit
import SwiftUI

/// Lets clicks land on SwiftUI controls even while the panel is not key:
/// a non-key window's first click is offered to `acceptsFirstMouse`, and
/// refusing it means the pill under the cursor never hears about the click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The always-on-top dock. A titled window with both its title bar and its
/// traffic lights hidden — the dock is a card, not a document window — while
/// the SwiftUI header carries the loom menu and the hide button. It opens at
/// the top of the screen but can be dragged anywhere and stays put.
/// NOT `.borderless` — macOS 26 (Tahoe) has an Apple-confirmed
/// system regression where borderless windows stop receiving clicks and
/// drags entirely, so the whole design rides on the ordinary titled path.
final class PanelWindow: NSPanel, NSWindowDelegate {
    private static let widthDefaultsKey = "panelWidth"
    private static let defaultWidth: CGFloat = 560
    /// Floor for a drag before any pill has been measured; once there is
    /// content the real limit is the widest single row (header or pill).
    private static let minimumWidth: CGFloat = 240
    /// Enough for the header strip and a sliver of the rows below it.
    private static let minimumHeight: CGFloat = 60
    private static let heightDefaultsKey = "panelHeight"

    private var hosting: NSHostingView<DockView>!
    private var store: TaskStore!

    /// The width the user dragged the panel to. Kept apart from the live frame
    /// width so a panel forced wider by an unusually long pill still returns to
    /// the chosen width once that pill goes away.
    private var userWidth: CGFloat = PanelWindow.savedWidth
    /// The height dragged to, or 0 while it still follows the content.
    private var userHeight: CGFloat = PanelWindow.savedHeight
    private var metrics = WrappingHStack.Metrics(contentSize: .zero, widestSubview: 0)

    init(store: TaskStore) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.savedWidth, height: 64),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the full-screen system overlays (Dock's desktop-click layer
        // sits at 20, i.e. over `.floating`) so nothing shadows the pills.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        // The panel may take key when a click genuinely needs it, but never
        // just because it was clicked — pill clicks stay non-activating.
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        // The window is bigger than the visible card (see DockView.cardMargin),
        // so a window shadow would float detached around it; the card draws
        // its own instead.
        hasShadow = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // No separator line between the invisible title bar and the content.
        titlebarSeparatorStyle = .none
        // No traffic lights: the dock is a card, not a document window, and
        // the header's own hide/collapse buttons cover what they would do.
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(buttonType)?.isHidden = true
        }
        minSize = NSSize(width: Self.minimumWidth, height: 1)
        delegate = self

        hosting = FirstMouseHostingView(rootView: DockView(store: store))
        // Without this the hosting view constrains the window to the content's
        // ideal size, which for a wrapping layout is one long unwrapped row.
        hosting.sizingOptions = []
        contentView = hosting

        hosting.rootView.onMeasure = { [weak self] metrics in
            guard let self = self, metrics.contentSize.height > 0, metrics != self.metrics else { return }
            if ProcessInfo.processInfo.environment["LOOM_DESKTOP_TRACE_LAYOUT"] == "1" {
                loomBoot("measure content=\(metrics.contentSize) widest=\(metrics.widestSubview) overflow=\(metrics.overflow) -> height \(self.contentHeight)")
            }
            self.metrics = metrics
            self.applyGeometry()
        }
        hosting.rootView.onHidePanel = { [weak self] in
            self?.setPanelHidden(true)
        }
        hosting.rootView.onFitToContents = { [weak self] in
            self?.fitToContents()
        }

        reposition()
    }

    /// Called only for user-driven resizes, which makes it the place to learn
    /// the size the user wants — both ways, so a corner drag does what a
    /// corner drag looks like it should.
    ///
    /// Dragging the height also fixes it: from then on the dock stays that
    /// tall and the rows scroll inside it, rather than growing down the screen
    /// as tasks appear. `fitToContents()` gives that back.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        userWidth = max(Self.minimumWidth, frameSize.width)
        userHeight = max(Self.minimumHeight, frameSize.height)
        persistSize()
        return NSSize(width: clampedWidth, height: userHeight)
    }

    /// Back to a dock exactly as tall as what is in it.
    func fitToContents() {
        userHeight = 0
        persistSize()
        applyGeometry()
    }

    private func frameSizeFitting(content: NSSize) -> NSSize {
        frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    /// Width is the user's choice, only widened when a single pill cannot fit
    /// (pills are never broken mid-way). Height follows the wrapped rows plus
    /// the header strip, growing downward from a fixed top edge — unless a
    /// height was dragged, which the content then scrolls within.
    private func applyGeometry() {
        // Sizes here are the *content* size; the window frame is taller by the
        // title bar, and setting the frame to a content height is what clipped
        // the bottom row off the dock.
        var target = frameSizeFitting(content: NSSize(width: clampedWidth, height: contentHeight))
        if userHeight > 0 { target.height = userHeight }
        guard abs(target.width - frame.width) > 0.5 || abs(target.height - frame.height) > 0.5
        else { return }

        var updated = frame
        updated.size = target
        // Grow downward from a fixed top edge, so the dock never creeps up
        // off the screen as rows appear.
        updated.origin.y = frame.maxY - target.height
        setFrame(updated, display: true)
    }

    /// The width the user dragged to, never narrower than a single pill and
    /// never wider than the screen. Deliberately *not* derived from the
    /// measured row: sizing the window to the content it just packed shrinks
    /// the limit, which drops a pill, which shrinks it again — a ratchet down
    /// to the minimum. The content fits the width, not the other way round.
    private var clampedWidth: CGFloat {
        let screenLimit = (NSScreen.screens.first { $0.frame.contains(frame.origin) }
            ?? NSScreen.main)?.visibleFrame.width ?? 1440
        let floorWidth = max(
            Self.minimumWidth,
            metrics.widestSubview + 2 * DockView.contentInset + 2 * DockView.cardMargin
        )
        return ceil(min(max(userWidth, floorWidth), screenLimit - 40))
    }

    private var contentHeight: CGFloat {
        guard metrics.contentSize.height > 0 else {
            return contentRect(forFrameRect: frame).height
        }
        // Rows + the card's padding + the transparent margin the card is
        // inset by, so the window's rounded corners never reach the content.
        return ceil(
            metrics.contentSize.height
                + 2 * DockView.contentInset
                + 2 * DockView.cardMargin
        )
    }

    // MARK: Show / hide

    private static let hiddenDefaultsKey = "panelHidden"

    var isPanelHidden: Bool {
        UserDefaults.standard.bool(forKey: Self.hiddenDefaultsKey)
    }

    /// Hiding the panel is remembered across launches; the menu-bar item is
    /// the way back. Showing summons it to the screen the mouse is on.
    func setPanelHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: Self.hiddenDefaultsKey)
        if hidden {
            orderOut(nil)
        } else {
            reposition()
            orderFrontRegardless()
        }
    }

    func reposition() {
        // The screen the mouse is on — that is where the user is looking.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let size = frame.size
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 8
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static var savedWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: widthDefaultsKey)
        return saved >= minimumWidth ? saved : defaultWidth
    }

    /// Zero means "as tall as the content", which is the default and what
    /// `fitToContents()` returns to.
    private static var savedHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: heightDefaultsKey)
        return saved >= minimumHeight ? saved : 0
    }

    private func persistSize() {
        UserDefaults.standard.set(Double(userWidth), forKey: Self.widthDefaultsKey)
        UserDefaults.standard.set(Double(userHeight), forKey: Self.heightDefaultsKey)
    }

    func windowWillClose(_ notification: Notification) {
        // The window's own close button hides rather than destroys.
        setPanelHidden(true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
