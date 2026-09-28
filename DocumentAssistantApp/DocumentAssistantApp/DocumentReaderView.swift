import SwiftUI
import DocumentAssistant

/// Kind-aware reader. When the document is a PDF whose original file was retained
/// at import, it renders the real PDF via `PDFDocumentReader` and highlights the
/// cited passage on its page. Otherwise (TXT/Markdown, or a PDF imported before
/// source retention existed) it falls back to the extracted-text reader.
///
/// A citation is only applied when it belongs to this document, so a stale
/// `focusCitation` from another document never highlights the wrong file.
struct DocumentReaderView: View {
    let document: Document
    let assistant: DocumentAssistant
    var focusCitation: Citation? = nil
    /// Asks the host (ContentView) to present the deep-search sheet for a query.
    /// The sheet lives at the root so its results survive detail-pane swaps:
    /// a reader-owned sheet died with this view when opening a result replaced
    /// the document being searched. Nil disables the deep-search affordances.
    var onRequestDeepSearch: ((String) -> Void)? = nil

    @State private var sourceURL: URL?
    @State private var highlightText: String?
    @State private var highlightPage: Int?
    @State private var search = ""
    @State private var textFocus: NSRange?
    @State private var textMatches: [NSRange] = []
    @State private var textMatchIndex = 0
    @State private var pdfMatchCount = 0
    @State private var pdfMatchIndex = 0
    @State private var factCheckRequest: FactCheckRequest?
    /// The active reader's current text selection (PDF via `PDFViewSelectionChanged`,
    /// text via `UITextViewDelegate`). Drives the floating Fact Check button. The
    /// native edit call-out is suppressed in the text readers, so this button is the
    /// single selection affordance.
    @State private var selectedText: String?

    /// Fact Check is offered only on personal documents; confidential docs never
    /// enable the call-out action.
    private var allowFactCheck: Bool { document.category == .personal }

    private func requestFactCheck(_ text: String) {
        guard allowFactCheck else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        factCheckRequest = FactCheckRequest(text: trimmed)
        selectedText = nil
    }

