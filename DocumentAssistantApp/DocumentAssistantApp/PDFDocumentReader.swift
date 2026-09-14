import SwiftUI
import PDFKit
import UIKit

/// Renders the ORIGINAL imported PDF and draws a transient highlight over a cited
/// passage. Highlights are overlays only: the stored file is never modified (no
/// `write(to:)`), so re-opening or clearing a citation leaves the PDF untouched.
///
/// The citation is mapped by (1-based) page + passage text rather than the global
/// UTF-16 offset, because the extracted-text offsets do not correspond to PDFKit's
/// per-page string. `locate` finds the passage within the page's own text.
struct PDFDocumentReader: UIViewRepresentable {
    let url: URL
    var highlightPage: Int?
    var highlightText: String?
    var findText: String? = nil
    var findIndex: Int = 0
    var onFindCount: ((Int) -> Void)? = nil
    /// Reports the current PDF text selection (or nil when empty) so the host can
    /// offer a Fact Check action. PDFKit presents its own selection call-out via an
    /// internal `UIEditMenuInteraction` and ignores custom `UIMenuController` items
    /// on iOS 26, so selection is observed here and acted on with an explicit button.
    var onSelectionChange: ((String?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        context.coordinator.observeSelection(of: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coord = context.coordinator
        coord.onSelectionChange = onSelectionChange
        if coord.lastURL != url {
            coord.lastURL = url
            coord.document = PDFDocument(url: url)
            coord.lastHighlightKey = nil
            coord.lastFind = nil
            coord.findSelections = []
            coord.lastFindIndex = -1
            coord.clearOverlays()
            coord.clearFindOverlays()
            view.document = coord.document
        }
        guard let document = coord.document else { return }

        let key = Self.highlightKey(page: highlightPage, text: highlightText)
        if coord.lastHighlightKey != key {
            coord.lastHighlightKey = key
            applyHighlight(view: view, document: document, coordinator: coord)
        }

        if let findText, !findText.isEmpty {
            if coord.lastFind != findText {
                coord.lastFind = findText
                coord.findSelections = document.findString(findText, withOptions: [.caseInsensitive])
                coord.lastFindIndex = -1
                coord.clearFindOverlays()
                addFindOverlays(coord.findSelections, coordinator: coord)
                report(coord.findSelections.count)
            }
            let count = coord.findSelections.count
            if count > 0 {
                let index = min(max(findIndex, 0), count - 1)
                if coord.lastFindIndex != index {
                    coord.lastFindIndex = index
                    view.setCurrentSelection(coord.findSelections[index], animate: true)
                    view.scrollSelectionToVisible(true)
                }
            }
        } else if coord.lastFind != nil {
            coord.lastFind = nil
            coord.findSelections = []
            coord.lastFindIndex = -1
            coord.clearFindOverlays()
            view.setCurrentSelection(nil, animate: false)
            report(0)
        }
    }

    private func applyHighlight(view: PDFView, document: PDFDocument, coordinator coord: Coordinator) {
        coord.clearOverlays()
        guard let pageNumber = highlightPage, pageNumber > 0,
              let page = document.page(at: pageNumber - 1) else { return }
        view.go(to: page)
        guard let text = highlightText, !text.isEmpty,
              let range = Self.locate(text, in: page.string ?? ""),
              let selection = page.selection(for: range) else { return }
        for line in selection.selectionsByLine() {
            let bounds = line.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = UIColor.systemYellow.withAlphaComponent(0.4)
            page.addAnnotation(annotation)
            coord.overlays.append((page, annotation))
        }
        view.setCurrentSelection(selection, animate: true)
        view.scrollSelectionToVisible(true)
    }

    static func highlightKey(page: Int?, text: String?) -> String? {
        guard page != nil || text != nil else { return nil }
        return "\(page ?? -1)|\(text ?? "")"
    }

    /// Locates a passage within a single page's text. Tries an exact
    /// case-insensitive match first, then the first line, then the first words,
    /// so a highlight degrades gracefully instead of vanishing.
    static func locate(_ text: String, in page: String) -> NSRange? {
        let pageNS = page as NSString
        let full = NSRange(location: 0, length: pageNS.length)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var found = pageNS.range(of: trimmed, options: .caseInsensitive, range: full)
        if found.location != NSNotFound { return found }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        if firstLine.count >= 4 {
            found = pageNS.range(of: firstLine, options: .caseInsensitive, range: full)
            if found.location != NSNotFound { return found }
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(8).joined(separator: " ")
        if words.count >= 4 {
            found = pageNS.range(of: words, options: .caseInsensitive, range: full)
            if found.location != NSNotFound { return found }
        }
        return nil
    }

    /// Draws a persistent highlight annotation over every find match so results
    /// stay visible. A plain `currentSelection` tint is transient and disappears
    /// between view updates (the "flashes then gone" symptom); annotations are
    /// page objects that persist until explicitly removed. They are tracked
    /// separately from citation overlays so the two never clobber each other.
    private func addFindOverlays(_ selections: [PDFSelection], coordinator coord: Coordinator) {
        // Bound the work: a single common letter in a large PDF could otherwise
        // produce thousands of annotations. The reported count is still exact;
        // navigation past this cap relies on the active selection + scroll.
        var budget = 500
        for selection in selections {
            if budget <= 0 { break }
            for line in selection.selectionsByLine() {
                if budget <= 0 { break }
                guard let page = line.pages.first else { continue }
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemOrange.withAlphaComponent(0.35)
                page.addAnnotation(annotation)
                coord.findOverlays.append((page, annotation))
                budget -= 1
            }
        }
    }

    /// Reports the match count to the parent without mutating its state during a
    /// view update (deferred to the next run-loop turn).
    private func report(_ count: Int) {
        guard let onFindCount else { return }
        DispatchQueue.main.async { onFindCount(count) }
    }

    final class Coordinator {
        var document: PDFDocument?
        var lastURL: URL?
        var lastHighlightKey: String?
        var lastFind: String?
        var findSelections: [PDFSelection] = []
        var lastFindIndex = -1
        var overlays: [(PDFPage, PDFAnnotation)] = []
        var findOverlays: [(PDFPage, PDFAnnotation)] = []
        var onSelectionChange: ((String?) -> Void)?
        private var selectionObserver: NSObjectProtocol?

        /// Observes PDFKit selection changes and forwards the selected text (or nil)
        /// so the host can show or hide its Fact Check button. The update is deferred
        /// to the next run-loop turn to avoid mutating SwiftUI state mid-update.
        func observeSelection(of view: PDFView) {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                let selected = view?.currentSelection?.string
                let text = selected?.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = (text?.isEmpty == false) ? text : nil
                DispatchQueue.main.async { self?.onSelectionChange?(value) }
            }
        }

        func clearOverlays() {
            for (page, annotation) in overlays { page.removeAnnotation(annotation) }
            overlays.removeAll()
        }

        func clearFindOverlays() {
            for (page, annotation) in findOverlays { page.removeAnnotation(annotation) }
            findOverlays.removeAll()
        }

        deinit {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }
    }
}
