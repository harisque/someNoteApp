import SwiftUI
import UIKit

/// Read-only, selectable text view that can scroll to and highlight an exact
/// UTF-16 range. Used by the document reader so a citation opens the precise
/// source passage instead of jumping to the top of the document.
struct ScrollableTextReader: UIViewRepresentable {
    let text: String
    var focus: NSRange? = nil
    /// When true, `text` is rendered as Markdown (headings, emphasis, code, lists)
    /// instead of plain text. Used by the note preview. Imported documents keep
    /// plain rendering so citation highlight ranges (raw UTF-16 offsets) stay valid.
    var rendersMarkdown: Bool = false
    /// Reports the current selection (or nil when empty) so the host can show or
    /// hide its Fact Check button. The host gates this to personal documents.
    var onSelectionChange: ((String?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SelectableTextView {
        let textView = SelectableTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: SelectableTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectionChange = onSelectionChange
        let focusKey = Self.key(for: focus)
        if coordinator.lastText != text {
            coordinator.lastText = text
            coordinator.lastFocusKey = focusKey
            apply(textView, highlight: focus)
            return
        }
        if coordinator.lastFocusKey != focusKey {
            coordinator.lastFocusKey = focusKey
            apply(textView, highlight: focus)
        }
    }

    private func apply(_ textView: UITextView, highlight: NSRange?) {
        textView.attributedText = Self.attributed(text, highlight: highlight, markdown: rendersMarkdown)
        if let highlight, highlight.length > 0 {
            textView.layoutIfNeeded()
            textView.scrollRangeToVisible(highlight)
        }
    }

    private static func key(for range: NSRange?) -> String? {
        guard let range else { return nil }
        return "\(range.location):\(range.length)"
    }

    private static func attributed(_ text: String, highlight: NSRange?, markdown: Bool) -> NSAttributedString {
        // Note previews render Markdown block-by-block; imported documents stay plain
        // so citation highlight ranges (raw UTF-16 offsets into the source) remain valid.
        if markdown { return MarkdownTextRenderer.render(text) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        // Ranges are UTF-16 offsets, matching NSAttributedString's own indexing.
        if let highlight,
           highlight.location >= 0,
           highlight.length > 0,
           NSMaxRange(highlight) <= attributed.length {
            attributed.addAttribute(
                .backgroundColor,
                value: UIColor.systemYellow.withAlphaComponent(0.35),
                range: highlight
            )
        }
        return attributed
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastText: String?
        var lastFocusKey: String?
        var onSelectionChange: ((String?) -> Void)?

        /// Reports selection changes to the host. Deferred to the next run-loop turn
        /// because assigning `attributedText` during a view update also fires this,
        /// and mutating SwiftUI state mid-update is not allowed.
        func textViewDidChangeSelection(_ textView: UITextView) {
            let selected: String?
            if let range = textView.selectedTextRange, !range.isEmpty,
               let text = textView.text(in: range),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selected = text
            } else {
                selected = nil
            }
            let handler = onSelectionChange
            DispatchQueue.main.async { handler?(selected) }
        }
    }
}

/// A read-only `UITextView` that suppresses the native edit call-out menu
/// (Copy / Select All / Look Up / Translate / Share). Fact Check is offered through
/// the host's floating button instead, which works reliably on iOS 26 — the
/// deprecated `UIMenuController` custom items no longer appear in the edit menu.
/// Returning `false` for every action leaves the menu empty so it is not presented;
/// text selection and its handles still work normally.
final class SelectableTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}
