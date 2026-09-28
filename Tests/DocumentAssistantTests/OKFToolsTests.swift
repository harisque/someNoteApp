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

    @Test("answer streams tool stages, then citations, then tokens, then used citations")
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
        var rankingAfterSearching = false
        var sawSearching = false
        for event in events {
            switch event {
            case .stage(.searching): sawSearching = true
            case .stage(.ranking): rankingAfterSearching = sawSearching
            case .stage(.readingSources): break
            case .stage(.composingPrompt): break
            case .stage(.generating):
                sawGenerating = true
                if !sawToken { generatingBeforeTokens = true }
            case .stage(.finished): break
            case .citations(let found):
                citations = found
                if !sawToken { citationsBeforeTokens = true }
            case .usedCitations: break
            case .token:
                sawToken = true
            }
        }
        #expect(sawGenerating)
        #expect(citationsBeforeTokens)
        #expect(generatingBeforeTokens)
        #expect(rankingAfterSearching)

        let resolved = try #require(citations)
        #expect(!resolved.isEmpty)
        let conceptID = try #require(resolved.first?.conceptID)
        let tokens = events.compactMap { event -> String? in
            if case .token(let text) = event { return text }
            return nil
        }.joined()
        #expect(tokens.contains(conceptID))
        #expect(tokens.contains("Zephyr unique token"))

        // The echoed prompt mentions "[Excerpt 1]", so the used-citation event
        // (after the tokens, before finished) resolves to exactly that excerpt.
        let usedIndex = try #require(events.firstIndex { event in
            if case .usedCitations = event { return true }
            return false
        })
        let lastTokenIndex = try #require(events.lastIndex { event in
            if case .token = event { return true }
            return false
        })
        #expect(usedIndex > lastTokenIndex)
        #expect(usedIndex == events.count - 2)  // immediately before .finished
        guard case .usedCitations(let used) = events[usedIndex] else {
            Issue.record("Expected used citations")
            return
        }
        #expect(used == [resolved[0]])
    }

    @Test("used citations fall back to the first packed excerpts when nothing is cited")
    func usedCitationFallback() {
        let hits = (1...5).map { index in
            ConceptHit(
                conceptID: "sections/doc/\(index)",
                citation: Citation(document: "doc.pdf", page: index, location: index * 100, length: 10, conceptID: "sections/doc/\(index)"),
                body: "body \(index)",
                score: Double(6 - index)
            )
        }
        let cited = DocumentAssistant.usedCitations(in: "No markers here.", from: hits)
        #expect(cited.count == 3)
        #expect(cited.map { $0.page } == [1, 2, 3])

        let referenced = DocumentAssistant.usedCitations(in: "Risk rose [2] and again [Excerpt 4].", from: hits)
        #expect(referenced.map { $0.page } == [2, 4])
    }

    @Test("excerpt reference parser reads every marker form and ignores long numbers")
    func excerptReferenceParsing() {
        #expect(ExcerptReferenceParser.numbers(in: "") == [])
        #expect(ExcerptReferenceParser.numbers(in: "Claim [1] and [3][5].") == [1, 3, 5])
        #expect(ExcerptReferenceParser.numbers(in: "See [Excerpt 2] plus Excerpt 7.") == [2, 7])
        #expect(ExcerptReferenceParser.numbers(in: "Nothing cited here.") == [])
        // Four-digit numbers are years, not excerpt markers.
        #expect(ExcerptReferenceParser.numbers(in: "In [2024] the policy changed.") == [])
    }

    @Test("mergeAdjacent collapses overlapping same-document hits only")
    func mergesOverlappingChunks() throws {
        let docID = UUID()
        let otherID = UUID()
        // Chunk windows overlap by 40 UTF-16 units here: [0,100) and [60,160).
        let first = ConceptHit(
            conceptID: "sections/a/0",
            citation: Citation(document: "a.pdf", page: 1, location: 0, length: 100, conceptID: "sections/a/0", documentID: docID),
            body: String(repeating: "x", count: 100),
            score: 0.9
        )
        let second = ConceptHit(
            conceptID: "sections/a/60",
            citation: Citation(document: "a.pdf", page: 1, location: 60, length: 100, conceptID: "sections/a/60", documentID: docID),
            body: String(repeating: "x", count: 40) + String(repeating: "y", count: 60),
            score: 0.4
        )
        let far = ConceptHit(
            conceptID: "sections/a/5000",
            citation: Citation(document: "a.pdf", page: 9, location: 5000, length: 50, conceptID: "sections/a/5000", documentID: docID),
            body: String(repeating: "z", count: 50),
            score: 0.3
        )
        let otherDoc = ConceptHit(
            conceptID: "sections/b/0",
            citation: Citation(document: "b.pdf", page: 1, location: 0, length: 100, conceptID: "sections/b/0", documentID: otherID),
            body: String(repeating: "w", count: 100),
            score: 0.8
        )
        let link = ConceptHit(
            conceptID: "datalinks/1",
            citation: Citation(document: "STAN", conceptID: "datalinks/1"),
            body: "summary",
            score: 0.7
        )

        let merged = DocumentAssistant.mergeAdjacent([first, second, far, otherDoc, link])
        // first+second collapse; far, otherDoc and the Data Link survive untouched.
        #expect(merged.count == 4)
        let combined = try #require(merged.first { $0.citation.location == 0 && $0.citation.documentID == docID })
        #expect(combined.score == 0.9)
        #expect(combined.citation.length == 160)
        #expect(combined.citation.conceptID == "sections/a/0")
        // The overlapping prefix is not duplicated: 100 x's then 60 y's.
        #expect(combined.body.count == 160)
        #expect(combined.body.hasSuffix(String(repeating: "y", count: 60)))
        #expect(merged.contains { $0.conceptID == "datalinks/1" })
        #expect(merged.contains { $0.conceptID == "sections/b/0" })
        // Sorted by score descending.
        #expect(merged.map(\.score) == merged.map(\.score).sorted(by: >))
    }

    @Test("makePrompt leads with the question, caps each excerpt, and stays in budget")
    func promptShapeAndBudget() throws {
        let hits = (1...6).map { index in
            ConceptHit(
                conceptID: "sections/doc/\(index)",
                citation: Citation(document: "doc.pdf", page: index, location: index * 10_000, length: 4000, conceptID: "sections/doc/\(index)"),
                body: String(repeating: "evidence ", count: 400),  // ~3600 chars, over the per-excerpt cap
                score: Double(7 - index)
            )
        }
        let budget = 6000
        let result = DocumentAssistant.makePrompt(
            question: "What are the risks?", mode: .ask, hits: hits, characterBudget: budget
        )
        #expect(result.prompt.count <= budget)
        #expect(!result.included.isEmpty)
        // Question and instructions lead; evidence follows.
        let questionIndex = try #require(result.prompt.range(of: "Question: What are the risks?")?.lowerBound)
        let firstExcerpt = try #require(result.prompt.range(of: "[Excerpt 1]")?.lowerBound)
        #expect(questionIndex < firstExcerpt)
        #expect(result.prompt.contains("Infer, combine, and summarize across them"))
        #expect(result.prompt.contains("Mark each statement with the supporting excerpt numbers"))
        // Each packed body is capped, so several distinct excerpts fit the budget.
        #expect(result.included.count > 1)
        let capped = String(hits[0].body.prefix(OKFToolLimits.maxExcerptCharacters))
        #expect(result.prompt.contains(capped))
        #expect(!result.prompt.contains(hits[0].body))
    }

    @Test("a single oversized excerpt is still truncated into the prompt")
    func oversizedSingleExcerpt() {
        let hit = ConceptHit(
            conceptID: "sections/doc/0",
            citation: Citation(document: "doc.pdf", page: 1, location: 0, length: 9000, conceptID: "sections/doc/0"),
            body: String(repeating: "long ", count: 1800),
            score: 1
        )
        let result = DocumentAssistant.makePrompt(question: "q", mode: .ask, hits: [hit], characterBudget: 1200)
        #expect(result.included.count == 1)
        #expect(result.prompt.count <= 1200)
    }

    @Test("candidateLimit stays within the excerpt ceiling")
    func candidateLimitBounds() {
        #expect(DocumentAssistant.candidateLimit(forCharacterBudget: 0) == 6)
        #expect(DocumentAssistant.candidateLimit(forCharacterBudget: 1_000_000) == OKFToolLimits.maxCandidateExcerpts)
    }

    // MARK: - Token-accurate packing

    /// Counts one token per two characters (rounded up), standing in for a real
    /// tokenizer so token-budget assertions are deterministic. Ceiling division
    /// is subadditive, so the whole packed prompt can never measure above the
    /// sum the packer accounted for.
    private struct HalfTokenCounter: PromptTokenCounter {
        func tokenCount(_ text: String) async -> Int? { (text.count + 1) / 2 }
    }

    private struct UnavailableTokenCounter: PromptTokenCounter {
        func tokenCount(_ text: String) async -> Int? { nil }
    }

    private static func packingHits(_ count: Int = 6) -> [ConceptHit] {
        (1...count).map { index in
            ConceptHit(
                conceptID: "sections/doc/\(index)",
                citation: Citation(document: "doc.pdf", page: index, location: index * 10_000, length: 900, conceptID: "sections/doc/\(index)"),
                body: String(repeating: "evidence ", count: 100),  // 900 chars
                score: Double(count + 1 - index)
            )
        }
    }

    @Test("token-accurate packing measures excerpts with the injected counter")
    func tokenBudgetPacking() async throws {
        let hits = Self.packingHits()
        let counter = HalfTokenCounter()
        // Budget expressed relative to the measured scaffolding, so the test
        // doesn't depend on the exact header wording.
        let headerTokens = try #require(await counter.tokenCount(DocumentAssistant.promptHeader(question: "q", mode: .ask)))
        let footerTokens = try #require(await counter.tokenCount(DocumentAssistant.promptFooter()))
        let packingTokens = headerTokens + footerTokens + 1_500
        let result = await DocumentAssistant.makePrompt(
            question: "q", mode: .ask, hits: hits,
            packingTokens: packingTokens, characterBudget: 100_000, counter: counter
        )
        // The packed prompt measures within the token budget, not the character one.
        let measured = try #require(await counter.tokenCount(result.prompt))
        #expect(measured <= packingTokens)
        #expect(!result.included.isEmpty)
        #expect(result.included.count < hits.count)  // packed by tokens, stopped early
        #expect(result.prompt.contains("[Excerpt 1]"))
        #expect(result.prompt.contains("Question: q"))
    }

    @Test("packing falls back to the character budget when the counter is unavailable")
    func tokenCounterFallback() async {
        let hits = Self.packingHits(2)
        let fallback = await DocumentAssistant.makePrompt(
            question: "q", mode: .ask, hits: hits,
            packingTokens: 100, characterBudget: 5_000, counter: UnavailableTokenCounter()
        )
        let direct = DocumentAssistant.makePrompt(
            question: "q", mode: .ask, hits: hits, characterBudget: 5_000
        )
        #expect(fallback.prompt == direct.prompt)
        #expect(fallback.included.map(\.conceptID) == direct.included.map(\.conceptID))
    }

    @Test("an oversized first excerpt is shrunk to fit the token budget")
    func oversizedExcerptTokenPacking() async throws {
        let counter = HalfTokenCounter()
        let hits = Self.packingHits(1)
        // Leave only a sliver for the ~490-token block once the header and the
        // closing directive are measured; it must be truncated in, never refused.
        let headerTokens = try #require(await counter.tokenCount(DocumentAssistant.promptHeader(question: "q", mode: .ask)))
        let footerTokens = try #require(await counter.tokenCount(DocumentAssistant.promptFooter()))
        let packingTokens = headerTokens + footerTokens + 17
        let result = await DocumentAssistant.makePrompt(
            question: "q", mode: .ask, hits: hits,
            packingTokens: packingTokens, characterBudget: 100_000, counter: counter
        )
        #expect(result.included.count == 1)
        let measured = try #require(await counter.tokenCount(result.prompt))
        #expect(measured <= packingTokens)
    }

    @Test("the prompt requires an English answer up front and again after the evidence")
    func englishAnswerEnforcement() async throws {
        let hits = Self.packingHits(2)
        let result = await DocumentAssistant.makePrompt(
            question: "q", mode: .ask, hits: hits,
            packingTokens: 4_000, characterBudget: 100_000, counter: HalfTokenCounter()
        )
        let footer = DocumentAssistant.promptFooter().trimmingCharacters(in: .whitespacesAndNewlines)
        // Stated in the rules, ahead of the question.
        #expect(result.prompt.contains("Always answer in English"))
        // Repeated as the closing line, after every excerpt, so a non-English
        // document can't set the answer's language by being the last thing read.
        #expect(result.prompt.hasSuffix(footer))
        let footerIndex = try #require(result.prompt.range(of: footer)?.lowerBound)
        for index in 1...max(1, result.included.count) {
            let marker = try #require(result.prompt.range(of: "[Excerpt \(index)]")?.lowerBound)
            #expect(marker < footerIndex)
        }
    }
}
