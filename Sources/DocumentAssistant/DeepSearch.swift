import Foundation

// MARK: - Result types

/// A single exact-match hit: a citation that navigates to the precise UTF-16
/// range in the source document, plus a short context snippet for display.
public struct DeepSearchOccurrence: Codable, Hashable, Sendable, Identifiable {
    public let citation: Citation
    public let snippet: String
    public init(citation: Citation, snippet: String) {
        self.citation = citation
        self.snippet = snippet
    }
    /// Occurrence citations carry no conceptID, so `citation.id` is
    /// `documentID-location`, unique per hit.
    public var id: String { "\(citation.id)" }
}

/// All exact-match hits within one document. `count` is always exact; the
/// listed `occurrences` are capped (see `DocumentAssistant.deepSearchOccurrenceCap`)
/// so a common term in a large document can't blow up the sheet.
public struct DocumentOccurrences: Codable, Hashable, Sendable, Identifiable {
    public let documentID: UUID
    public let documentName: String
    public let count: Int
    public let occurrences: [DeepSearchOccurrence]
    public init(documentID: UUID, documentName: String, count: Int, occurrences: [DeepSearchOccurrence]) {
        self.documentID = documentID
        self.documentName = documentName
        self.count = count
        self.occurrences = occurrences
    }
    public var id: UUID { documentID }
}

/// The full deep-search answer: exact occurrences grouped per document plus
/// semantically similar passages (embedding cosine similarity). When the
/// configured embedder can't produce vectors, `semanticAvailable` is false and
/// `semanticMatches` is empty; the literal results are always produced.
public struct DeepSearchResult: Codable, Hashable, Sendable {
    public let query: String
    public let groups: [DocumentOccurrences]
    public let totalOccurrences: Int
    public let semanticMatches: [Passage]
    public let semanticAvailable: Bool
    public init(query: String, groups: [DocumentOccurrences], totalOccurrences: Int, semanticMatches: [Passage], semanticAvailable: Bool) {
        self.query = query
        self.groups = groups
        self.totalOccurrences = totalOccurrences
        self.semanticMatches = semanticMatches
        self.semanticAvailable = semanticAvailable
    }
}

// MARK: - Deep search

@available(macOS 10.15, iOS 13, *)
extension DocumentAssistant {
    /// Runs a cross-document deep search for `q`:
    /// 1. Literal pass — case-insensitive substring scan of every document's
    ///    full text, producing exact per-document occurrence counts and
    ///    navigable citations (with page numbers for `[Page N]`-segmented PDFs).
    /// 2. Semantic pass — embeds the query and ranks cached chunk embeddings by
    ///    cosine similarity, surfacing similar claims that don't share the exact
    ///    wording. Chunk embeddings are computed lazily on first use (reporting
    ///    progress via `onProgress(done, total)`) and persisted to
    ///    `embeddings.json`, so the cost is paid once per library change.
    ///
    /// The semantic pass degrades gracefully: with an embedder that returns
    /// empty vectors (e.g. `HashEmbedder`) or on any embedding failure,
    /// `semanticAvailable` is false and only literal results are returned.
    public func deepSearch(
        _ q: String,
        onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> DeepSearchResult {
        let term = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return DeepSearchResult(query: q, groups: [], totalOccurrences: 0, semanticMatches: [], semanticAvailable: false)
        }

        let groups = literalOccurrences(of: term)
        let total = groups.reduce(0) { $0 + $1.count }

        var semanticMatches: [Passage] = []
        var semanticAvailable = false
        if let queryVector = try? await embedder.embed(term), !queryVector.isEmpty {
            semanticAvailable = true
            // Best-effort index build; a failure (or cancellation) simply leaves
            // whatever embeddings are already cached in play.
            try? await ensureChunkEmbeddings(onProgress: onProgress)
            semanticMatches = rankSemanticMatches(for: queryVector)
            if semanticMatches.isEmpty && embeddings.isEmpty { semanticAvailable = false }
        }
        return DeepSearchResult(
            query: term, groups: groups, totalOccurrences: total,
            semanticMatches: semanticMatches, semanticAvailable: semanticAvailable
        )
    }

    /// Maximum number of occurrences listed per document (the count stays exact).
    static let deepSearchOccurrenceCap = 50
    /// Minimum cosine similarity for a chunk to be reported as semantically similar.
    static let semanticSimilarityThreshold = 0.5
    /// Maximum number of semantic matches returned.
    static let semanticMatchLimit = 10

    // MARK: Literal pass

