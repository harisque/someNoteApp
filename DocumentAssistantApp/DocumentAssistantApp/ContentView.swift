import SwiftUI
import DocumentAssistant

/// Adaptive root view.
/// - Regular width (iPad): `NavigationSplitView` with the categorized
///   `DocumentManagerView` as the sidebar, the reader in the detail column, and
///   the assistant (Ask only) in a trailing `.inspector`. Tapping a citation
///   focuses the reader in place (no navigation push).
/// - Compact width (iPhone): the Ask panel is front-and-center; a "Library"
///   toolbar button pushes `DocumentManagerView`, and selecting a document there
///   pushes the reader (or the note editor for AI Notes).

/// Compact-stack navigation item for a Data Link. A distinct type from `UUID` so it
/// can't collide with the document `navigationDestination(item:)` in the same stack.
private struct DataLinkRoute: Hashable { let id: UUID }

struct ContentView: View {
    let assistant: DocumentAssistant
    let coordinator: ModelCoordinator

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showTestMode = false
    @State private var documents: [Document] = []
    @State private var folders: [Folder] = []
    /// Most-recently-opened document ids (MRU) and favorited ids, loaded from the
    /// assistant's lightweight sidecar. Drive the per-category Recent/Favorites
    /// sections in DocumentManagerView; virtual only (never move a doc's folder).
    @State private var recents: [UUID] = []
    @State private var favorites: [UUID] = []
    @State private var selectedDocumentID: UUID?
    @State private var focusCitation: Citation?
    @State private var showAssistant = false
    @State private var showLibrary = false
    @State private var openedDocumentID: UUID?
    /// Deep-search sheet state lives at the root (not in the per-document reader)
    /// so results survive detail-pane swaps: opening a hit replaces the searched
    /// document, which used to destroy the reader-owned sheet and its results.
    @State private var deepSearchRequest: DeepSearchRequest?
    /// The most recent deep-search query, kept after the sheet closes so readers
    /// can offer a way back to the results: tapping a hit from another file swaps
    /// the detail pane, and the original entry point (that file's find-bar query
    /// or selection) goes with it.
    @State private var lastDeepSearchQuery: String?
    @State private var dataLinks: [DataLink] = []
    /// Regular (iPad): the data link shown in the detail pane, if any.
    @State private var selectedDataLinkID: UUID?
    /// Compact (iPhone): drives the pushed `DataLinkView`.
    @State private var openedDataLink: DataLinkRoute?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    /// Launch gate: holds the app behind a non-interactive cover until the whole
    /// library is embedded and the chat model is resident.
    @State private var gate = LaunchGate()
    /// Per-document embedding state, polled while any job is in flight. Drives the
    /// Library row indicators, the Ask gate, and the reader's "embedding" banner.
    @State private var embeddingStates: [UUID: DocumentEmbeddingState] = [:]
    /// Ids of documents still embedding; Ask and their Deep Search stay disabled.
    @State private var pendingEmbeddingIDs: Set<UUID> = []
    @State private var embeddingWatch: Task<Void, Never>?

    var body: some View {
        Group {
            if gate.isReady {
                if horizontalSizeClass == .regular { regularLayout } else { compactLayout }
            } else {
                LaunchGateView(
                    gate: gate,
                    onRetry: loadModelIntoGate,
                    onEnterAnyway: { gate.enteredManually = true }
                )
            }
        }
        .task { await bootstrap() }
        .fullScreenCover(isPresented: $showTestMode) {
            TestModeView(coordinator: coordinator)
        }
        .sheet(item: $deepSearchRequest) { request in
            DeepSearchSheet(query: request.text, assistant: assistant, onOpenCitation: focusInPlace)
        }
    }

    // MARK: - Launch gate + bootstrap

