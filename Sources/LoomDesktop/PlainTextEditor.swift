import AppKit
import SwiftUI

/// Editable `NSTextView` for markdown source. Avoids SwiftUI `Text` /
/// `AttributedString(markdown:)` which stalls the main thread on big plans.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: [
                .font: font ?? .systemFont(ofSize: 13.5),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
    }
}

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var documentID: String
    /// Parent bumps this when the binding was replaced externally (load / switch).
    var contentRevision: Int
    var editable: Bool
    var fontSize: Double
    /// Shown when the file is empty, so a new one does not read as a failure
    /// to load.
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(LoomColors.bgElev1)

        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(LoomColors.bgElev1)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor(LoomColors.accent)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        // ⌘F. The bar drops in above the text and searches as you type; the
        // Edit ▸ Find menu is what routes the shortcut here.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.documentID = documentID
        context.coordinator.contentRevision = contentRevision
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        (textView as? PlaceholderTextView)?.placeholder = placeholder
        textView.isEditable = editable
        textView.isSelectable = true
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != font { textView.font = font }

        // Only replace the buffer on an explicit document/content change.
        // Never push the SwiftUI binding back while the user is typing — that
        // is what made characters appear to vanish.
        let documentChanged = context.coordinator.documentID != documentID
        let revisionChanged = context.coordinator.contentRevision != contentRevision
        if documentChanged || revisionChanged {
            context.coordinator.documentID = documentID
            context.coordinator.contentRevision = contentRevision
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                if documentChanged {
                    textView.scrollToBeginningOfDocument(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var documentID = ""
        var contentRevision = -1

        init(text: Binding<String>) { self.text = text }

        func textDidEndEditing(_ notification: Notification) {
            if let textView {
                text.wrappedValue = textView.string
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
        }
    }
}
