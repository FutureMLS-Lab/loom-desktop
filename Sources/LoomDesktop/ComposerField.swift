import AppKit
import SwiftUI

/// The terminal's compose box: Enter sends, Shift+Enter starts a new line.
///
/// This is an `NSTextView` rather than a SwiftUI `TextField` because those
/// three behaviours have to be told apart at the keystroke, and only AppKit
/// exposes enough to do it:
///
/// - Shift+Enter has to insert a newline instead of submitting, which a
///   `TextField` gives no way to distinguish.
/// - The Enter that *commits* an input-method composition must be left alone.
///   Sending on it would fire off a half-finished sentence the moment you
///   accepted Chinese candidates — so the composing state has to be checked
///   before Return is interpreted at all.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    /// Bumped by the owner when it means to replace the contents — after a
    /// send, say. Without it there is no way to tell a deliberate clear from
    /// a stale value arriving mid-keystroke, and one of the two has to lose.
    var contentRevision: Int
    var placeholder: String
    var fontSize: CGFloat = 14.5
    var focusOnAppear = false
    var onSubmit: () -> Void

    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 108

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = NSColor(TerminalTheme.text)
        textView.insertionPointColor = NSColor(TerminalTheme.inkAccent)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.string = text
        textView.focusOnAppear = focusOnAppear

        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        textView.placeholder = placeholder

        // An intentional replacement always applies, even with the caret in
        // the field — that is how the box empties after sending.
        if context.coordinator.contentRevision != contentRevision {
            context.coordinator.contentRevision = contentRevision
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                textView.needsDisplay = true
                context.coordinator.reportHeight()
            }
            return
        }

        // Otherwise leave the field alone while it is being typed in: the
        // binding round-trips through published state, so a value arriving
        // late would fight what was just typed.
        let isTyping = textView.window?.firstResponder === textView
        if !isTyping, textView.string != text {
            textView.string = text
            context.coordinator.reportHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?
        var contentRevision: Int

        init(_ parent: ComposerField) {
            self.parent = parent
            self.contentRevision = parent.contentRevision
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            reportHeight()
        }

        /// Grow with the text, up to a few lines, then scroll.
        func reportHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let height = min(
                max(used + textView.textContainerInset.height * 2, ComposerField.minHeight),
                ComposerField.maxHeight
            )
            if abs(parent.measuredHeight - height) > 0.5 {
                parent.measuredHeight = height
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = ""
    var focusOnAppear = false
    private var hasFocused = false

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            // Mid-composition, Return belongs to the input method: it accepts
            // the candidate rather than sending anything.
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
                return
            }
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, !hasFocused, window != nil else { return }
        hasFocused = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 14.5),
            .foregroundColor: NSColor(TerminalTheme.dimText).withAlphaComponent(0.65),
        ]
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}
