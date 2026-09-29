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

/// Deterministic keyword embedder: three dimensions for "apple", "banana",
/// "cherry" plus a tiny baseline so every vector is non-empty (an empty vector
/// signals "embedder unavailable" to deep search). Normalized, so cosine
/// similarity equals the dot product.
private struct StubEmbedder: DocumentEmbedder {
    func embed(_ text: String) async throws -> [Float] {
        let low = text.lowercased()
        var v: [Float] = [0.001, 0.001, 0.001]
        if low.contains("apple") { v[0] += 1 }
        if low.contains("banana") { v[1] += 1 }
        if low.contains("cherry") { v[2] += 1 }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }
}

/// Counts embed calls and returns a constant non-empty vector, so a test can
/// prove the query-vector cache keeps a repeated question off the embedder.
private actor CountingEmbedder: DocumentEmbedder {
    private(set) var calls = 0
    func embed(_ text: String) async throws -> [Float] {
        calls += 1
        return [1, 0, 0]
    }
}

private func workspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DocumentAssistantDeepSearch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeAssistant(_ root: URL, embedder: DocumentEmbedder = HashEmbedder()) -> DocumentAssistant {
    DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"), embedder: embedder)
}

/// Writes a text document into the workspace and imports it, returning its id.
@discardableResult
private func importText(_ assistant: DocumentAssistant, root: URL, name: String, text: String) async throws -> UUID {
    let url = root.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try await assistant.importDocument(url: url)
    let documents = await assistant.documents
    return try #require(documents.first(where: { $0.name == name })?.id)
}

@Suite("Deep search")
struct DeepSearchTests {
    // MARK: Literal pass

    @Test("counts case-insensitive occurrences per document, sorted by count")
    func literalCountsAndGrouping() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        let heavyID = try await importText(assistant, root: root, name: "heavy.txt", text: "alpha beta alpha gamma ALPHA")
        let lightID = try await importText(assistant, root: root, name: "light.txt", text: "one alpha only")

        let result = await assistant.deepSearch("alpha")
        #expect(result.totalOccurrences == 4)
        #expect(result.groups.count == 2)
        // Sorted by count descending: the heavy document comes first.
        #expect(result.groups[0].documentID == heavyID)
        #expect(result.groups[0].count == 3)
        #expect(result.groups[1].documentID == lightID)
        #expect(result.groups[1].count == 1)