    private func literalOccurrences(of term: String) -> [DocumentOccurrences] {
        var groups: [DocumentOccurrences] = []
        for d in documents {
            let ranges = Self.allRanges(of: term, in: d.text)
            guard !ranges.isEmpty else { continue }
            let pages = Self.pageRanges(of: d.text)
            let occurrences = ranges.prefix(Self.deepSearchOccurrenceCap).map { range in
                let citation = Citation(
                    document: d.name,
                    page: Self.page(for: range.location, in: pages),
                    location: range.location,
                    length: range.length,
                    documentID: d.id
                )
                return DeepSearchOccurrence(citation: citation, snippet: Self.snippet(around: range, in: d.text))
            }
            groups.append(DocumentOccurrences(
                documentID: d.id, documentName: d.name,
                count: ranges.count, occurrences: occurrences
            ))
        }
        return groups.sorted { $0.count != $1.count ? $0.count > $1.count : $0.documentName < $1.documentName }
    }

    /// All case-insensitive, non-overlapping ranges of `term` in `text`.
    static func allRanges(of term: String, in text: String) -> [NSRange] {
        guard !term.isEmpty else { return [] }
        let source = text as NSString
        var results: [NSRange] = []
        var start = 0
        while start < source.length {
            let found = source.range(
                of: term, options: .caseInsensitive,
                range: NSRange(location: start, length: source.length - start)
            )
            if found.location == NSNotFound || found.length == 0 { break }
            results.append(found)
            start = NSMaxRange(found)
        }
        return results
    }

    /// A display snippet around a match: ~80 characters of context on each side,
    /// trimmed to whitespace and marked with ellipses when cut.
    static func snippet(around range: NSRange, in text: String, context: Int = 80) -> String {
        let source = text as NSString
        let start = max(0, range.location - context)
        let end = min(source.length, NSMaxRange(range) + context)
        guard end > start else { return "" }
        let body = source.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = start > 0 ? "…" : ""
        let suffix = end < source.length ? "…" : ""
        return prefix + body + suffix
    }

    // MARK: Semantic pass

