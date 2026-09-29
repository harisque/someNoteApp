import SwiftUI
import DocumentAssistant

/// The assistant (Ask) UI shared by both layouts: a grouped scope picker, a live
/// tool-status feed, the streamed answer with citation chips, the ask bar, and
/// "Save to Note" (routed to Confidential or Personal AI Notes by the answer's scope).
///
/// Document/folder browsing lives in `DocumentManagerView`, not here. This panel
/// owns the conversation state and drives `assistant.answer`. Citation taps are
/// forwarded to `onOpenCitation` so each layout can react (iPad: focus the reader
/// in place; iPhone: push the reader). Saving a note calls `onDocumentsChanged`
/// and `onOpenDocument` so the host refreshes and opens the new note.
struct AssistantPanel: View {
    let assistant: DocumentAssistant
    let documents: [Document]
    let folders: [Folder]
    /// Confidential live-data assets that can be scoped into a question alongside
    /// documents; their ids share `scopeIDs` with document ids.
    let dataLinks: [DataLink]
    /// Ids of documents whose background embedding job is still running. Ask stays
    /// disabled while any document in the effective scope is in this set, so a
    /// question never runs against half-built vectors.
    var pendingEmbeddingIDs: Set<UUID> = []
    /// Whether the chat model is already resident (mirrors the launch gate). The
    /// gate normally blocks entry until the model is ready, so the first question
    /// must not claim "Starting on-device model…" when it is already warm.
    var modelWarm: Bool = false
    var onOpenCitation: (Citation) -> Void
    var onOpenDocument: (UUID) -> Void
    var onDocumentsChanged: () -> Void
    var onRequestTestMode: () -> Void

    @State private var query = ""
    @State private var askedQuestion = ""
    @State private var response = ""
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var activity: [ActivityStep] = []
    /// Citations the answer actually used (a subset of `packedCitations`). This is
    /// what the chip row and a saved note list, so unused evidence that merely fit
    /// in the prompt is no longer offered for browsing.
    @State private var answerCitations: [Citation] = []
    /// Every excerpt packed into the prompt, kept for status counts and for
    /// mapping a used citation back to the `[n]` number the answer cited.
    @State private var packedCitations: [Citation] = []
    /// Candidates surviving hybrid fusion, reported by the ranking stage.
    @State private var candidateCount = 0
    /// Scope of the next question: ids of the chosen documents and/or Data Links.
    /// Empty means "all sources" (the default).
    @State private var scopeIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var modelWarmedUp = false

