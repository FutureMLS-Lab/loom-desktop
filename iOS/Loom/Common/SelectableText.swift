import SwiftUI
import UIKit

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// Something to open in the selection sheet.
struct SelectableItem: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    var monospaced = false
    var scrollToEnd = false
}

/// Text you can select any piece of, with the system's handles.
///
/// A long press on a message offers "Copy", which takes all of it; this is
/// for the part of it you actually wanted — a command out of a paragraph, a
/// path out of the terminal.
struct SelectableTextSheet: View {
    let item: SelectableItem
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            SelectableTextView(
                text: item.text,
                monospaced: item.monospaced,
                scrollToEnd: item.scrollToEnd
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy All") {
                        Clipboard.copy(item.text)
                        copied = true
                    }
                }
            }
        }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String
    var monospaced = false
    var scrollToEnd = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 28, right: 10)
        if monospaced {
            view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        } else {
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
        }
        view.text = text
        if scrollToEnd {
            DispatchQueue.main.async {
                view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
