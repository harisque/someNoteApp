import Foundation

/// Errors raised by category/folder management. Kept separate from the model so
/// the actor and its extensions share one vocabulary.
public enum DocumentError: LocalizedError {
    case confidentialReadOnly
    case confidentialFolderNotAllowed
    case folderNotFound
    case crossCategoryMove
    case systemFolderProtected
    case notesNotMovable
    case cannotMoveIntoAINotes

    public var errorDescription: String? {
        switch self {
        case .confidentialReadOnly: return "Confidential documents are read-only."
        case .confidentialFolderNotAllowed: return "Folders can't be created in Confidential."
        case .folderNotFound: return "That folder no longer exists."
        case .crossCategoryMove: return "Documents can only move within their own category."
        case .systemFolderProtected: return "The AI Notes folder can't be renamed or deleted."
        case .notesNotMovable: return "Notes stay in their AI Notes folder."
        case .cannotMoveIntoAINotes: return "Only notes live in the AI Notes folder."
        }
    }
}

/// Folder management: one level of user-created subfolders within Personal only.
/// Each category also has a permanent system "AI Notes" folder (`isSystem == true`)
/// that cannot be renamed or deleted. Confidential is read-only: its non-note docs
/// cannot be moved or deleted (its AI Notes are still editable/deletable). Every
/// mutation re-indexes/persists through `persist()`.
@available(macOS 10.15, iOS 13.0, *)
extension DocumentAssistant {
    /// Creates a user subfolder in Personal and returns its id. Confidential holds
    /// only its read-only seeds and the permanent AI Notes folder.
    @discardableResult
    public func createFolder(name: String, category: DocumentCategory) async throws -> UUID {
        guard category == .personal else { throw DocumentError.confidentialFolderNotAllowed }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: trimmed.isEmpty ? "New folder" : trimmed, category: category)
        folders.append(folder)
        try persist()
        return folder.id
    }

    /// Renames a folder; ignores an empty/whitespace name. System (AI Notes) folders
    /// are permanent and cannot be renamed.
    public func renameFolder(id: UUID, to name: String) async throws {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { throw DocumentError.folderNotFound }
        guard !folders[idx].isSystem else { throw DocumentError.systemFolderProtected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[idx].name = trimmed
        try persist()
    }

    /// Deletes a folder non-destructively: its documents are reassigned to the
    /// category root (`folderID = nil`) rather than removed. System (AI Notes)
    /// folders are permanent and cannot be deleted.
    public func deleteFolder(id: UUID) async throws {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { throw DocumentError.folderNotFound }
        guard !folders[idx].isSystem else { throw DocumentError.systemFolderProtected }
        folders.remove(at: idx)
        for i in documents.indices where documents[i].folderID == id { documents[i].folderID = nil }
        try persist()
    }

    /// Moves a non-note document to `folderID` (or `nil` for its category root).
    /// Rules: Confidential non-note docs are read-only; notes are never movable
    /// (they stay in their AI Notes folder); the target folder must exist, belong to
    /// the same category, and not be a system AI Notes folder.
    public func moveDocument(id: UUID, toFolder folderID: UUID?) async throws {
        guard let docIdx = documents.firstIndex(where: { $0.id == id }) else { return }
        let doc = documents[docIdx]
        guard !(doc.category == .confidential && !doc.isNote) else { throw DocumentError.confidentialReadOnly }
        guard !doc.isNote else { throw DocumentError.notesNotMovable }
        if let folderID {
            guard let folder = folders.first(where: { $0.id == folderID }) else { throw DocumentError.folderNotFound }
            guard folder.category == doc.category else { throw DocumentError.crossCategoryMove }
            guard !folder.isSystem else { throw DocumentError.cannotMoveIntoAINotes }
        }
        documents[docIdx].folderID = folderID
        try persist()
    }
}
