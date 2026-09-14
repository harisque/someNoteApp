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

@Suite("Native OKF catalog")
struct OKFBundleTests {
    @Test("Unicode and preamble text survive segmentation with valid source offsets")
    func unicodeSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("unicode.txt")
        let text = "Preamble keyword\n[Page 1]\n" + String(repeating: "😀中文 test ", count: 300)
        try text.write(to: source, atomically: true, encoding: .utf8)
        let assistant = DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
        try await assistant.importDocument(url: source)
        #expect(!(await assistant.retrieve("Preamble")).isEmpty)
        for hit in await assistant.retrieve("test", limit: 100) {
            let range = NSRange(location: try #require(hit.citation.location), length: hit.text.utf16.count)
            #expect((text as NSString).substring(with: range) == hit.text)
        }
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAssistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("PDF page markers preserve the text that follows each marker")
    func pageContentIsIndexed() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("catalog.json")
        let source = root.appendingPathComponent("pages.txt")
        try "[Page 1]\nAlpha unique wording.\n\n[Page 2]\nBeta material.".write(
            to: source, atomically: true, encoding: .utf8
        )
        let assistant = DocumentAssistant(model: EchoModel(), store: store)
        try await assistant.importDocument(url: source)

        let alpha = await assistant.retrieve("Alpha unique")
        #expect(alpha.first?.text.contains("Alpha unique wording") == true)
        #expect(alpha.first?.citation.page == 1)
        let beta = await assistant.retrieve("Beta material")
        #expect(beta.first?.citation.page == 2)
    }

    @Test("OKF concepts round-trip with required type and exact body")
    func conceptRoundTrip() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = Document(name: "Policy [Final].md", text: "Exact source wording.")
        let section = IndexedChunk(
            documentID: document.id, document: document.name,
            text: "Exact source wording.", page: 4, location: 23
        )
        let bundle = OKFBundle(root: root.appendingPathComponent("OKFBundle"))
        try bundle.write(documents: [document], sections: [section])

        let concept = try bundle.readConcept(id: bundle.conceptID(for: section))
        #expect(concept.type == "Document Section")
        #expect(concept.metadata["page"] == "4")
        #expect(concept.body.trimmingCharacters(in: .whitespacesAndNewlines) == section.text)
        #expect(FileManager.default.fileExists(atPath: bundle.root.appendingPathComponent("index.md").path))
    }

    @Test("Existing JSON documents migrate and deletion removes their OKF concepts")
    func migrationAndDeletion() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("catalog.json")
        let legacy = Document(name: "Legacy.txt", text: "Legacy migration keyword.")
        try JSONEncoder().encode([legacy]).write(to: store, options: .atomic)

        let assistant = DocumentAssistant(model: EchoModel(), store: store)
        #expect((await assistant.documents).map(\.id) == [legacy.id])
        #expect((await assistant.retrieve("migration keyword")).count == 1)
        try await assistant.deleteDocument(id: legacy.id)

        let concepts = try OKFBundle(root: root.appendingPathComponent("OKFBundle")).readAllConcepts()
        #expect(concepts.isEmpty)
        #expect((await assistant.documents).isEmpty)
    }
}