    @State private var isSavingNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }

            askContent

            HStack {
                Image(systemName: "iphone")
                Text("Powered by On-Device AI")
                    .font(.footnote.bold())
                    .foregroundStyle(Color("SCGreen"))
                Spacer()
            }
        }
        .padding(.horizontal)
        .onChange(of: documents) { _, _ in pruneScope() }
        .onChange(of: dataLinks) { _, _ in pruneScope() }
        .onDisappear { generationTask?.cancel() }
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--model-smoke-test") { query = "Reply with OK."; send() }
            #endif
        }
    }

    // MARK: - Ask mode

    private var askContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolStatusView(steps: activity)

            scopePicker

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if askedQuestion.isEmpty && response.isEmpty {
                        Text("Ask a question, or tap a quick prompt below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        if !askedQuestion.isEmpty {
                            Text(askedQuestion)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if !response.isEmpty {
                            MarkdownAnswerView(text: response)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 60, maxHeight: .infinity)
        }
        // Dock the input section to the safe-area edge instead of stacking it under a
        // flexible ScrollView: SwiftUI keeps a `safeAreaInset` bottom bar above the
        // keyboard on iPhone, whereas the plain VStack let the keyboard cover the ask
        // bar once the answer region collapsed to its minimum height.
        .safeAreaInset(edge: .bottom, spacing: 10) { askDock }
    }

    /// Citations, note action, quick prompts, and the ask bar, pinned to the bottom
    /// of the panel (and lifted above the keyboard while typing). The opaque
    /// background is required: the answer ScrollView extends underneath a bottom
    /// `safeAreaInset`, so without it the streamed text shows through the dock.
    private var askDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !answerCitations.isEmpty { citationChips }

            saveToNoteButton

            quickPromptBar

            askBar
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var scopeLabel: String {
        let total = documents.count + dataLinks.count
        guard total > 0 else { return "Nothing to ask yet" }
        if scopeIDs.isEmpty {
            return "Asking: all \(total) source\(total == 1 ? "" : "s")"
        }
        if scopeIDs.count == 1, let only = scopeIDs.first, let name = scopeName(for: only) {
            return "Asking: \(name)"
        }
        return "Asking: \(scopeIDs.count) of \(total) sources"
    }

    /// The display name for a scope id, whether it names a document or a Data Link.
    private func scopeName(for id: UUID) -> String? {
        documents.first(where: { $0.id == id })?.name
            ?? dataLinks.first(where: { $0.id == id })?.name
    }

    /// A user-facing scope option that shows what the question will search and
    /// lets the user narrow it to a chosen subset across categories/folders. An
    /// empty selection means "all documents" (the default). Documents are grouped
    /// by category and folder, and each group has a select-all/clear-all action.
    private var scopePicker: some View {
        Menu {
            Button {
                scopeIDs = []
            } label: {
                if scopeIDs.isEmpty { Label("All sources", systemImage: "checkmark") }
                else { Text("All sources") }
            }
            if !documents.isEmpty || !dataLinks.isEmpty { Divider() }
            ForEach(scopeGroups) { group in
                Section {
                    Button { toggleGroup(group) } label: {
                        if isGroupFullySelected(group) {
                            Label("Clear group", systemImage: "circle")
                        } else {
                            Label("Select all in group", systemImage: "checkmark.circle")
                        }
                    }
                    ForEach(group.docs) { document in
                        Button { toggle(document) } label: {
                            if scopeIDs.contains(document.id) { Label(document.name, systemImage: "checkmark") }
                            else { Text(document.name) }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
            if !dataLinks.isEmpty {
                Divider()
                Section {
                    Button { toggleAllDataLinks() } label: {
                        if allDataLinksSelected {
                            Label("Clear group", systemImage: "circle")
                        } else {
                            Label("Select all in group", systemImage: "checkmark.circle")
                        }
                    }
                    ForEach(dataLinks) { link in
                        Button { toggleDataLink(link) } label: {
                            if scopeIDs.contains(link.id) {
                                Label(link.name, systemImage: "checkmark")
                            } else {
                                Text(link.name)
                            }
                        }
                    }
                } header: {
                    Text("Data Links")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text(scopeLabel)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
    }

    // MARK: - Scope grouping

    private struct ScopeGroup: Identifiable {
        let id: String
        let title: String
        let docs: [Document]
    }

    /// Groups documents for the scope picker: Confidential then Personal, each as a
    /// top-level group plus one group per folder (including the permanent AI Notes
    /// system folder, which carries that category's notes).
    private var scopeGroups: [ScopeGroup] {
        var groups: [ScopeGroup] = []
        appendCategoryGroups(.confidential, "Confidential", to: &groups)
        appendCategoryGroups(.personal, "Personal", to: &groups)
        return groups
    }

    private func appendCategoryGroups(_ category: DocumentCategory, _ name: String, to groups: inout [ScopeGroup]) {
        let root = documents.filter { $0.category == category && $0.folderID == nil && !$0.isNote }
        if !root.isEmpty {
            groups.append(ScopeGroup(id: "\(category.rawValue)-root", title: name, docs: root))
        }
        for folder in folders.filter({ $0.category == category }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let docs = documents.filter { $0.folderID == folder.id }
            if !docs.isEmpty {
                groups.append(ScopeGroup(id: folder.id.uuidString, title: "\(name) · \(folder.name)", docs: docs))
            }
        }
    }

    private func toggle(_ document: Document) {
        if scopeIDs.contains(document.id) { scopeIDs.remove(document.id) }
        else { scopeIDs.insert(document.id) }
    }

    private func isGroupFullySelected(_ group: ScopeGroup) -> Bool {
        !group.docs.isEmpty && group.docs.allSatisfy { scopeIDs.contains($0.id) }
    }

    private func toggleGroup(_ group: ScopeGroup) {
        if isGroupFullySelected(group) {
            for doc in group.docs { scopeIDs.remove(doc.id) }
        } else {
            for doc in group.docs { scopeIDs.insert(doc.id) }
        }
    }

    // MARK: - Data Link scope

    private var allDataLinksSelected: Bool {
        !dataLinks.isEmpty && dataLinks.allSatisfy { scopeIDs.contains($0.id) }
    }

    private func toggleDataLink(_ link: DataLink) {
        if scopeIDs.contains(link.id) { scopeIDs.remove(link.id) }
        else { scopeIDs.insert(link.id) }
    }

    private func toggleAllDataLinks() {
        if allDataLinksSelected {
            for link in dataLinks { scopeIDs.remove(link.id) }
        } else {
            for link in dataLinks { scopeIDs.insert(link.id) }
        }
    }

    /// Drops scope ids whose entity (document or Data Link) no longer exists so a
    /// deletion can't leave a dangling selection.
    private func pruneScope() {
        scopeIDs = scopeIDs.filter { id in
            documents.contains(where: { $0.id == id }) || dataLinks.contains(where: { $0.id == id })
        }
    }

    private var citationChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(answerCitations.enumerated()), id: \.element.id) { index, citation in
                    Button { onOpenCitation(citation) } label: {
                        Label {
                            Text("Excerpt \(excerptNumber(for: citation, fallback: index + 1))").bold()
                                + Text(" · \(citationLabel(citation))")
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The number the answer cited this source as. Prompt excerpts are numbered by
    /// packed order, so the label has to come from `packedCitations` rather than
    /// the (shorter) used list — otherwise citing `[3]` and `[7]` would display as
    /// "Excerpt 1" and "Excerpt 2".
    private func excerptNumber(for citation: Citation, fallback: Int) -> Int {
        packedCitations.firstIndex(of: citation).map { $0 + 1 } ?? fallback
    }

    @ViewBuilder private var saveToNoteButton: some View {
        if !response.isEmpty {
            Button { saveToNote() } label: {
                HStack(spacing: 6) {
                    if isSavingNote {
                        ProgressView().controlSize(.small)
                        Text("Saving note…")
                    } else {
                        Image(systemName: "note.text.badge.plus")
                        Text("Save to Note")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isGenerating || isSavingNote)
        }
    }

    /// Documents in the effective scope that are still embedding. An empty scope
    /// means "all sources," so any pending document blocks. Data Links never block
    /// (they carry no chunk embeddings).
    private var blockingEmbeddings: [Document] {
        let effective: Set<UUID> = scopeIDs.isEmpty ? Set(documents.map(\.id)) : scopeIDs
        return documents.filter { pendingEmbeddingIDs.contains($0.id) && effective.contains($0.id) }
    }
    private var isAskBlocked: Bool { !blockingEmbeddings.isEmpty }
    private var embeddingHint: String {
        let names = blockingEmbeddings.map(\.name)
        let shown = names.prefix(2).joined(separator: ", ")
        let extra = names.count > 2 ? " +\(names.count - 2) more" : ""
        return "Waiting for “\(shown)\(extra)” to finish embedding…"
    }

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isAskBlocked {
                Label(embeddingHint, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                TextField("Ask about your documents", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { send() }
                    .disabled(isGenerating || isAskBlocked || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isGenerating { Button("Stop") { generationTask?.cancel() } }
            }
        }
    }

    /// One-click starter prompts. Tapping sends immediately against the current scope.
    /// Laid out with a wrapping flow so every chip stays fully readable at narrow
    /// inspector widths (a horizontal scroller clipped the trailing chips).
    private let quickPrompts = [
        "Summarize this document",
        "List key risks",
        "Important dates & deadlines",
        "Explain key terms"
    ]

    private var quickPromptBar: some View {
        FlowLayout(spacing: 8) {
            ForEach(quickPrompts, id: \.self) { prompt in
                Button {
                    query = prompt
                    send()
                } label: {
                    Text(prompt)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color("SCBlue").opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color("SCBlue").opacity(0.35), lineWidth: 1))
                        .foregroundStyle(Color("SCBlue"))
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isAskBlocked)
            }
        }
    }

    private func citationLabel(_ citation: Citation) -> String {
        citation.document + (citation.page.map { ", p\($0)" } ?? "")
    }

    // MARK: - Note actions

    /// Saves the current answer to a NEW note. Gated on `!isGenerating` so it
    /// never overlaps the answer's model call; generates a title from the asked
    /// question (on-device, with a deterministic fallback in the package).
    private func saveToNote() {
        guard !isGenerating, !response.isEmpty, !isSavingNote else { return }
        isSavingNote = true
        Task {
            defer { isSavingNote = false }
            do {
                let title = askedQuestion.isEmpty
                    ? "Saved note"
                    : await assistant.generateNoteTitle(from: askedQuestion)
                // Route by the answer's scope: if it touched any Confidential doc
                // (empty scope = "All documents" counts whenever one exists), the
                // note may contain confidential info, so file it under Confidential.
                let scopedDocs = scopeIDs.isEmpty ? documents : documents.filter { scopeIDs.contains($0.id) }
                let scopedLinks = scopeIDs.isEmpty ? dataLinks : dataLinks.filter { scopeIDs.contains($0.id) }
                let touchesConfidential = scopedDocs.contains { $0.category == .confidential }
                    || scopedLinks.contains { $0.category == .confidential }
                let category: DocumentCategory = touchesConfidential ? .confidential : .personal
                let id = try await assistant.createNote(title: title, text: makeNoteBody(title: title), category: category)
                onDocumentsChanged()
                onOpenDocument(id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeNoteBody(title: String) -> String {
        var lines: [String] = []
        lines.append("## \(askedQuestion.isEmpty ? title : askedQuestion)")
        lines.append("_Saved \(Self.noteDateFormatter.string(from: Date()))_")
        lines.append("")
        lines.append(response.trimmingCharacters(in: .whitespacesAndNewlines))
        if !answerCitations.isEmpty {
            lines.append("")
            lines.append("### Sources")
            for (index, citation) in answerCitations.enumerated() {
                lines.append("- Excerpt \(excerptNumber(for: citation, fallback: index + 1)): \(citationLabel(citation))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let noteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Conversation runner

    private func send() {
        // Hidden Test Mode: typing the exact trigger phrase opens the benchmarking
        // surface instead of asking a question.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == TestMode.triggerPhrase {
            query = ""
            onRequestTestMode()
            return
        }
        // Never run a question against half-built vectors: Ask waits until every
        // document in scope has finished embedding.
        guard !isAskBlocked else { return }
        let question = query
        query = ""
        askedQuestion = question
        response = ""
        answerCitations = []
        packedCitations = []
        candidateCount = 0
        errorMessage = nil
        activity = []
        isGenerating = true
        generationTask = Task {
            defer { isGenerating = false }
            do {
                for try await event in await assistant.answer(question, mode: .ask, scope: scopeIDs) {
                    try Task.checkCancellation()
                    switch event {
                    case .stage(let stage):
                        applyStage(stage)
                    case .citations(let citations):
                        // Packed evidence: counted in the status feed, listed only if used.
                        packedCitations = citations
                    case .usedCitations(let citations):
                        answerCitations = citations
                        if let i = activity.firstIndex(where: { $0.id == "generate" }) {
                            activity[i].detail = citations.isEmpty
                                ? nil
                                : "Cited \(citations.count) of \(packedCitations.count) source(s)"
                        }
                    case .token(let token):
                        modelWarmedUp = true
                        if let i = activity.firstIndex(where: { $0.id == "generate" }) { activity[i].label = "Generating answer…" }
                        response += token
                    }
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                finishAll()
                advance("stopped", "Stopped.")
                finishAll()
            } catch {
                activity = []
                errorMessage = error.localizedDescription
                askedQuestion = ""
                query = question
            }
        }
    }

    private func applyStage(_ stage: ToolStage) {
        switch stage {
        case .searching:
            advance("search", "Searching concepts…")
        case .ranking(let lexical, let semantic, let fused, let semanticAvailable):
            // Makes the hybrid pipeline visible: the semantic pass and RRF fusion
            // used to happen between two rows with nothing on screen.
            candidateCount = fused
            advance(
                "rank",
                semanticAvailable ? "Ranking matches…" : "Ranking matches (keyword only)",
                detail: semanticAvailable
                    ? "\(lexical) keyword · \(semantic) semantic → \(fused) candidates"
                    : "\(lexical) keyword matches"
            )
        case .readingSources(let count):
            advance("read", count == 1 ? "Reading 1 source" : "Reading \(count) sources")
        case .composingPrompt(let count):
            advance(
                "compose",
                "Composing prompt",
                detail: candidateCount > 0
                    ? "\(count) excerpt(s) from \(candidateCount) candidate(s)"
                    : "\(count) excerpt(s)"
            )
        case .generating:
            advance("generate", (modelWarm || modelWarmedUp) ? "Generating answer…" : "Starting on-device model…")
        case .finished:
            finishAll()
        }
    }

    private func advance(_ id: String, _ label: String, detail: String? = nil) {
        for i in activity.indices { activity[i].state = .done }
        activity.append(ActivityStep(id: id, label: label, state: .active, detail: detail))
    }

    private func finishAll() {
        for i in activity.indices { activity[i].state = .done }
    }
}

/// Greedy left-to-right flow layout: children that no longer fit on the current
/// row wrap to the next one, so chip rows never get clipped by a narrow container.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
