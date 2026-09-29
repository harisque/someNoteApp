import SwiftUI
import UniformTypeIdentifiers
import DocumentAssistant

/// A reusable, categorized document browser/manager. It renders two rounded,
/// SCBlue-tinted "category cards" — Confidential and Personal — separated by extra
/// spacing so the categories read as distinct boxes. It is the single place to
/// create, rename, and delete folders, move documents between folders, import files,
/// and open documents.
///
/// Each category contains a permanent "AI Notes" system folder holding its notes
/// (editable/deletable in both categories). Confidential is otherwise read-only:
/// its non-note rows have no move/delete/import affordances and show a lock.
/// Personal also lists user folders (one level). Rows are plain views grouped in a
/// card (never `DisclosureGroup`, whose nested context menus were unreliable); each
/// folder has a tappable chevron header that folds its contents, and nested rows are
/// indented so the hierarchy stays obvious.
///
/// Layout differences stay in the host via callbacks:
/// - `selection`: pass a binding on iPad so the split-view detail pane tracks the
///   highlighted row; pass `nil` on iPhone so rows become buttons that open directly.
/// - `onOpenDocument(id)`: the host routes to the reader or the note editor.
/// - `onChanged()`: the host reloads its `documents`/`folders` after any mutation.
struct DocumentManagerView: View {
    let assistant: DocumentAssistant
    let documents: [Document]
    let folders: [Folder]
    /// Most-recently-opened document ids (MRU) and favorited ids, supplied by the
    /// host from the assistant's sidecar. Drive the per-category Recent/Favorites
    /// sections. Virtual groupings: a doc still renders in its real folder below and
    /// its `folderID`/`category` never change.
    var recents: [UUID] = []
    var favorites: [UUID] = []
    /// Per-document embedding state. A doc that is still embedding shows a spinner
    /// and percentage in its row; viewing stays allowed, so the row remains tappable.
    var embeddingStates: [UUID: DocumentEmbeddingState] = [:]
    /// Non-nil on iPad (drives the detail pane); nil on iPhone (rows open directly).
    var selection: Binding<UUID?>?
    var onOpenDocument: (UUID) -> Void
    var onChanged: () -> Void
    /// Read-only Data Links (Confidential). Seeded from the app bundle; opened via
    /// `onOpenDataLink`. Empty on hosts that don't surface them.
    var dataLinks: [DataLink] = []
    /// Highlights the selected data-link row on iPad; nil on iPhone.
    var selectedDataLinkID: UUID? = nil
    /// Host routes to `DataLinkView`.
    var onOpenDataLink: (UUID) -> Void = { _ in }

    @State private var importing = false
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var folderPrompt: FolderPrompt?
    @State private var folderNameInput = ""
    /// Folder header keys the user has folded (empty = all expanded). String keys so
    /// both user folders (uuid) and the system AI Notes folders (per category) work
    /// without needing the actor-internal deterministic folder ids.
    @State private var collapsed: Set<String> = []

    /// Shared light SCBlue tint for both category boxes (dark-mode adaptive).
    private static let cardTint = Color("SCBlue").opacity(0.12)
    /// Stronger SCBlue used to highlight the selected row on iPad.
    private static let selectionTint = Color("SCBlue").opacity(0.30)

    private static let allowedTypes: [UTType] = [
        .plainText, .pdf,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText
    ]

    /// Drives the create/rename folder alert.
    private enum FolderPrompt: Identifiable {
        case create(DocumentCategory)
        case rename(Folder)
        var id: String {
            switch self {
            case .create(let category): return "create-\(category.rawValue)"
            case .rename(let folder): return "rename-\(folder.id.uuidString)"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                categoryCard(.confidential)
                categoryCard(.personal)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .overlay { if isImporting { ProgressView("Reading and indexing document…") } }
        .safeAreaInset(edge: .bottom) { statusFooter }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .disabled(isImporting)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.allowedTypes) { result in
            switch result {
            case .success(let url): importDocument(url)
            case .failure(let error): statusMessage = "File selection failed: \(error.localizedDescription)"
            }
        }
        .alert(folderAlertTitle, isPresented: folderPromptBinding) {
            TextField("Folder name", text: $folderNameInput)
            Button("Cancel", role: .cancel) { folderPrompt = nil }
            Button(folderAlertActionTitle) { commitFolderPrompt() }
        } message: {
            Text(folderAlertMessage)
        }
    }

