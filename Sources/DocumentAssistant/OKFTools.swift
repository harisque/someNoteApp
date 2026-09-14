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
/// the deterministic tool layer is doing (searching, reading, composing, generating).
public enum ToolStage: Sendable, Hashable {
    case searching(query: String)
    case readingSources(count: Int)
    case composingPrompt(excerpts: Int)
    case generating
    case finished
}

/// Streamed by `answer(_:mode:)`: stage updates for tool progress, the citations
/// actually packed into the prompt (emitted once), followed by the model's tokens.
public enum AnswerEvent: Sendable {
    case stage(ToolStage)
    case citations([Citation])
    case token(String)
}

/// Namespace for tool-layer limits.
public enum OKFToolLimits {
    /// Upper character bound for a single concept body passed toward the model.
    public static let conceptBody = 4000
    /// Approximate characters per token used to convert a token budget into a
    /// character budget for prompt packing. Conservative (real prose is ~4) so a
    /// packed prompt stays under the model adapter's hard `contextWindowTokens` guard.
    public static let charactersPerToken = 3.5
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
        let capped = max(0, limit)
        guard capped > 0 else { return [] }
        let passages = await retrieve(query, limit: capped * 8)
        var hits: [ConceptHit] = []
        for passage in passages {
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
        return hits
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
        let characterBudget = promptCharacterBudget()
        let candidates = await searchConcepts(
            query: q, filters: filters, limit: Self.candidateLimit(forCharacterBudget: characterBudget)
        )
        let (prompt, included) = Self.makePrompt(
            question: q, mode: mode, hits: candidates, characterBudget: characterBudget
        )
        continuation.yield(.citations(included.map { $0.citation }))
        continuation.yield(.stage(.readingSources(count: included.count)))
        continuation.yield(.stage(.composingPrompt(excerpts: included.count)))
        continuation.yield(.stage(.generating))
        for try await token in model.stream(prompt: prompt) {
            try Task.checkCancellation()
            continuation.yield(.token(token))
        }
        continuation.yield(.stage(.finished))
    }

    /// Converts the token budget into an approximate character budget for packing,
    /// reserving room for the answer and the prompt scaffolding.
    private func promptCharacterBudget() -> Int {
        let packingTokens = max(0, promptTokenBudget - reservedAnswerTokens - OKFToolLimits.promptOverheadTokens)
        return Int(Double(packingTokens) * OKFToolLimits.charactersPerToken)
    }

    /// Fetches enough candidates to plausibly fill the character budget, bounded so
    /// retrieval work stays predictable.
    static func candidateLimit(forCharacterBudget budget: Int) -> Int {
        max(6, min(OKFToolLimits.maxCandidateExcerpts, budget / 500 + 6))
    }

    /// Packs complete excerpts, in score order, until `characterBudget` is reached.
    /// Returns the composed prompt alongside the excerpts actually included so the
    /// citations match the evidence the model sees.
    static func makePrompt(
        question: String,
        mode: PromptMode,
        hits: [ConceptHit],
        characterBudget: Int
    ) -> (prompt: String, included: [ConceptHit]) {
        let header = "Mode: \(mode.rawValue)\nUse only these source excerpts; cite sources and say when evidence is missing.\n"
        let questionBlock = "\nQuestion: \(question)"
        var remaining = max(0, characterBudget - header.count - questionBlock.count)
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
        let prompt = "\(header)\(blocks.joined(separator: "\n\n"))\(questionBlock)"
        return (prompt, included)
    }

    private static func excerptBlock(index: Int, hit: ConceptHit) -> String {
        let citation = hit.citation
        let source = "\(citation.document)\(citation.page.map { ", page \($0)" } ?? "") offset \(citation.location ?? 0)"
        return "[Excerpt \(index + 1)]\nOKF concept: \(citation.conceptID ?? "unknown")\nSource: \(source)\n\(hit.body)"
    }

    private static func truncatedExcerptBlock(index: Int, hit: ConceptHit, budget: Int) -> String {
        let citation = hit.citation
        let source = "\(citation.document)\(citation.page.map { ", page \($0)" } ?? "") offset \(citation.location ?? 0)"
        let prefix = "[Excerpt \(index + 1)]\nOKF concept: \(citation.conceptID ?? "unknown")\nSource: \(source)\n"
        let bodyBudget = max(0, budget - prefix.count)
        return prefix + String(hit.body.prefix(bodyBudget))
    }
}
