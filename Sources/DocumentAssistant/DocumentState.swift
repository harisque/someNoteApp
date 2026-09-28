import Foundation

/// Persisted shape of the lightweight UI navigation sidecar (`documentState.json`).
/// Kept separate from the full-text catalog so recording an open or a favorite is a
/// tiny write. `recent` is most-recent-first; `favorites` is in the order added.
struct DocumentUIState: Codable, Sendable {
    var recent: [UUID] = []
    var favorites: [UUID] = []
}

/// "Recent" and "Favorites" navigation state.
///
/// Both are virtual groupings layered over the catalog: they store only document
/// ids and never touch a document's `folderID` or `category`, so pinning or
/// recording an open leaves the file exactly where it lives. They apply to every
/// category (Confidential included) because favoriting/opening is metadata, not a
/// content mutation, so it does not breach Confidential's read-only rule.
///
/// The ids are persisted in `documentState.json` (see ``DocumentUIState``) rather
/// than on `Document`: the catalog embeds every document's full text, so rewriting
/// it on each open would be disproportionate. `saveUIState()` prunes ids that no
/// longer resolve to a live document, and `persist()` calls it too so deletes stay
/// clean without editing the delete paths.
@available(macOS 10.15, iOS 13.0, *)
extension DocumentAssistant {
    /// Stored depth of the most-recently-used list. Larger than the per-category
    /// display count so each category can still surface its own top few even when
    /// the other category dominates recent opens.
    static let recentLimit = 20
    /// How many recent documents each category card shows.
    public static let recentDisplayCount = 3

    /// Records that `id` was opened: moves it to the front of the MRU list,
    /// de-duplicates, caps the list, and persists the sidecar.
    public func markDocumentOpened(_ id: UUID) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        saveUIState()
    }

    /// Pins (`favorite: true`) or unpins (`favorite: false`) `id`. Idempotent and
    /// order-preserving for existing entries; persists the sidecar.
    public func setFavorite(_ id: UUID, favorite: Bool) {
        if favorite {
            if !favorites.contains(id) { favorites.append(id) }
        } else {
            favorites.removeAll { $0 == id }
        }
        saveUIState()
    }

    /// Flips `id`'s favorite state and returns the new value.
    @discardableResult
    public func toggleFavorite(_ id: UUID) -> Bool {
        let now = !favorites.contains(id)
        setFavorite(id, favorite: now)
        return now
    }

    /// Prunes ids that no longer resolve to a live document, then writes the
    /// sidecar. Best-effort and non-throwing: this is non-critical UI state, so a
    /// failed write must never fail the mutation that triggered it.
    func saveUIState() {
        let live = Set(documents.map { $0.id })
        recents = recents.filter { live.contains($0) }
        favorites = favorites.filter { live.contains($0) }
        let state = DocumentUIState(recent: recents, favorites: favorites)
        try? FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: documentStateURL, options: .atomic)
    }
}