    // MARK: - Category cards

    /// One rounded, SCBlue-tinted box per category: a header, its top-level docs,
    /// the permanent AI Notes folder, and (Personal only) the user folders. The outer
    /// stack's spacing separates the two cards so the categories read distinctly.
    @ViewBuilder private func categoryCard(_ category: DocumentCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: category == .confidential ? "lock.fill" : "folder.fill")
                Text(categoryName(category)).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            recentRows(category)
            favoritesRows(category)

            ForEach(documents(in: category, folderID: nil)) { doc in docRow(doc, nested: false) }

            aiNotesRows(category)

            if category == .personal {
                userFolderRows(category)
            } else {
                dataLinksRows
                Text(documents(in: category, folderID: nil).isEmpty
                     ? "Bundled confidential files appear here automatically and are read-only."
                     : "Read-only. Seeded from the app bundle. AI Notes here stay editable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
        .background(Self.cardTint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The per-category "Recent" section: a foldable chevron header and up to
    /// `DocumentAssistant.recentDisplayCount` most-recently-opened docs of this
    /// category. Virtual — the same docs still appear in their real folder below.
    @ViewBuilder private func recentRows(_ category: DocumentCategory) -> some View {
        let key = "recent-\(category.rawValue)"
        let items = recentDocuments(in: category)
        folderHeaderRow("Recent", icon: "clock.arrow.circlepath", key: key, folder: nil)
        if !collapsed.contains(key) {
            if items.isEmpty {
                Text("Documents you open appear here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.vertical, 6)
            } else {
                ForEach(items) { doc in docRow(doc, nested: true) }
            }
        }
    }

    /// The per-category "Favorites" section: a foldable chevron header and every
    /// favorited doc of this category, in the order pinned. Virtual — pinning never
    /// moves the file out of its real folder.
    @ViewBuilder private func favoritesRows(_ category: DocumentCategory) -> some View {
        let key = "favorites-\(category.rawValue)"
        let items = favoriteDocuments(in: category)
        folderHeaderRow("Favorites", icon: "star.fill", key: key, folder: nil)
        if !collapsed.contains(key) {
            if items.isEmpty {
                Text("Tap the star on a document to pin it here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.vertical, 6)
            } else {
                ForEach(items) { doc in docRow(doc, nested: true) }
            }
        }
    }

    /// The permanent AI Notes system folder for a category: a foldable chevron
    /// header, its notes indented one level, and (Personal only) a "New note" button.
    @ViewBuilder private func aiNotesRows(_ category: DocumentCategory) -> some View {
        let key = "ainotes-\(category.rawValue)"
        folderHeaderRow("AI Notes", icon: "note.text", key: key, folder: nil)
        if !collapsed.contains(key) {
            ForEach(notes(in: category)) { doc in docRow(doc, nested: true) }
            if category == .personal {
                actionRow("New note", icon: "square.and.pencil", nested: true) { newNote() }
            }
        }
    }

    /// Personal user folders (never the system AI Notes folder): each a foldable
    /// chevron header with a rename/delete context menu, its documents indented one
    /// level, then a "New folder" button.
    @ViewBuilder private func userFolderRows(_ category: DocumentCategory) -> some View {
        ForEach(folders(in: category).filter { !$0.isSystem }) { folder in
            let key = folder.id.uuidString
            folderHeaderRow(folder.name, icon: "folder.fill", key: key, folder: folder)
            if !collapsed.contains(key) {
                let docs = documents.filter { $0.folderID == folder.id }
                if docs.isEmpty {
                    Text("No documents")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 28).padding(.vertical, 6)
                } else {
                    ForEach(docs) { doc in docRow(doc, nested: true) }
                }
            }
        }
        actionRow("New folder", icon: "folder.badge.plus", nested: false) { beginCreate(category) }
    }

    /// The Confidential "Data Links" section: a foldable chevron header and read-only
    /// rows (one per seeded link). Reuses the folder-header/row styling so it reads as
    /// part of the same hierarchy; there are no move/delete/import affordances.
    @ViewBuilder private var dataLinksRows: some View {
        if !dataLinks.isEmpty {
            let key = "datalinks"
            folderHeaderRow("Data Links", icon: "chart.xyaxis.line", key: key, folder: nil)
            if !collapsed.contains(key) {
                ForEach(dataLinks) { link in dataLinkRow(link) }
            }
        }
    }

    /// A read-only data-link row: an up-trend chart icon, the name, and a lock. Tapping
    /// opens `DataLinkView` via the host's `onOpenDataLink`; iPad highlights selection.
    @ViewBuilder private func dataLinkRow(_ link: DataLink) -> some View {
        let isSelected = selectedDataLinkID == link.id
        Button { onOpenDataLink(link.id) } label: {
            HStack(spacing: 6) {
                Label(link.name, systemImage: "chart.line.uptrend.xyaxis")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Self.selectionTint : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A tappable folder header row: a chevron reflecting fold state and a semibold
    /// label; user folders also get a rename/delete context menu. Tapping anywhere
    /// toggles the fold. Child rows stay plain views so their context menus remain
    /// reliable — the reason we avoid `DisclosureGroup`.
    @ViewBuilder
    private func folderHeaderRow(_ title: String, icon: String, key: String, folder: Folder?) -> some View {
        let header = HStack(spacing: 6) {
            Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                .font(.caption2).foregroundStyle(.secondary)
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggleFold(key) }
        if let folder {
            header.contextMenu {
                Button { beginRename(folder) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { deleteFolder(folder) } label: { Label("Delete", systemImage: "trash") }
            }
        } else {
            header
        }
    }

    /// A full-width borderless action row ("New note" / "New folder").
    @ViewBuilder
    private func actionRow(_ title: String, icon: String, nested: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.leading, nested ? 28 : 12)
        .padding(.trailing, 12)
    }

    @ViewBuilder private func docRow(_ doc: Document, nested: Bool) -> some View {
        let isSelected = selection?.wrappedValue == doc.id
        let isFavorite = favorites.contains(doc.id)
        HStack(spacing: 6) {
            Button { onOpenDocument(doc.id) } label: {
                HStack(spacing: 6) {
                    Label(doc.name, systemImage: icon(for: doc))
                        .lineLimit(1)
                    if doc.category == .confidential && !doc.isNote {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    if let state = embeddingStates[doc.id], state.isInFlight {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Embedding… \(Int(state.fraction * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Inline favorite toggle. A sibling button (not nested inside the open
            // button) so both hit areas stay reliable; offered for every category,
            // Confidential included, because pinning is metadata, not an edit.
            Button { toggleFavorite(doc) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color("SCBlue") : Color.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, nested ? 28 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Self.selectionTint : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contextMenu { docMenu(doc) }
    }

    private func toggleFold(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    @ViewBuilder private func docMenu(_ doc: Document) -> some View {
        Button { onOpenDocument(doc.id) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
        // Favorite applies to every doc in both categories (metadata, not a move),
        // so it precedes the note/personal branching that gates edit/delete/move.
        Button { toggleFavorite(doc) } label: {
            Label(favorites.contains(doc.id) ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: favorites.contains(doc.id) ? "star.slash" : "star")
        }
        if doc.isNote {
            // Notes are editable/deletable in both categories but never movable.
            Button(role: .destructive) { delete(doc) } label: { Label("Delete", systemImage: "trash") }
        } else if doc.category == .personal {
            Menu {
                Button { move(doc, to: nil) } label: {
                    if doc.folderID == nil {
                        Label("Personal top level", systemImage: "checkmark")
                    } else {
                        Text("Personal top level")
                    }
                }
                ForEach(folders(in: .personal).filter { !$0.isSystem }) { folder in
                    Button { move(doc, to: folder.id) } label: {
                        if doc.folderID == folder.id { Label(folder.name, systemImage: "checkmark") }
                        else { Text(folder.name) }
                    }
                }
            } label: {
                Label("Move to", systemImage: "folder.badge.arrow")
            }
            Button(role: .destructive) { delete(doc) } label: { Label("Delete", systemImage: "trash") }
        }
        // Confidential non-note: read-only, only Open.
    }

    @ViewBuilder private var statusFooter: some View {
        if let statusMessage {
            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    // MARK: - Data helpers

    private func documents(in category: DocumentCategory, folderID: UUID?) -> [Document] {
        documents.filter { $0.category == category && $0.folderID == folderID && !$0.isNote }
    }

    private func notes(in category: DocumentCategory) -> [Document] {
        documents.filter { $0.category == category && $0.isNote }
    }

    /// This category's most-recently-opened docs (MRU order, capped at the display
    /// count). Ids that no longer resolve to a live doc are dropped by the join.
    private func recentDocuments(in category: DocumentCategory) -> [Document] {
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return Array(recents.compactMap { byID[$0] }
            .filter { $0.category == category }
            .prefix(DocumentAssistant.recentDisplayCount))
    }

    /// This category's favorited docs, in the order they were pinned.
    private func favoriteDocuments(in category: DocumentCategory) -> [Document] {
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return favorites.compactMap { byID[$0] }.filter { $0.category == category }
    }

    private func folders(in category: DocumentCategory) -> [Folder] {
        folders.filter { $0.category == category }.sorted { $0.createdAt < $1.createdAt }
    }

    private func categoryName(_ category: DocumentCategory) -> String {
        switch category {
        case .confidential: return "Confidential"
        case .personal: return "Personal"
        }
    }

    private func icon(for document: Document) -> String {
        switch document.kind {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.plaintext"
        case .text: return "doc.plaintext"
        case .unknown: return "doc.text"
        }
    }

    /// Import always targets Personal; it lands in the selected Personal folder
    /// when the current selection is inside Personal, otherwise the Personal root.
    private var importFolderID: UUID? {
        guard let selected = selection?.wrappedValue,
              let doc = documents.first(where: { $0.id == selected }),
              doc.category == .personal else { return nil }
        return doc.folderID
    }

    // MARK: - Actions

    private func importDocument(_ url: URL) {
        isImporting = true
        statusMessage = nil
        let folderID = importFolderID
        Task {
            defer { isImporting = false }
            do {
                try await assistant.importDocument(url: url, category: .personal, folderID: folderID)
                statusMessage = "Imported \(url.lastPathComponent)."
                onChanged()
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func newNote() {
        Task {
            do {
                let id = try await assistant.createNote(title: "Untitled note", text: "", category: .personal)
                onChanged()
                onOpenDocument(id)
            } catch {
                statusMessage = "Couldn't create note: \(error.localizedDescription)"
            }
        }
    }

    /// Pins/unpins a doc as a favorite. Virtual: never changes its folder/category.
    /// `onChanged()` reloads the host's favorites so the star and section update.
    private func toggleFavorite(_ doc: Document) {
        Task {
            await assistant.setFavorite(doc.id, favorite: !favorites.contains(doc.id))
            onChanged()
        }
    }

    private func move(_ doc: Document, to folderID: UUID?) {
        Task {
            do {
                try await assistant.moveDocument(id: doc.id, toFolder: folderID)
                onChanged()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ doc: Document) {
        Task {
            do {
                try await assistant.deleteDocument(id: doc.id)
                statusMessage = "Document removed."
                onChanged()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func deleteFolder(_ folder: Folder) {
        Task {
            do {
                try await assistant.deleteFolder(id: folder.id)
                statusMessage = "Folder removed; its documents moved to the top level."
                onChanged()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func beginCreate(_ category: DocumentCategory) {
        folderNameInput = ""
        folderPrompt = .create(category)
    }

    private func beginRename(_ folder: Folder) {
        folderNameInput = folder.name
        folderPrompt = .rename(folder)
    }

    private func commitFolderPrompt() {
        guard let prompt = folderPrompt else { return }
        let name = folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        folderPrompt = nil
        switch prompt {
        case .create(let category):
            guard !name.isEmpty else { return }
            Task {
                do {
                    try await assistant.createFolder(name: name, category: category)
                    onChanged()
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
        case .rename(let folder):
            guard !name.isEmpty, name != folder.name else { return }
            Task {
                do {
                    try await assistant.renameFolder(id: folder.id, to: name)
                    onChanged()
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Alert plumbing

    private var folderPromptBinding: Binding<Bool> {
        Binding(get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } })
    }

    private var folderAlertTitle: String {
        switch folderPrompt {
        case .create(let category): return "New \(categoryName(category)) folder"
        case .rename: return "Rename folder"
        case .none: return ""
        }
    }

    private var folderAlertActionTitle: String {
        switch folderPrompt {
        case .create: return "Create"
        case .rename: return "Save"
        case .none: return "OK"
        }
    }

    private var folderAlertMessage: String {
        switch folderPrompt {
        case .rename(let folder):
            return "Documents in “\(folder.name)” stay put; only the name changes."
        default:
            return "Folders live one level under a category."
        }
    }
}
