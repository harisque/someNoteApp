import Foundation

/// Lightweight, Codable-safe descriptor for an imported document.
public struct DocumentSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let indexedAt: Date?
    public init(id: UUID, name: String, indexedAt: Date?) {
        self.id = id
        self.name = name
        self.indexedAt = indexedAt
    }
}

/// Deterministic, optional constraints applied to `searchConcepts`.
/// A nil field means "no constraint"; a `type` other than "Document Section"
/// yields nothing because retrieval currently returns section concepts only.
public struct ConceptFilters: Hashable, Sendable {
    public var documentID: UUID?
    /// Scope retrieval to any of these entity ids. An id may name either a document
    /// or a Data Link (a data-link concept is matched by the link UUID embedded in its
    /// `datalinks/<uuid>` concept id). `nil` or an empty set means no constraint.
    public var documentIDs: Set<UUID>?
    public var page: Int?
    public var type: String?
    public init(documentID: UUID? = nil, documentIDs: Set<UUID>? = nil, page: Int? = nil, type: String? = nil) {
        self.documentID = documentID
        self.documentIDs = documentIDs
        self.page = page
        self.type = type
    }
    public static let none = ConceptFilters()
}

/// A single bounded search result paired with its navigation-ready citation.
/// `body` is capped for prompt packing; `citation` keeps the full source range
/// so navigation can highlight the exact passage.
public struct ConceptHit: Hashable, Sendable, Identifiable {
    public let conceptID: String
    public let citation: Citation
    public let body: String
    public let score: Double
    public var id: String { conceptID }
    public init(conceptID: String, citation: Citation, body: String, score: Double) {
        self.conceptID = conceptID
        self.citation = citation
        self.body = body
        self.score = score
    }
}

/// Coarse progress stages emitted by `answer(_:mode:)` so the UI can show what
/// the deterministic tool layer is doing (searching, ranking, reading, composing,
/// generating).
public enum ToolStage: Sendable, Hashable {
    case searching(query: String)
    /// Hybrid ranking step, emitted between `searching` and `readingSources`:
    /// how many candidates the keyword and semantic passes produced, how many
    /// survived fusion, and whether the semantic side was available at all.
    /// Without it the embedding/ranking work looked like a stall in the UI.
    case ranking(lexical: Int, semantic: Int, fused: Int, semanticAvailable: Bool)
    case readingSources(count: Int)
    case composingPrompt(excerpts: Int)
    case generating
    case finished
}

/// Streamed by `answer(_:mode:)`: stage updates for tool progress, the citations
/// actually packed into the prompt (emitted once), the model's tokens, then the
/// subset of those citations the answer really used.
public enum AnswerEvent: Sendable {
    case stage(ToolStage)
    case citations([Citation])
    /// The packed excerpts the answer cited, emitted after the token stream so
    /// the UI lists only the sources that back the answer instead of every
    /// excerpt that happened to fit in the prompt.
    case usedCitations([Citation])
    case token(String)
}

/// Namespace for tool-layer limits.
public enum OKFToolLimits {
    /// Upper character bound for a single concept body passed toward the model.
    public static let conceptBody = 4000
    /// Upper character bound for one *packed* excerpt. Lower than `conceptBody`
    /// so the config-derived prompt budget buys several distinct passages rather
    /// than a couple of oversized ones.
    public static let maxExcerptCharacters = 1600
    /// Approximate characters per token, used only when no ``PromptTokenCounter``
    /// is injected (or it fails). Deliberately conservative: 3.5 assumed clean
    /// English prose, but dense numeric/symbol content and non-ASCII text can
    /// tokenize below 3 chars/token, which overflowed the adapter's hard
    /// `contextWindowTokens` guard. With a counter injected the app packs against
    /// real token counts and this ratio only sizes the fallback.
    public static let charactersPerToken = 2.5
    /// Tokens reserved for prompt scaffolding (mode line + instructions + question label).
    public static let promptOverheadTokens = 64
    /// Hard bound on how many candidate excerpts are fetched before budget packing.
    public static let maxCandidateExcerpts = 64
}