        // Citation offsets point at the exact matches (first match at offset 0).
        let first = try #require(result.groups[0].occurrences.first)
        #expect(first.citation.location == 0)
        #expect(first.citation.length == "alpha".utf16.count)
        #expect(first.citation.documentID == heavyID)
        #expect(!first.snippet.isEmpty)
    }

    @Test("maps occurrences to page numbers via [Page N] markers")
    func literalPageMapping() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await importText(assistant, root: root, name: "paged.txt", text: "[Page 1]\nfoo bar\n\n[Page 2]\nfoo again")

        let result = await assistant.deepSearch("foo")
        #expect(result.totalOccurrences == 2)
        let pages = try #require(result.groups.first).occurrences.compactMap { $0.citation.page }
        #expect(pages == [1, 2])
    }

    @Test("listed occurrences are capped at 50 while the count stays exact")
    func occurrenceCap() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        let text = (0..<60).map { _ in "needle" }.joined(separator: " ")
        try await importText(assistant, root: root, name: "many.txt", text: text)

        let result = await assistant.deepSearch("needle")
        let group = try #require(result.groups.first)
        #expect(group.count == 60)
        #expect(group.occurrences.count == DocumentAssistant.deepSearchOccurrenceCap)
    }

    @Test("empty query returns an empty result")
    func emptyQuery() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        let result = await assistant.deepSearch("   ")
        #expect(result.totalOccurrences == 0)
        #expect(result.groups.isEmpty)
        #expect(!result.semanticAvailable)
    }

    // MARK: Semantic pass

    @Test("finds a similar claim that shares the keyword, not the wording")
    func semanticMatches() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        try await importText(assistant, root: root, name: "fruit.txt", text: "An apple a day keeps the doctor away.")
        try await importText(assistant, root: root, name: "other.txt", text: "Bananas are a yellow tropical fruit.")

        // Literal query "apples" doesn't appear verbatim in fruit.txt, but the
        // semantic pass still surfaces the apple passage.
        let result = await assistant.deepSearch("apples")
        #expect(result.semanticAvailable)
        #expect(result.totalOccurrences == 0)
        #expect(!result.semanticMatches.isEmpty)
        let top = try #require(result.semanticMatches.first)
        #expect(top.citation.document == "fruit.txt")
        #expect(top.score >= DocumentAssistant.semanticSimilarityThreshold)
        // The banana passage is below the threshold and must not appear.
        #expect(!result.semanticMatches.contains { $0.citation.document == "other.txt" })
    }

    @Test("ranks the closest passage first")
    func semanticRanking() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        try await importText(assistant, root: root, name: "mixed.txt", text: "apple and banana together")
        try await importText(assistant, root: root, name: "pure.txt", text: "apple only")

        let result = await assistant.deepSearch("apple")
        #expect(result.semanticMatches.count == 2)
        #expect(result.semanticMatches[0].citation.document == "pure.txt")
        #expect(result.semanticMatches[0].score > result.semanticMatches[1].score)
    }

    @Test("HashEmbedder degrades to literal-only results")
    func semanticUnavailable() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root) // default HashEmbedder returns []
        try await importText(assistant, root: root, name: "doc.txt", text: "alpha beta")

        let result = await assistant.deepSearch("alpha")
        #expect(!result.semanticAvailable)
        #expect(result.semanticMatches.isEmpty)
        #expect(result.totalOccurrences == 1)
    }

    // MARK: Embedding cache

    @Test("embeddings persist to disk and reload into a fresh assistant")
    func embeddingCacheRoundTrip() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        try await importText(assistant, root: root, name: "a.txt", text: "apple text")
        try await importText(assistant, root: root, name: "b.txt", text: "banana text")

        _ = await assistant.deepSearch("apple")
        let cached = await assistant.embeddings.count
        #expect(cached > 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("embeddings.json").path))

        // A fresh assistant on the same store loads the cache without recomputing.
        let reloaded = makeAssistant(root, embedder: StubEmbedder())
        let restored = await reloaded.embeddings.count
        #expect(restored == cached)
    }

    @Test("stale embeddings are pruned after a document is deleted")
    func embeddingCachePrunesStale() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        let appleID = try await importText(assistant, root: root, name: "apple.txt", text: "apple text")
        try await importText(assistant, root: root, name: "banana.txt", text: "banana text")

        _ = await assistant.deepSearch("fruit")
        let before = await assistant.embeddings.count
        #expect(before >= 2)

        try await assistant.deleteDocument(id: appleID)
        _ = await assistant.deepSearch("fruit")
        let after = await assistant.embeddings.count
        #expect(after < before)
        let staleChunks = await assistant.index.filter { $0.documentID == appleID }
        #expect(staleChunks.isEmpty)
    }
}