    /// Launch orchestration: seed and load the library, then hold the gate until
    /// the whole library has finished embedding and the chat model is resident.
    /// The Data Link refresh runs after entry so network latency never delays it.
    private func bootstrap() async {
        gate.isPreparing = true
        #if targetEnvironment(simulator)
        // MLX inference is unavailable in the Simulator, so don't require the model.
        gate.modelRequired = false
        #endif

        // Seed Confidential from the app bundle (idempotent), then load state.
        try? await assistant.syncBundledConfidential(
            bundleFolderURL: Bundle.main.url(forResource: "Confidential", withExtension: nil)
        )
        // Configure the live Data Link source and seed bundled descriptors
        // (idempotent by symbol) so Ask has structured data to cite.
        // TEMPORARY: DemoBackfillSource wraps the real source to fill STAN.L's
        // 2026-09-14 session, which Yahoo has not republished yet. Remove after the
        // demo by reverting this line to `RemoteDataLinkSource()`.
        await assistant.configureDataLinkSource(DemoBackfillSource(wrapped: RemoteDataLinkSource()))
        if let descriptors = bundledDataLinkDescriptors() {
            try? await assistant.seedDataLinks(descriptors)
        }
        documents = await assistant.documents
        folders = await assistant.folders
        dataLinks = await assistant.listDataLinks()
        recents = await assistant.recents
        favorites = await assistant.favorites
        if selectedDocumentID == nil { selectedDocumentID = documents.first?.id }

        // Start the chat-model load (device only). It reports into the gate
        // reactively, so it needs no polling.
        if gate.modelRequired {
            loadModelIntoGate()
        } else {
            gate.modelState = .ready
        }

        // Warm the semantic index: rebuilds the index if needed, preloads the
        // embedder model, and starts the per-document background embedding jobs.
        await assistant.warmEmbeddingCache()

        // Poll embedding progress into the gate until every job settles.
        gate.isPreparing = false
        while true {
            let progress = await assistant.libraryEmbeddingProgress()
            gate.totalChunks = progress.totalChunks
            gate.embeddedChunks = progress.embeddedChunks
            gate.embeddingSettled = progress.isSettled
            if progress.isSettled { break }
            try? await Task.sleep(for: .milliseconds(400))
        }

        // Post-entry: watch per-document embedding (for import gating) and refresh
        // Data Links without blocking the gate.
        startEmbeddingWatch()
        Task {
            await assistant.refreshAllDataLinks()
            dataLinks = await assistant.listDataLinks()
        }
    }

    /// Kicks off the chat-model load and mirrors its outcome into the gate. Called
    /// once at launch and again by the gate's Retry button.
    private func loadModelIntoGate() {
        gate.modelState = .loading
        Task { @MainActor in
            await coordinator.normalModel.loadNow()
            gate.modelState = coordinator.normalModel.loadState
        }
    }