/// Typed, deterministic OKF tool layer. Every operation is a local read over the
/// OKF bundle and the in-memory index; there is no network, shell, or arbitrary
/// file access. Concept ids are validated by `OKFBundle.readConcept`, which
/// rejects path traversal. Bodies handed toward the model are bounded so prompts
/// stay within the adapter's token guard.
@available(macOS 10.15, iOS 13.0, *)
extension DocumentAssistant {
    /// Lists imported documents as lightweight summaries.
    public func listDocuments() async -> [DocumentSummary] {
        documents.map { DocumentSummary(id: $0.id, name: $0.name, indexedAt: $0.indexedAt) }
    }

    /// Keyword search over document sections with optional deterministic filters.
    /// Over-fetches before filtering so the requested `limit` can still be met.
    public func searchConcepts(
        query: String,
        filters: ConceptFilters = .none,
        limit: Int = 6,
        maxBodyCharacters: Int = OKFToolLimits.conceptBody
    ) async -> [ConceptHit] {
        await searchConceptsDetailed(
            query: query, filters: filters, limit: limit, maxBodyCharacters: maxBodyCharacters
        ).hits
    }

    /// `searchConcepts` plus the retrieval diagnostics Ask publishes as tool
    /// status. An id-scope filter is pushed into retrieval itself, so both passes
    /// rank only in-scope candidates; the remaining filters are applied after.
    func searchConceptsDetailed(
        query: String,
        filters: ConceptFilters = .none,
        limit: Int = 6,
        maxBodyCharacters: Int = OKFToolLimits.conceptBody
    ) async -> (hits: [ConceptHit], stats: RetrievalStats) {
        let capped = max(0, limit)
        guard capped > 0 else { return ([], .empty) }
        let scope = Self.retrievalScope(for: filters)
        let found = await retrieveDetailed(query, limit: min(128, capped * 4), scope: scope)
        var hits: [ConceptHit] = []
        for passage in found.passages {
            let citation = passage.citation
            if let wanted = filters.documentID, citation.documentID != wanted { continue }
            if let wantedIDs = filters.documentIDs, !wantedIDs.isEmpty {
                // A scope id names either a document or a Data Link. Data-link concepts
                // carry `documentID == nil`, so match them by the link UUID embedded in
                // their `datalinks/<uuid>` concept id.
                let ownerID = citation.documentID ?? Self.dataLinkID(fromConceptID: citation.conceptID)
                guard let ownerID, wantedIDs.contains(ownerID) else { continue }
            }
            if let wanted = filters.page, citation.page != wanted { continue }
            if let wanted = filters.type, wanted != "Document Section" { continue }
            hits.append(ConceptHit(
                conceptID: citation.conceptID ?? "",
                citation: citation,
                body: String(passage.text.prefix(max(0, maxBodyCharacters))),
                score: passage.score
            ))
            if hits.count >= capped { break }
        }
        return (hits, found.stats)
    }

    /// The entity-id scope to push into retrieval, if the filters name one. A
    /// single `documentID` counts as a one-element scope; `page`/`type` filters
    /// stay post-retrieval because they aren't entity ids.
    static func retrievalScope(for filters: ConceptFilters) -> Set<UUID>? {
        if let ids = filters.documentIDs, !ids.isEmpty { return ids }
        if let id = filters.documentID { return [id] }
        return nil
    }

    /// Extracts a Data Link's UUID from an OKF concept id of the form `datalinks/<uuid>`,
    /// mirroring the app's citation routing so a scope id can name a data link.
    static func dataLinkID(fromConceptID conceptID: String?) -> UUID? {
        guard let conceptID, conceptID.hasPrefix("datalinks/") else { return nil }
        return UUID(uuidString: String(conceptID.dropFirst("datalinks/".count)))
    }

    /// Reads one OKF concept by id, bounding its body length.
    public func readConcept(
        id: String,
        maxBodyCharacters: Int = OKFToolLimits.conceptBody
    ) async throws -> OKFConcept {
        let concept = try bundle().readConcept(id: id)
        let bound = max(0, maxBodyCharacters)
        guard concept.body.count > bound else { return concept }
        return OKFConcept(
            id: concept.id, type: concept.type, title: concept.title,
            metadata: concept.metadata, body: String(concept.body.prefix(bound)),
            fileURL: concept.fileURL
        )
    }