    /// Deep Search runs across every document (read-only), so it is offered in
    /// all categories, unlike the personal-only Fact Check.
    private func requestDeepSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRequestDeepSearch?(trimmed)
        selectedText = nil
    }

    /// Floating selection pills shown when text is selected (PDF or text).
    /// The native edit call-out is suppressed in the text readers and can't be
    /// extended on iOS 26, so these buttons are the single, reliable selection
    /// affordance across all reader types.
    @ViewBuilder private var selectionButtons: some View {
        if let text = selectedText, !text.isEmpty {
            HStack(spacing: 12) {
                if allowFactCheck {
                    FactCheckButton { requestFactCheck(text) }
                }
                DeepSearchButton { requestDeepSearch(text) }
            }
        }
    }

    private var effectiveCitation: Citation? {
        guard let focusCitation, focusCitation.documentID == document.id else { return nil }
        return focusCitation
    }

    private var focusKey: String {
        "\(document.id.uuidString)|\(effectiveCitation?.id ?? "none")"
    }

    var body: some View {
        Group {
            if document.kind == .pdf, let sourceURL {
                PDFDocumentReader(
                    url: sourceURL,
                    highlightPage: highlightPage,
                    highlightText: highlightText,
                    findText: trimmedSearch.isEmpty ? nil : trimmedSearch,
                    findIndex: pdfMatchIndex,
                    onFindCount: { pdfMatchCount = $0 },
                    onSelectionChange: { selectedText = $0 }
                )
            } else {
                ScrollableTextReader(
                    text: document.text,
                    focus: textFocus,
                    onSelectionChange: { selectedText = $0 }
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { findBar }
        .searchable(text: $search, prompt: "Find in document")
        .onChange(of: search) { _, value in updateSearch(value) }
        .task(id: focusKey) { await resolve() }
        .overlay(alignment: .bottom) { selectionButtons }
        .animation(.easeInOut(duration: 0.15), value: selectedText)
        .sheet(item: $factCheckRequest) { request in
            FactCheckSheet(claim: request.text, assistant: assistant)
        }
        .navigationTitle(document.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Find

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isPDF: Bool { document.kind == .pdf && sourceURL != nil }
    private var totalMatches: Int { isPDF ? pdfMatchCount : textMatches.count }
    private var currentMatchIndex: Int { isPDF ? pdfMatchIndex : textMatchIndex }

    /// A find bar that surfaces the match count, offers a cross-document Deep
    /// Search for the current term, and lets the user step through in-document
    /// results, so searching visibly returns something instead of silently
    /// highlighting only the first hit.
    @ViewBuilder private var findBar: some View {
        if !trimmedSearch.isEmpty {
            HStack(spacing: 12) {
                Text(totalMatches == 0
                     ? "No matches"
                     : "\(min(currentMatchIndex + 1, totalMatches)) of \(totalMatches)")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button {
                    // Read the live `$search` binding on the next run-loop turn,
                    // not the render-time `trimmedSearch` snapshot: tapping this
                    // button resigns the search field, and iOS commits any
                    // uncommitted autocorrect/marked text only at that moment —
                    // reading the captured snapshot races the commit and can
                    // deep-search just the first few typed characters.
                    DispatchQueue.main.async {
                        requestDeepSearch($search.wrappedValue)
                    }
                } label: {
                    Label("Deep Search", systemImage: "text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color("SCBlue"))
                Button { previousMatch() } label: { Image(systemName: "chevron.up") }
                    .disabled(totalMatches == 0)
                Button { nextMatch() } label: { Image(systemName: "chevron.down") }
                    .disabled(totalMatches == 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func updateSearch(_ value: String) {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // For a real PDF, PDFKit's find drives matching; just reset the index.
        if isPDF { pdfMatchIndex = 0; return }
        guard !term.isEmpty else {
            textMatches = []
            textMatchIndex = 0
            textFocus = effectiveCitation?.utf16Range
            return
        }
        textMatches = Self.allRanges(of: term, in: document.text)
        textMatchIndex = 0
        textFocus = textMatches.first
    }

    private func nextMatch() {
        guard totalMatches > 0 else { return }
        if isPDF {
            pdfMatchIndex = (pdfMatchIndex + 1) % pdfMatchCount
        } else {
            textMatchIndex = (textMatchIndex + 1) % textMatches.count
            textFocus = textMatches[textMatchIndex]
        }
    }

    private func previousMatch() {
        guard totalMatches > 0 else { return }
        if isPDF {
            pdfMatchIndex = (pdfMatchIndex - 1 + pdfMatchCount) % pdfMatchCount
        } else {
            textMatchIndex = (textMatchIndex - 1 + textMatches.count) % textMatches.count
            textFocus = textMatches[textMatchIndex]
        }
    }

    private static func allRanges(of term: String, in text: String) -> [NSRange] {
        guard !term.isEmpty else { return [] }
        let source = text as NSString
        var results: [NSRange] = []
        var start = 0
        while start < source.length {
            let found = source.range(of: term, options: .caseInsensitive,
                                     range: NSRange(location: start, length: source.length - start))
            if found.location == NSNotFound || found.length == 0 { break }
            results.append(found)
            start = NSMaxRange(found)
        }
        return results
    }

    private func resolve() async {
        sourceURL = await assistant.sourceURL(for: document.id)
        guard let citation = effectiveCitation else {
            highlightText = nil
            highlightPage = nil
            textFocus = nil
            return
        }
        highlightPage = citation.page
        textFocus = citation.utf16Range
        if let conceptID = citation.conceptID,
           let concept = try? await assistant.readConcept(id: conceptID) {
            highlightText = concept.body
        } else {
            highlightText = nil
        }
    }
}

/// An Identifiable wrapper so the fact-check sheet can be presented via `.sheet(item:)`.
struct FactCheckRequest: Identifiable {
    let id = UUID()
    let text: String
}
