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

@Suite("OKF tool layer")
struct OKFToolsTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAssistantToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAssistant(_ root: URL) -> DocumentAssistant {
        DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
    }

    @Test("listDocuments returns a summary per imported document")
    func listDocuments() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("alpha.txt")
        try "Alpha keyword content.".write(to: source, atomically: true, encoding: .utf8)
        let assistant = makeAssistant(root)
        try await assistant.importDocument(url: source)

        let summaries = await assistant.listDocuments()
        #expect(summaries.count == 1)
        #expect(summaries.first?.name == "alpha.txt")
        #expect(summaries.first?.indexedAt != nil)
    }

    @Test("searchConcepts filters by document and page and bounds bodies")
    func searchFiltersAndBounds() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        try "[Page 1]\nAlpha unique wording.\n\n[Page 2]\nBeta unique wording.".write(
            to: a, atomically: true, encoding: .utf8
        )
        let b = root.appendingPathComponent("b.txt")
        try "Gamma unique wording.".write(to: b, atomically: true, encoding: .utf8)
        let assistant = makeAssistant(root)
        try await assistant.importDocument(url: a)
        try await assistant.importDocument(url: b)

        let docs = await assistant.listDocuments()
        let aID = try #require(docs.first(where: { $0.name == "a.txt" })?.id)

        let across = await assistant.searchConcepts(query: "unique", limit: 20)
        #expect(across.count >= 2)

        let onlyA = await assistant.searchConcepts(
            query: "unique", filters: ConceptFilters(documentID: aID), limit: 20
        )
        #expect(!onlyA.isEmpty)
        #expect(onlyA.allSatisfy { $0.citation.documentID == aID })

        let page2 = await assistant.searchConcepts(
            query: "unique", filters: ConceptFilters(documentID: aID, page: 2), limit: 20
        )
        #expect(!page2.isEmpty)
        #expect(page2.allSatisfy { $0.citation.page == 2 })

        let bounded = await assistant.searchConcepts(query: "unique", limit: 20, maxBodyCharacters: 4)
        #expect(bounded.allSatisfy { $0.body.count <= 4 })
    }

    @Test("readConcept bounds the body and rejects path traversal ids")
    func readBoundsAndTraversal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("long.txt")
        try String(repeating: "word ", count: 400).write(to: source, atomically: true, encoding: .utf8)
        let assistant = makeAssistant(root)
        try await assistant.importDocument(url: source)

        let hit = try #require(await assistant.searchConcepts(query: "word", limit: 1).first)
        let full = try await assistant.readConcept(id: hit.conceptID)
        #expect(full.body.count > 20)
        let bounded = try await assistant.readConcept(id: hit.conceptID, maxBodyCharacters: 20)
        #expect(bounded.body.count == 20)

        await #expect(throws: OKFError.self) {
            _ = try await assistant.readConcept(id: "../../secret")
        }
    }

    @Test("citeConcept reproduces the exact UTF-16 source range")
    func citeRange() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("unicode.txt")
        let text = "[Page 1]\n" + String(repeating: "😀中文 keyword ", count: 200)
        try text.write(to: source, atomically: true, encoding: .utf8)
        let assistant = makeAssistant(root)
        try await assistant.importDocument(url: source)

        let hit = try #require(await assistant.searchConcepts(query: "keyword", limit: 5).first)
        let citation = try await assistant.citeConcept(id: hit.conceptID)
        #expect(citation.documentID != nil)
        #expect(citation.page == 1)
        let range = try #require(citation.utf16Range)
        let concept = try await assistant.readConcept(id: hit.conceptID)
        let expected = concept.body.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((text as NSString).substring(with: range) == expected)
    }

    @Test("answer streams tool stages, then citations, then tokens")
    func answerEvents() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("zephyr.txt")
        try "Zephyr unique token content.".write(to: source, atomically: true, encoding: .utf8)
        let assistant = makeAssistant(root)
        try await assistant.importDocument(url: source)

        var events: [AnswerEvent] = []
        for try await event in await assistant.answer("Zephyr", mode: .ask) {
            events.append(event)
        }

        guard case .stage(.searching)? = events.first else {
            Issue.record("Expected a searching stage first")
            return
        }
        guard case .stage(.finished)? = events.last else {
            Issue.record("Expected a finished stage last")
            return
        }

        var citations: [Citation]?
        var sawGenerating = false
        var citationsBeforeTokens = false
        var generatingBeforeTokens = false
        var sawToken = false
        for event in events {
            switch event {
            case .stage(.searching): break
            case .stage(.readingSources): break
            case .stage(.composingPrompt): break
            case .stage(.generating):
                sawGenerating = true
                if !sawToken { generatingBeforeTokens = true }
            case .stage(.finished): break
            case .citations(let found):
                citations = found
                if !sawToken { citationsBeforeTokens = true }
            case .token:
                sawToken = true
            }
        }
        #expect(sawGenerating)
        #expect(citationsBeforeTokens)
        #expect(generatingBeforeTokens)

        let resolved = try #require(citations)
        #expect(!resolved.isEmpty)
        let conceptID = try #require(resolved.first?.conceptID)
        let tokens = events.compactMap { event -> String? in
            if case .token(let text) = event { return text }
            return nil
        }.joined()
        #expect(tokens.contains(conceptID))
        #expect(tokens.contains("Zephyr unique token"))
    }
}
