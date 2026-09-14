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

@Suite("Source retention")
struct SourceRetentionTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAssistantRetention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("import copies the source file; delete removes it")
    func retainsAndCleansUp() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.md")
        try "# Notes\nSome markdown body.".write(to: source, atomically: true, encoding: .utf8)
        let assistant = DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
        try await assistant.importDocument(url: source)

        let id = try #require(await assistant.listDocuments().first?.id)
        let stored = try #require(await assistant.sourceURL(for: id))
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(stored.deletingLastPathComponent().lastPathComponent == "Sources")

        let documents = await assistant.documents
        #expect(documents.first?.sourceFile != nil)
        #expect(documents.first?.kind == .markdown)

        try await assistant.deleteDocument(id: id)
        #expect(await assistant.sourceURL(for: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: stored.path))
    }

    @Test("legacy documents without a retained file report no source URL")
    func missingSourceIsNil() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
        // A document constructed directly (no import) has no retained source file.
        #expect(await assistant.sourceURL(for: UUID()) == nil)
    }
}