/// Waits until every indexed chunk has a cached embedding vector. Polling on
/// full coverage (rather than the transient in-flight set, which can be empty
/// between back-to-back imports before the next job starts, or a raw count,
/// which stale vectors inflate) keeps multi-import fixtures deterministic.
/// If a job fails outright the poll times out and the test records an issue.
private func waitForBackgroundEmbedding(_ assistant: DocumentAssistant) async throws {
    var tries = 0
    while tries < 300 {
        let chunks = await assistant.index
        let cached = await assistant.embeddings
        if chunks.allSatisfy({ cached[$0.id] != nil }) { return }
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
    Issue.record("background embedding did not settle in time")
}

@Suite("Hybrid retrieval")
struct HybridRetrievalTests {
    @Test("retrieve surfaces a semantically similar passage with no lexical overlap")
    func semanticOnlyMatch() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        try await importText(assistant, root: root, name: "fruit.txt", text: "An apple a day keeps the doctor away.")
        try await waitForBackgroundEmbedding(assistant)

        // "apples" appears nowhere verbatim, so the lexical side is empty and
        // only the semantic side can surface the passage.
        let passages = await assistant.retrieve("apples")
        #expect(passages.contains { $0.citation.document == "fruit.txt" })
    }

    @Test("a strong lexical match still ranks first when both signals agree")
    func lexicalStrengthSurvivesFusion() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        try await importText(assistant, root: root, name: "exact.txt", text: "apple pie recipe with apple")
        try await importText(assistant, root: root, name: "related.txt", text: "apple cherry loaf")
        try await waitForBackgroundEmbedding(assistant)

        let passages = await assistant.retrieve("apple pie")
        try #require(passages.count >= 2)
        // exact.txt wins both lists: lexical token+phrase hits, and a purer
        // apple vector than the apple+cherry chunk (cosine 1.0 vs ~0.71) —
        // so fusion ranks it first and the diluted chunk second.
        #expect(passages[0].citation.document == "exact.txt")
        #expect(passages[1].citation.document == "related.txt")
    }

    @Test("HashEmbedder keeps retrieve purely lexical")
    func lexicalFallbackUnchanged() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root) // default HashEmbedder returns []
        try await importText(assistant, root: root, name: "alpha.txt", text: "alpha beta")
        try await importText(assistant, root: root, name: "other.txt", text: "gamma delta")

        let passages = await assistant.retrieve("alpha")
        try #require(passages.count == 1)
        #expect(passages[0].citation.document == "alpha.txt")
        // Lexical score is IDF-weighted query coverage plus the phrase bonus, so a
        // single-token exact match is a full-coverage hit well above the floor.
        #expect(passages[0].score >= 1 + DocumentAssistant.lexicalPhraseBonus - 0.001)
    }

    @Test("the lexical coverage floor prunes weak matches but never empties the list")
    func coverageFloorPrunesWeakMatches() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await importText(assistant, root: root, name: "strong.txt", text: "zebra crossing policy")
        for i in 0..<7 {
            try await importText(assistant, root: root, name: "weak\(i).txt", text: "policy note \(i) alpha beta gamma")
        }

        // A long question used to match every chunk containing one common word.
        let passages = await assistant.retrieve(
            "zebra crossing policy for the annual financial reporting period", limit: 20
        )
        #expect(passages.first?.citation.document == "strong.txt")
        // Only the strong chunk clears the coverage floor; the retention safety net
        // then keeps the top-scoring few so the answer still has evidence.
        #expect(passages.count == DocumentAssistant.lexicalMinRetained)
    }

    @Test("retrieveDetailed reports per-pass counts and ranks inside a scope")
    func retrievalStatsAndScope() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        let appleID = try await importText(assistant, root: root, name: "apple.txt", text: "apple text")
        try await importText(assistant, root: root, name: "banana.txt", text: "banana text")
        try await waitForBackgroundEmbedding(assistant)

        let all = await assistant.retrieveDetailed("apple", limit: 10)
        #expect(all.stats.lexical > 0)
        #expect(all.stats.semantic > 0)
        #expect(all.stats.semanticAvailable)
        #expect(all.stats.fused > 0)

        let scoped = await assistant.retrieveDetailed("apple", limit: 10, scope: [appleID])
        #expect(!scoped.passages.isEmpty)
        #expect(scoped.passages.allSatisfy { $0.citation.documentID == appleID })
    }

    @Test("a repeated question reuses the cached query vector")
    func queryVectorIsCached() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = CountingEmbedder()
        let assistant = makeAssistant(root, embedder: embedder)
        try await importText(assistant, root: root, name: "apple.txt", text: "apple text")
        try await waitForBackgroundEmbedding(assistant)

        let afterIndexing = await embedder.calls
        _ = await assistant.retrieve("apple")
        let afterFirst = await embedder.calls
        #expect(afterFirst == afterIndexing + 1)
        _ = await assistant.retrieve("apple")
        #expect(await embedder.calls == afterFirst)
    }

    @Test("RRF fusion ranks passages present in both lists first, deterministically")
    func fusionOrdering() throws {
        let a = Passage(text: "A", citation: Citation(document: "d", conceptID: "a"), score: 0)
        let b = Passage(text: "B", citation: Citation(document: "d", conceptID: "b"), score: 0)
        let c = Passage(text: "C", citation: Citation(document: "d", conceptID: "c"), score: 0)
        let fused = DocumentAssistant.fuseRRF(lexical: [a, b], semantic: [b, c])
        try #require(fused.count == 3)
        // b appears in both lists: 1/62 + 1/61 beats a (1/61) and c (1/62).
        #expect(fused[0].citation.conceptID == "b")
        #expect(fused[1].citation.conceptID == "a")
        #expect(fused[2].citation.conceptID == "c")
    }

    // MARK: Import-time embedding

    @Test("importing a document embeds its chunks in the background and persists them")
    func importTriggersEmbedding() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        try await importText(assistant, root: root, name: "doc.txt", text: "apple text")

        try await waitForBackgroundEmbedding(assistant)
        let chunks = await assistant.index.count
        let cached = await assistant.embeddings.count
        #expect(chunks > 0)
        #expect(cached == chunks)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("embeddings.json").path))
    }

    @Test("updateNote re-embeds the regenerated chunks")
    func noteUpdateReembeds() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        let noteID = try await assistant.createNote(title: "N", text: "apple note")
        try await waitForBackgroundEmbedding(assistant)

        try await assistant.updateNote(id: noteID, title: "N", text: "banana note, fully rewritten")
        try await waitForBackgroundEmbedding(assistant)
        // Every regenerated chunk of the note has a fresh vector, and stale
        // vectors from the previous revision were pruned.
        let chunks = await assistant.index.filter { $0.documentID == noteID }
        let cached = await assistant.embeddings
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { cached[$0.id] != nil })
        let liveIDs = Set(await assistant.index.map { $0.id })
        #expect(cached.keys.allSatisfy { liveIDs.contains($0) })
    }

    @Test("warmEmbeddingCache backfills a cold cache without a deep search")
    func warmUpBackfillsColdCache() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = makeAssistant(root, embedder: StubEmbedder())
        try await importText(first, root: root, name: "a.txt", text: "apple text")
        try await waitForBackgroundEmbedding(first)

        // Simulate a library whose vectors are missing at launch (ingested before
        // import-time embedding existed, or cache invalidated): catalog + sources
        // on disk, embeddings.json gone. The warm-up alone must refill the cache.
        try FileManager.default.removeItem(at: root.appendingPathComponent("embeddings.json"))
        let relaunched = makeAssistant(root, embedder: StubEmbedder())
        await relaunched.warmEmbeddingCache()
        try await waitForBackgroundEmbedding(relaunched)

        let chunks = await relaunched.index
        let cached = await relaunched.embeddings
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { cached[$0.id] != nil })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("embeddings.json").path))
    }

    @Test("deleteDocument prunes cached vectors immediately")
    func deletePrunesImmediately() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        let appleID = try await importText(assistant, root: root, name: "apple.txt", text: "apple text")
        try await importText(assistant, root: root, name: "banana.txt", text: "banana text")
        try await waitForBackgroundEmbedding(assistant)
        let before = await assistant.embeddings.count
        #expect(before >= 2)

        try await assistant.deleteDocument(id: appleID)
        // No deep search needed: the delete path prunes synchronously.
        let after = await assistant.embeddings.count
        #expect(after < before)
        let remainingChunks = await assistant.index.filter { $0.documentID == appleID }
        #expect(remainingChunks.isEmpty)
    }

    @Test("embedding progress reports library and per-document state")
    func embeddingProgressReports() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root, embedder: StubEmbedder())
        let id = try await importText(assistant, root: root, name: "apple.txt", text: "apple text")

        // The index is built synchronously at import, so chunk totals are known
        // immediately, even before the background job finishes.
        let mid = await assistant.libraryEmbeddingProgress()
        #expect(mid.totalChunks > 0)

        try await waitForBackgroundEmbedding(assistant)

        // Vectors are cached a moment before the job clears its in-flight flag; poll
        // until settled so the isSettled/isReady assertions stay deterministic.
        var progress = mid
        var tries = 0
        while tries < 300 {
            progress = await assistant.libraryEmbeddingProgress()
            if progress.isSettled { break }
            try await Task.sleep(for: .milliseconds(10))
            tries += 1
        }
        #expect(progress.isSettled)
        #expect(progress.isFullyEmbedded)
        #expect(progress.embeddedChunks == progress.totalChunks)

        let states = await assistant.embeddingStates()
        let state = try #require(states[id])
        #expect(!state.isInFlight)
        #expect(state.isReady)
        #expect(state.embeddedChunks >= state.totalChunks)

        let pending = await assistant.pendingEmbeddingDocumentIDs()
        #expect(pending.isEmpty)
    }
}