    /// Ranks cached chunk embeddings against the query vector by cosine
    /// similarity (vectors are normalized, so a dot product suffices) and
    /// returns the top matches above the threshold as passages with citations.
    private func rankSemanticMatches(for queryVector: [Float]) -> [Passage] {
        guard !embeddings.isEmpty else { return [] }
        if index.isEmpty { return [] }
        var scored: [(Passage, Double)] = []
        for c in index {
            guard let vector = embeddings[c.id], vector.count == queryVector.count else { continue }
            let similarity = Double(Self.dot(queryVector, vector))
            guard similarity >= Self.semanticSimilarityThreshold else { continue }
            scored.append((makePassage(for: c, score: similarity), similarity))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(Self.semanticMatchLimit).map { $0.0 }
    }

    /// Builds a display passage for an index chunk, preferring the OKF concept
    /// body (bounded, navigation-ready) and falling back to the raw chunk text.
    /// Shared by deep search's semantic section and hybrid retrieval.
    func makePassage(for c: IndexedChunk, score: Double) -> Passage {
        let bundle = self.bundle()
        let conceptID = bundle.conceptID(for: c)
        let concept = try? bundle.readConcept(id: conceptID)
        let text = concept?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? c.text
        let citation = Citation(
            document: c.document, page: c.page, location: c.location,
            length: text.utf16.count, conceptID: conceptID, documentID: c.documentID
        )
        return Passage(text: text, citation: citation, score: score)
    }

    /// ``makePassage(for:score:)`` without the disk read. A section concept's
    /// body is exactly the trimmed chunk text `OKFBundle.write` persisted, so
    /// retrieval's hot path can build the same passage and citation in memory;
    /// the concept id is a pure function of the chunk. Used by hybrid retrieval,
    /// where the old per-chunk read meant one file open per indexed chunk on
    /// every question.
    func makePassageInMemory(for c: IndexedChunk, score: Double) -> Passage {
        let text = c.text
        let citation = Citation(
            document: c.document, page: c.page, location: c.location,
            length: text.utf16.count, conceptID: bundle().conceptID(for: c), documentID: c.documentID
        )
        return Passage(text: text, citation: citation, score: score)
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    /// Computes embeddings for every indexed chunk that doesn't have one yet,
    /// prunes entries whose chunk disappeared (document deleted/reimported), and
    /// persists the cache. Progress is reported on the caller's closure; partial
    /// work is always persisted, even on cancellation or failure.
    func ensureChunkEmbeddings(onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        if index.isEmpty {
            for d in documents { try? await rebuildIndex(for: d) }
        }
        let live = Set(index.map { $0.id })
        if embeddings.count != embeddings.filter({ live.contains($0.key) }).count {
            embeddings = embeddings.filter { live.contains($0.key) }
            try? persistEmbeddings()
        }
        let missing = index.filter { embeddings[$0.id] == nil }
        guard !missing.isEmpty else { return }

        var computed = 0
        defer { if computed > 0 { try? persistEmbeddings() } }
        onProgress?(0, missing.count)
        for chunk in missing {
            try Task.checkCancellation()
            let vector = try await embedder.embed(chunk.text)
            // An embedder that can't produce vectors (e.g. HashEmbedder) aborts
            // the build; the caller treats that as "semantic unavailable".
            guard !vector.isEmpty else { return }
            embeddings[chunk.id] = vector
            computed += 1
            onProgress?(computed, missing.count)
            // Persist periodically so a crash or force-quit mid-build (e.g. a
            // jetsam kill under memory pressure on device) doesn't discard all
            // completed work — the next run resumes from the cache.
            if computed % 10 == 0 { try? persistEmbeddings() }
        }
    }

    // MARK: Import-time background embedding

    /// Library-wide warm-up, meant to run once at launch: builds the chunk index
    /// if needed, then starts background embedding for every document, so the
    /// semantic cache is warm before the first Ask or Deep Search — including
    /// libraries ingested before import-time embedding existed, sessions where a
    /// background job was interrupted, and caches invalidated by format changes.
    /// Returns immediately; the per-document jobs are fire-and-forget and no-ops
    /// when everything is already cached or the embedder can't produce vectors.
    public func warmEmbeddingCache() async {
        guard !documents.isEmpty else { return }
        // One full rebuild (persist regenerates the whole index with stable,
        // content-derived chunk ids) instead of a per-document rebuild storm.
        if index.isEmpty { try? persist() }
        for d in documents { startBackgroundEmbedding(for: d.id) }
    }

    /// Embeds only the chunks of one document that lack vectors, with the same
    /// memory-safe behavior as the whole-library build (incremental persist
    /// every 10 chunks, cancellation-safe, empty-vector abort). Also prunes
    /// vectors whose chunks vanished from the index (e.g. a note re-save
    /// regenerated its chunk ids). Called by `startBackgroundEmbedding` after
    /// ingestion and directly by tests.
    func embedChunks(for documentID: UUID) async throws {
        let live = Set(index.map { $0.id })
        if embeddings.contains(where: { !live.contains($0.key) }) {
            embeddings = embeddings.filter { live.contains($0.key) }
            try? persistEmbeddings()
        }
        let targets = index.filter { $0.documentID == documentID && embeddings[$0.id] == nil }
        guard !targets.isEmpty else { return }
        var computed = 0
        defer { if computed > 0 { try? persistEmbeddings() } }
        for chunk in targets {
            try Task.checkCancellation()
            let vector = try await embedder.embed(chunk.text)
            guard !vector.isEmpty else { return }
            embeddings[chunk.id] = vector
            computed += 1
            if computed % 10 == 0 { try? persistEmbeddings() }
        }
    }

    /// Fire-and-forget background embedding for a freshly ingested document, so
    /// the semantic index is warm before any Ask or Deep Search needs it. Guarded
    /// by an in-flight set so repeat triggers don't duplicate work; failures are
    /// silent — Deep Search's lazy `ensureChunkEmbeddings` remains the backfill.
    func startBackgroundEmbedding(for documentID: UUID) {
        guard !embeddingInFlight.contains(documentID) else { return }
        embeddingInFlight.insert(documentID)
        Task {
            do { try await embedChunks(for: documentID) } catch { /* backfill covers it */ }
            embeddingInFlight.remove(documentID)
        }
    }

    /// Drops cached vectors for deleted chunks and persists immediately, so a
    /// delete shrinks the cache without waiting for the next deep search.
    func pruneEmbeddings(chunkIDs: [UUID]) {
        guard !chunkIDs.isEmpty else { return }
        let doomed = Set(chunkIDs)
        let before = embeddings.count
        embeddings = embeddings.filter { !doomed.contains($0.key) }
        if embeddings.count != before { try? persistEmbeddings() }
    }

    // MARK: Embedding cache persistence

    func persistEmbeddings() throws {
        let keyed = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.key.uuidString, $0.value) })
        try FileManager.default.createDirectory(
            at: embeddingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(keyed).write(to: embeddingsURL, options: .atomic)
    }
}
