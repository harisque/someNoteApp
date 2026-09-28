import Foundation
import Testing
@testable import DocumentAssistant

private struct EchoModel: LanguageModel {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(prompt)
            continuation.finish()
        }
    }
}

/// Recents and Favorites are virtual navigation groupings stored in a lightweight
/// sidecar (`documentState.json`). These tests cover MRU ordering, capping,
/// favorite toggling, cross-reload persistence, the two hard requirements
/// (a: works for Confidential too; b: never moves a document), and delete pruning.
@Suite("Recents and Favorites")
struct DocumentStateTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAssistant() throws -> (DocumentAssistant, URL) {
        let root = try workspace()
        let assistant = DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
        return (assistant, root)
    }

    @discardableResult
    private func writeText(_ name: String, in root: URL, body: String = "keyword body") throws -> URL {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Imports one document per name (unique) and returns their ids in name order.
    @discardableResult
    private func importDocs(_ assistant: DocumentAssistant, _ root: URL,
                            names: [String], category: DocumentCategory = .personal) async throws -> [UUID] {
        for name in names {
            let url = try writeText(name, in: root)
            try await assistant.importDocument(url: url, category: category)
        }
        let docs = await assistant.documents
        return names.compactMap { name in docs.first(where: { $0.name == name })?.id }
    }

    // MARK: - Recents

    @Test("markDocumentOpened orders most-recent-first and de-duplicates")
    func recentOrder() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = try await importDocs(assistant, root, names: ["a.txt", "b.txt", "c.txt"])
        let (a, b, c) = (ids[0], ids[1], ids[2])
        await assistant.markDocumentOpened(a)
        await assistant.markDocumentOpened(b)
        await assistant.markDocumentOpened(c)
        await assistant.markDocumentOpened(a)   // a jumps back to the front
        #expect(await assistant.recents == [a, c, b])
    }

    @Test("markDocumentOpened caps the MRU list at recentLimit")
    func recentCap() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let total = DocumentAssistant.recentLimit + 3
        let ids = try await importDocs(assistant, root, names: (0..<total).map { "doc\($0).txt" })
        for id in ids { await assistant.markDocumentOpened(id) }

        let recents = await assistant.recents
        #expect(recents.count == DocumentAssistant.recentLimit)
        #expect(recents.first == ids.last)          // newest stays at the front
        #expect(!recents.contains(ids[0]))          // oldest fell off the tail
    }

    // MARK: - Favorites

    @Test("setFavorite and toggleFavorite add, de-dupe, and remove")
    func favoriteToggle() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = try await importDocs(assistant, root, names: ["a.txt", "b.txt"])
        let (a, b) = (ids[0], ids[1])
        await assistant.setFavorite(a, favorite: true)
        await assistant.setFavorite(a, favorite: true)   // idempotent
        #expect(await assistant.favorites == [a])

        let removed = await assistant.toggleFavorite(a)  // removes
        #expect(removed == false)
        #expect(await assistant.favorites == [])

        let added = await assistant.toggleFavorite(b)    // adds
        #expect(added == true)
        #expect(await assistant.favorites == [b])
    }

    // MARK: - Persistence

    @Test("recents and favorites survive a reload from disk")
    func persistsAcrossReload() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("catalog.json")

        let first = DocumentAssistant(model: EchoModel(), store: store)
        let ids = try await importDocs(first, root, names: ["a.txt", "b.txt"])
        await first.markDocumentOpened(ids[1])
        await first.markDocumentOpened(ids[0])
        await first.setFavorite(ids[1], favorite: true)
        #expect(await first.recents == [ids[0], ids[1]])
        #expect(await first.favorites == [ids[1]])

        // A fresh instance over the same store reads the sidecar back.
        let second = DocumentAssistant(model: EchoModel(), store: store)
        #expect(await second.recents == [ids[0], ids[1]])
        #expect(await second.favorites == [ids[1]])
    }

    // MARK: - Requirement (b): virtual, never moves a document

    @Test("recents and favorites leave folderID and category untouched")
    func virtualGroupingsDoNotMoveDocs() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try await assistant.createFolder(name: "Work", category: .personal)
        let url = try writeText("report.txt", in: root)
        try await assistant.importDocument(url: url, category: .personal, folderID: folder)
        let id = try #require((await assistant.documents).first?.id)

        await assistant.markDocumentOpened(id)
        await assistant.setFavorite(id, favorite: true)

        let doc = try #require((await assistant.documents).first { $0.id == id })
        #expect(doc.folderID == folder)        // still filed in its folder
        #expect(doc.category == .personal)     // category unchanged
        #expect(await assistant.recents == [id])
        #expect(await assistant.favorites == [id])
    }

    // MARK: - Requirement (a): applies to Confidential too

    @Test("confidential docs can be favorited and recorded as recent")
    func confidentialSupported() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try writeText("policy.txt", in: root, body: "confidential keyword")
        try await assistant.importDocument(url: url, category: .confidential)
        let id = try #require((await assistant.documents).first?.id)

        await assistant.markDocumentOpened(id)
        await assistant.setFavorite(id, favorite: true)
        #expect(await assistant.recents == [id])
        #expect(await assistant.favorites == [id])

        // Favoriting/opening is metadata only: the doc is still read-only.
        await #expect(throws: DocumentError.self) { try await assistant.deleteDocument(id: id) }
    }

    // MARK: - Pruning

    @Test("deleting a document prunes it from recents and favorites")
    func pruningOnDelete() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = try await importDocs(assistant, root, names: ["a.txt", "b.txt"])
        let (a, b) = (ids[0], ids[1])
        await assistant.markDocumentOpened(a)
        await assistant.markDocumentOpened(b)
        await assistant.setFavorite(a, favorite: true)
        await assistant.setFavorite(b, favorite: true)

        try await assistant.deleteDocument(id: a)
        #expect(await assistant.recents == [b])
        #expect(await assistant.favorites == [b])
    }
}