    /// Polls per-document embedding state while any job is in flight, feeding the
    /// Library row indicators, the Ask gate, and the reader banner. Re-armed by
    /// `refreshDocuments()` after an import; stops once nothing is pending.
    private func startEmbeddingWatch() {
        embeddingWatch?.cancel()
        embeddingWatch = Task { @MainActor in
            while !Task.isCancelled {
                let states = await assistant.embeddingStates()
                embeddingStates = states
                pendingEmbeddingIDs = Set(states.filter { $0.value.isInFlight }.keys)
                if pendingEmbeddingIDs.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Regular (iPad)

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DocumentManagerView(
                assistant: assistant,
                documents: documents,
                folders: folders,
                recents: recents,
                favorites: favorites,
                embeddingStates: embeddingStates,
                selection: $selectedDocumentID,
                onOpenDocument: { selectedDocumentID = $0; selectedDataLinkID = nil },
                onChanged: refreshDocuments,
                dataLinks: dataLinks,
                selectedDataLinkID: selectedDataLinkID,
                onOpenDataLink: { selectedDataLinkID = $0; selectedDocumentID = nil }
            )
            .navigationTitle("Documents")
        } detail: {
            readerPane
                .inspector(isPresented: $showAssistant) {
                    AssistantPanel(
                        assistant: assistant,
                        documents: documents,
                        folders: folders,
                        dataLinks: dataLinks,
                        pendingEmbeddingIDs: pendingEmbeddingIDs,
                        modelWarm: gate.modelState == .ready,
                        onOpenCitation: focusInPlace,
                        onOpenDocument: { selectedDocumentID = $0 },
                        onDocumentsChanged: refreshDocuments,
                        onRequestTestMode: { showTestMode = true }
                    )
                    // The inspector column opens at a system-default width that ignores
                    // minWidth/idealWidth on first presentation, and is narrower in
                    // portrait. A minWidth above that default makes the frame overflow
                    // the column and clip both edges, so keep the floor at zero and let
                    // the (wrapping, flexible) panel fill exactly the column it is given;
                    // maxWidth .infinity still lets the user drag it wider in landscape.
                    .frame(minWidth: 0, idealWidth: 400, maxWidth: .infinity, alignment: .topLeading)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
                        } label: {
                            Label("Documents", systemImage: "sidebar.leading")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAssistant.toggle() } label: { Label("Assistant", systemImage: "sparkles") }
                    }
                }
        }
    }

    @ViewBuilder private var readerPane: some View {
        if let id = selectedDataLinkID, let link = dataLinks.first(where: { $0.id == id }) {
            DataLinkView(assistant: assistant, link: link, onChanged: refreshDocuments)
                .id(link.id)
        } else if let id = selectedDocumentID, let document = documents.first(where: { $0.id == id }) {
            readerOrEditor(for: document)
        } else {
            ContentUnavailableView(
                "Select a document", systemImage: "doc.text",
                description: Text("Import a PDF, TXT, or Markdown file, then choose it here.")
            )
        }
    }

    /// Routes a document to the note editor (AI Notes) or the reader. Deep-search
    /// results navigate through `focusInPlace`, which works in both layouts:
    /// regular swaps the detail pane; compact pushes via `focusCitation`.
    @ViewBuilder private func readerOrEditor(for document: Document) -> some View {
        Group {
            if document.isNote {
                NoteEditorView(
                    document: document,
                    assistant: assistant,
                    onChanged: refreshDocuments,
                    onDelete: { openedDocumentID = nil; refreshDocuments() },
                    onRequestDeepSearch: requestDeepSearch
                )
                .id(document.id)
            } else {
                DocumentReaderView(document: document, assistant: assistant, isEmbedding: embeddingStates[document.id]?.isInFlight == true, focusCitation: focusCitation, onRequestDeepSearch: requestDeepSearch)
                    .id(document.id)
            }
        }
        .toolbar { reopenDeepSearchToolbar }
        // Single choke point for "a document is on screen": records the open so the
        // per-category Recent lists stay live. Keyed on id, so re-renders of the
        // same document don't re-record or loop.
        .task(id: document.id) {
            await assistant.markDocumentOpened(document.id)
            recents = await assistant.recents
        }
    }

    /// Presents the root-owned deep-search sheet for a query coming from any
    /// reader/editor (selection pill or find-bar button).
    private func requestDeepSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastDeepSearchQuery = trimmed
        deepSearchRequest = DeepSearchRequest(text: trimmed)
    }

    /// Toolbar re-entry to the last deep-search results, shown on any document
    /// once a search has run. Reopening re-runs the query (fast: exact scan plus
    /// cached vectors) in the root-owned sheet.
    @ToolbarContentBuilder private var reopenDeepSearchToolbar: some ToolbarContent {
        if let query = lastDeepSearchQuery {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    deepSearchRequest = DeepSearchRequest(text: query)
                } label: {
                    Label("Deep Search Results", systemImage: "text.magnifyingglass")
                }
                .tint(Color("SCBlue"))
            }
        }
    }

    private func focusInPlace(_ citation: Citation) {
        if let linkID = dataLinkID(from: citation) {
            selectedDataLinkID = linkID
            selectedDocumentID = nil
            return
        }
        if let id = citation.documentID { selectedDocumentID = id; selectedDataLinkID = nil }
        focusCitation = citation
    }

    /// Maps a tapped Data Link citation (OKF conceptID prefix `datalinks/`) back to its
    /// link id so the host opens `DataLinkView` instead of the document reader.
    private func dataLinkID(from citation: Citation) -> UUID? {
        guard let conceptID = citation.conceptID,
              conceptID.hasPrefix("datalinks/") else { return nil }
        return UUID(uuidString: String(conceptID.dropFirst("datalinks/".count)))
    }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
        NavigationStack {
            AssistantPanel(
                assistant: assistant,
                documents: documents,
                folders: folders,
                dataLinks: dataLinks,
                pendingEmbeddingIDs: pendingEmbeddingIDs,
                modelWarm: gate.modelState == .ready,
                onOpenCitation: { citation in
                    if let linkID = dataLinkID(from: citation) {
                        openedDataLink = DataLinkRoute(id: linkID)
                    } else {
                        focusCitation = citation
                    }
                },
                onOpenDocument: { openedDocumentID = $0 },
                onDocumentsChanged: refreshDocuments,
                onRequestTestMode: { showTestMode = true }
            )
            .navigationTitle("Ask")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLibrary = true } label: { Label("Library", systemImage: "folder") }
                }
            }
            .navigationDestination(isPresented: $showLibrary) {
                DocumentManagerView(
                    assistant: assistant,
                    documents: documents,
                    folders: folders,
                    recents: recents,
                    favorites: favorites,
                    embeddingStates: embeddingStates,
                    selection: nil,
                    onOpenDocument: { openedDocumentID = $0 },
                    onChanged: refreshDocuments,
                    dataLinks: dataLinks,
                    onOpenDataLink: { openedDataLink = DataLinkRoute(id: $0) }
                )
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(item: $openedDocumentID) { id in
                if let document = documents.first(where: { $0.id == id }) {
                    readerOrEditor(for: document)
                } else {
                    Text("This document is no longer available.")
                        .padding().navigationTitle("Document")
                }
            }
            .navigationDestination(item: $focusCitation) { citation in
                if let document = documents.first(where: { $0.id == citation.documentID }) {
                    // Route through the shared builder so citation/deep-search opens
                    // also record as "recent" and reuse its toolbar/task.
                    readerOrEditor(for: document)
                } else {
                    Text("The source document for this citation is no longer available.")
                        .padding().navigationTitle("Source")
                }
            }
            .navigationDestination(item: $openedDataLink) { route in
                if let link = dataLinks.first(where: { $0.id == route.id }) {
                    DataLinkView(assistant: assistant, link: link, onChanged: refreshDocuments)
                        .id(link.id)
                } else {
                    Text("This data link is no longer available.")
                        .padding().navigationTitle("Data Link")
                }
            }
        }
    }

    // MARK: - Shared

    /// Reloads the shared document + folder lists and, if the current selection
    /// vanished (e.g. a document was deleted), reselects the first document.
    private func refreshDocuments() {
        Task {
            documents = await assistant.documents
            folders = await assistant.folders
            dataLinks = await assistant.listDataLinks()
            recents = await assistant.recents
            favorites = await assistant.favorites
            if let selected = selectedDocumentID, !documents.contains(where: { $0.id == selected }) {
                selectedDocumentID = documents.first?.id
            }
            if let selected = selectedDataLinkID, !dataLinks.contains(where: { $0.id == selected }) {
                selectedDataLinkID = nil
            }
            // Re-arm the embedding watch so a fresh import shows progress and gates
            // Ask for that document until its vectors are ready.
            startEmbeddingWatch()
        }
    }

    /// Loads the bundled `dataLinks.json` seed descriptors, if present. Placed flat in
    /// the bundle (like `ModelConfig.json`); the `DataLinks/` subdirectory is checked
    /// first as a fallback so either layout works.
    private func bundledDataLinkDescriptors() -> [DataLinkDescriptor]? {
        let url = Bundle.main.url(forResource: "dataLinks", withExtension: "json", subdirectory: "DataLinks")
            ?? Bundle.main.url(forResource: "dataLinks", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([DataLinkDescriptor].self, from: data)
    }
}