    /// Builds a navigation-ready citation from a concept's stored metadata and body.
    public func citeConcept(id: String) async throws -> Citation {
        let concept = try bundle().readConcept(id: id)
        let metadata = concept.metadata
        let documentID = metadata["document_id"].flatMap { UUID(uuidString: $0) }
        let location = metadata["location"].flatMap { Int($0) }
        let page = metadata["page"].flatMap { Int($0) }
        let body = concept.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let documentID, let match = documents.first(where: { $0.id == documentID }) {
            name = match.name
        } else {
            name = metadata["title"] ?? concept.title
        }
        return Citation(
            document: name, page: page, location: location,
            length: body.utf16.count, conceptID: id, documentID: documentID
        )
    }

    /// Deterministic answer flow: search once, publish the citations actually used,
    /// build a bounded prompt from those concepts, then stream the model's tokens.
    /// `scope` optionally restricts retrieval to a set of ids naming documents and/or
    /// Data Links; `nil` or an empty set searches across everything.
    public func answer(_ q: String, mode: PromptMode, scope: Set<UUID>? = nil) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runAnswer(q, mode: mode, scope: scope, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Streams raw model tokens for a caller-supplied prompt, bypassing corpus
    /// retrieval. Used by the app's fact-check flow, which builds its own prompt
    /// from web evidence. The model stays actor-isolated; only the token stream
    /// (a Sendable value) crosses the actor boundary.
    public func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        model.stream(prompt: prompt)
    }

