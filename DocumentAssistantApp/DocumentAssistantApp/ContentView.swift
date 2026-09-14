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
    @State private var selectedDocumentID: UUID?
    @State private var focusCitation: Citation?
    @State private var showAssistant = false
    @State private var showLibrary = false
    @State private var openedDocumentID: UUID?
    @State private var dataLinks: [DataLink] = []
    /// Regular (iPad): the data link shown in the detail pane, if any.
    @State private var selectedDataLinkID: UUID?
    /// Compact (iPhone): drives the pushed `DataLinkView`.
    @State private var openedDataLink: DataLinkRoute?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        Group {
            if horizontalSizeClass == .regular { regularLayout } else { compactLayout }
        }
        .task {
            // Seed Confidential from the app bundle (idempotent), then load state.
            try? await assistant.syncBundledConfidential(
                bundleFolderURL: Bundle.main.url(forResource: "Confidential", withExtension: nil)
            )
            // Configure the live Data Link source and seed bundled descriptors
            // (idempotent by symbol) so Ask has structured data to cite.
            await assistant.configureDataLinkSource(RemoteDataLinkSource())
            if let descriptors = bundledDataLinkDescriptors() {
                try? await assistant.seedDataLinks(descriptors)
            }
            documents = await assistant.documents
            folders = await assistant.folders
            dataLinks = await assistant.listDataLinks()
            if selectedDocumentID == nil { selectedDocumentID = documents.first?.id }
            // Best-effort refresh after the UI is populated; reload to pick up the new
            // last-refresh stamps. A failure simply keeps the seeded state.
            await assistant.refreshAllDataLinks()
            dataLinks = await assistant.listDataLinks()
        }
        .fullScreenCover(isPresented: $showTestMode) {
            TestModeView(coordinator: coordinator)
        }
    }

    // MARK: - Regular (iPad)

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DocumentManagerView(
                assistant: assistant,
                documents: documents,
                folders: folders,
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
                        onOpenCitation: focusInPlace,
                        onOpenDocument: { selectedDocumentID = $0 },
                        onDocumentsChanged: refreshDocuments,
                        onRequestTestMode: { showTestMode = true }
                    )
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: .infinity, alignment: .topLeading)
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

    /// Routes a document to the note editor (AI Notes) or the reader.
    @ViewBuilder private func readerOrEditor(for document: Document) -> some View {
        if document.isNote {
            NoteEditorView(
                document: document,
                assistant: assistant,
                onChanged: refreshDocuments,
                onDelete: { openedDocumentID = nil; refreshDocuments() }
            )
            .id(document.id)
        } else {
            DocumentReaderView(document: document, assistant: assistant, focusCitation: focusCitation)
                .id(document.id)
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
                    DocumentReaderView(document: document, assistant: assistant, focusCitation: citation)
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
            if let selected = selectedDocumentID, !documents.contains(where: { $0.id == selected }) {
                selectedDocumentID = documents.first?.id
            }
            if let selected = selectedDataLinkID, !dataLinks.contains(where: { $0.id == selected }) {
                selectedDataLinkID = nil
            }
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