    private func runAnswer(
        _ q: String,
        mode: PromptMode,
        scope: Set<UUID>?,
        continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.stage(.searching(query: q)))
        let filters = (scope?.isEmpty == false) ? ConceptFilters(documentIDs: scope) : .none
        // Derive the excerpt budget from the configured context window so the packed
        // prompt grows and shrinks with it instead of a fixed 6-excerpt cap.
        let packingTokens = promptPackingTokens()
        let characterBudget = Int(Double(packingTokens) * OKFToolLimits.charactersPerToken)
        let found = await searchConceptsDetailed(
            query: q, filters: filters, limit: Self.candidateLimit(forCharacterBudget: characterBudget)
        )
        let stats = found.stats
        continuation.yield(.stage(.ranking(
            lexical: stats.lexical, semantic: stats.semantic,
            fused: stats.fused, semanticAvailable: stats.semanticAvailable
        )))
        // Collapse overlapping windows of the same document before packing, so the
        // budget buys distinct evidence and the source row has no near-duplicates.
        let candidates = Self.mergeAdjacent(found.hits)
        // Pack against the model's real tokenizer when one is injected: the
        // character estimate alone under-counts dense numeric/symbol content and
        // tripped the adapter's hard context-window guard on every question.
        let (prompt, included) = await Self.makePrompt(
            question: q, mode: mode, hits: candidates,
            packingTokens: packingTokens, characterBudget: characterBudget, counter: tokenCounter
        )
        continuation.yield(.citations(included.map { $0.citation }))
        continuation.yield(.stage(.readingSources(count: included.count)))
        continuation.yield(.stage(.composingPrompt(excerpts: included.count)))
        continuation.yield(.stage(.generating))
        var answer = ""
        for try await token in model.stream(prompt: prompt) {
            try Task.checkCancellation()
            answer += token
            continuation.yield(.token(token))
        }
        continuation.yield(.usedCitations(Self.usedCitations(in: answer, from: included)))
        continuation.yield(.stage(.finished))
    }

    /// Tokens available for the composed prompt after reserving the answer and a
    /// margin for the chat template/scaffolding.
    func promptPackingTokens() -> Int {
        max(0, promptTokenBudget - reservedAnswerTokens - OKFToolLimits.promptOverheadTokens)
    }

    /// Fetches enough candidates to plausibly fill the character budget, bounded so
    /// retrieval work stays predictable.
    static func candidateLimit(forCharacterBudget budget: Int) -> Int {
        max(6, min(OKFToolLimits.maxCandidateExcerpts, budget / 500 + 6))
    }

    /// Packs complete excerpts, in score order, until `characterBudget` is reached.
    /// Returns the composed prompt alongside the excerpts actually included so the
    /// citations match the evidence the model sees. The task framing and the
    /// question lead the prompt (evidence trails) so a long excerpt list can't push
    /// the instructions out of the model's attention, and each excerpt body is
    /// capped at `OKFToolLimits.maxExcerptCharacters`.
    static func makePrompt(
        question: String,
        mode: PromptMode,
        hits: [ConceptHit],
        characterBudget: Int
    ) -> (prompt: String, included: [ConceptHit]) {
        let header = promptHeader(question: question, mode: mode)
        let footer = promptFooter()
        var remaining = max(0, characterBudget - header.count - footer.count)
        var blocks: [String] = []
        var included: [ConceptHit] = []
        for (index, hit) in hits.enumerated() {
            let block = excerptBlock(index: index, hit: hit)
            let separator = blocks.isEmpty ? 0 : 2  // "\n\n" between excerpts
            let cost = block.count + separator
            if cost <= remaining {
                blocks.append(block)
                included.append(hit)
                remaining -= cost
            } else if included.isEmpty {
                // Always include at least one excerpt, truncating its body to fit so a
                // single oversized section can't cause the whole request to be refused.
                blocks.append(truncatedExcerptBlock(index: 0, hit: hit, budget: remaining))
                included.append(hit)
                break
            } else {
                break  // stop at the first excerpt that doesn't fit; pack complete sections
            }
        }
        let prompt = header + blocks.joined(separator: "\n\n") + footer
        return (prompt, included)
    }

    /// Token-accurate packing: measures the header and every excerpt block with
    /// the model's real tokenizer (`counter`) and packs in score order until
    /// `packingTokens` is spent, so the composed prompt provably fits the
    /// adapter's context-window guard instead of trusting a characters-per-token
    /// estimate. Falls back to the character-budget packer when no counter is
    /// injected or the tokenizer fails, so Ask still works (just more
    /// conservatively) without one.
    static func makePrompt(
        question: String,
        mode: PromptMode,
        hits: [ConceptHit],
        packingTokens: Int,
        characterBudget: Int,
        counter: PromptTokenCounter?
    ) async -> (prompt: String, included: [ConceptHit]) {
        let charFallback = {
            makePrompt(question: question, mode: mode, hits: hits, characterBudget: characterBudget)
        }
        guard let counter else { return charFallback() }
        let header = promptHeader(question: question, mode: mode)
        let footer = promptFooter()
        guard let headerTokens = await counter.tokenCount(header),
              let footerTokens = await counter.tokenCount(footer) else { return charFallback() }
        var remaining = max(0, packingTokens - headerTokens - footerTokens)
        var blocks: [String] = []
        var included: [ConceptHit] = []
        for (index, hit) in hits.enumerated() {
            let block = excerptBlock(index: index, hit: hit)
            guard let cost = await counter.tokenCount(block) else { break }
            let separator = blocks.isEmpty ? 0 : 1  // "\n\n" between excerpts
            if cost + separator <= remaining {
                blocks.append(block)
                included.append(hit)
                remaining -= cost + separator
            } else if included.isEmpty {
                // Same "never refuse over one oversized section" rule as the
                // character packer: shrink the block until it fits.
                if let fitted = await fitToTokens(block, tokens: remaining, cost: cost, counter: counter) {
                    blocks.append(fitted)
                    included.append(hit)
                }
                break
            } else {
                break  // stop at the first excerpt that doesn't fit
            }
        }
        return (header + blocks.joined(separator: "\n\n") + footer, included)
    }

    /// Shrinks `block` to a character prefix that measures at most `tokens`.
    /// Starts from the measured density (`cost` tokens for the full block) and
    /// verifies, shrinking geometrically until it fits; returns nil only if even
    /// a one-character prefix is over budget.
    private static func fitToTokens(
        _ block: String, tokens: Int, cost: Int, counter: PromptTokenCounter
    ) async -> String? {
        guard tokens > 0 else { return nil }
        let estimate = max(1, block.count * tokens / max(1, cost))
        var candidate = String(block.prefix(min(block.count, estimate)))
        while !candidate.isEmpty {
            if let count = await counter.tokenCount(candidate), count <= tokens { return candidate }
            candidate = String(candidate.prefix(candidate.count * 9 / 10))
        }
        return nil
    }

    /// Task framing plus the question, ahead of the evidence. The wording is
    /// deliberate: the previous one-liner ("use only these excerpts; say when
    /// evidence is missing") made the model read questions literally and refuse
    /// answers that were present but worded differently, so it now requires
    /// inference across excerpts and only allows "missing" when nothing is
    /// relevant. The `[n]` marker requirement is what lets the UI show the
    /// sources the answer actually used (see `ExcerptReferenceParser`).
    /// The output-language rule is stated here and repeated by ``promptFooter()``
    /// because one mention is not enough: a long run of non-English excerpts
    /// drags the answer into the document's language.
    static func promptHeader(question: String, mode: PromptMode) -> String {
        let rules = [
            "- Excerpts rarely reuse the question's wording. Infer, combine, and summarize across them.",
            "- If any excerpt addresses the question, answer it. Say that evidence is missing only when no excerpt is relevant at all.",
            "- Be specific and concise; do not quote whole excerpts.",
            "- Mark each statement with the supporting excerpt numbers, like [1] or [2][5].",
            "- Always answer in English, whatever language the question or the excerpts are written in."
        ]
        return "Mode: \(mode.rawValue)\nYou answer from the source excerpts below.\n"
            + rules.joined(separator: "\n")
            + "\n\nQuestion: \(question)\n\n"
    }

    /// Closing directive appended after the evidence, so it is the last thing the
    /// model reads before generating. Recency matters twice here: a prompt ending
    /// in non-English excerpts otherwise tends to produce a non-English answer
    /// (the source language wins over an instruction buried thousands of tokens
    /// earlier), and repeating the `[n]` rule lifts citation-marker compliance,
    /// which is what ``usedCitations`` and the source chips depend on.
    static func promptFooter() -> String {
        "\n\nWrite the answer in English, whatever language the excerpts above use. Mark each statement with its supporting excerpt numbers, like [1]."
    }

    /// Collapses hits drawn from overlapping or adjacent chunks of the same
    /// document. Chunking deliberately overlaps consecutive windows (~120
    /// characters), so without this the same sentence is packed twice: the
    /// excerpt list looks padded, the budget is wasted, and the source row shows
    /// near-duplicates. Merged excerpts keep the best score, cite from the
    /// earliest offset, and span the combined range. Hits without a source range
    /// (Data Links) never merge. The result is re-sorted by score.
    static func mergeAdjacent(_ hits: [ConceptHit], maxGap: Int = 200) -> [ConceptHit] {
        guard hits.count > 1 else { return hits }
        struct Group {
            var body: String
            var start: Int
            var end: Int
            var page: Int?
            var conceptID: String?
            var documentID: UUID?
            var document: String
            var score: Double
        }
        /// Drops the first `count` UTF-16 units, matching how citation offsets are measured.
        func droppingFirst(_ text: String, _ count: Int) -> String {
            guard count > 0 else { return text }
            let ns = text as NSString
            return count < ns.length ? ns.substring(from: count) : ""
        }
        /// Drops the last `count` UTF-16 units.
        func droppingLast(_ text: String, _ count: Int) -> String {
            guard count > 0 else { return text }
            let ns = text as NSString
            return count < ns.length ? ns.substring(to: ns.length - count) : ""
        }
        var groups: [Group] = []
        var standalone: [ConceptHit] = []
        for hit in hits {
            guard hit.citation.documentID != nil, let location = hit.citation.location else {
                standalone.append(hit)
                continue
            }
            let end = location + (hit.citation.length ?? hit.body.utf16.count)
            guard let i = groups.firstIndex(where: {
                $0.documentID == hit.citation.documentID
                    && location <= $0.end + maxGap
                    && $0.start <= end + maxGap
            }) else {
                groups.append(Group(
                    body: hit.body, start: location, end: end, page: hit.citation.page,
                    conceptID: hit.citation.conceptID, documentID: hit.citation.documentID,
                    document: hit.citation.document, score: hit.score
                ))
                continue
            }
            var group = groups[i]
            if location >= group.start {
                // New body extends to the right: append only what isn't already covered.
                let overlap = max(0, min(group.end - location, hit.body.utf16.count))
                let tail = droppingFirst(hit.body, overlap)
                let joiner = (overlap > 0 || location == group.end) ? "" : " … "
                group.body += tail.isEmpty ? "" : joiner + tail
            } else {
                // New body starts earlier: prepend what isn't already covered and
                // re-anchor the citation so navigation lands at the first offset.
                let overlap = max(0, min(end - group.start, hit.body.utf16.count))
                let head = droppingLast(hit.body, overlap)
                let joiner = (overlap > 0 || end == group.start) ? "" : " … "
                group.body = head.isEmpty ? group.body : head + joiner + group.body
                group.start = location
                group.page = hit.citation.page
                group.conceptID = hit.citation.conceptID
            }
            group.end = max(group.end, end)
            group.score = max(group.score, hit.score)
            groups[i] = group
        }
        let merged = groups.map { group in
            ConceptHit(
                conceptID: group.conceptID ?? "",
                citation: Citation(
                    document: group.document, page: group.page, location: group.start,
                    length: group.end - group.start, conceptID: group.conceptID,
                    documentID: group.documentID
                ),
                body: String(group.body.prefix(OKFToolLimits.conceptBody)),
                score: group.score
            )
        }
        return (merged + standalone).sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id
        }
    }

    /// The excerpts the answer actually cited, in prompt order. Falls back to the
    /// first few packed excerpts when the model wrote no recognizable marker, so
    /// the source row is never empty after a grounded answer.
    static func usedCitations(in answer: String, from included: [ConceptHit], fallback: Int = 3) -> [Citation] {
        let numbers = ExcerptReferenceParser.numbers(in: answer)
        let cited = included.enumerated()
            .filter { numbers.contains($0.offset + 1) }
            .map { $0.element.citation }
        guard cited.isEmpty else { return cited }
        return included.prefix(max(0, fallback)).map { $0.citation }
    }

    private static func excerptBlock(index: Int, hit: ConceptHit) -> String {
        let citation = hit.citation
        let source = "\(citation.document)\(citation.page.map { ", page \($0)" } ?? "") offset \(citation.location ?? 0)"
        let body = String(hit.body.prefix(OKFToolLimits.maxExcerptCharacters))
        return "[Excerpt \(index + 1)]\nOKF concept: \(citation.conceptID ?? "unknown")\nSource: \(source)\n\(body)"
    }

    private static func truncatedExcerptBlock(index: Int, hit: ConceptHit, budget: Int) -> String {
        let citation = hit.citation
        let source = "\(citation.document)\(citation.page.map { ", page \($0)" } ?? "") offset \(citation.location ?? 0)"
        let prefix = "[Excerpt \(index + 1)]\nOKF concept: \(citation.conceptID ?? "unknown")\nSource: \(source)\n"
        let bodyBudget = max(0, budget - prefix.count)
        return prefix + String(hit.body.prefix(bodyBudget))
    }
}

/// Reads the excerpt numbers an answer cites. `DocumentAssistant.promptHeader`
/// asks for `[n]` markers, but models also write `[Excerpt n]` and `Excerpt n`,
/// so all three forms count. Numbers are returned raw; mapping them onto the
/// packed excerpts (and ignoring out-of-range values) is the caller's job.
public enum ExcerptReferenceParser {
    private static let patterns = [
        #"\[Excerpt\s*([0-9]{1,3})\]"#,
        #"\[([0-9]{1,3})\]"#,
        #"Excerpt\s+([0-9]{1,3})"#
    ]

    /// Every excerpt number referenced in `answer`, deduplicated.
    public static func numbers(in answer: String) -> Set<Int> {
        guard !answer.isEmpty else { return [] }
        let full = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        var found: Set<Int> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: answer, options: [], range: full) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: answer),
                      let value = Int(answer[range]) else { continue }
                found.insert(value)
            }
        }
        return found
    }
}
