import Foundation
import OSLog
import Combine

/// A single saved Test Mode run: the question asked, the raw answer, the model and
/// parameter snapshot used, and the native MLX metrics captured for that run.
///
/// Stored only in Test Mode's own ``TestHistoryStore`` (a separate `history.json`),
/// never in the normal document catalog, so the two modes stay fully isolated.
struct TestRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let model: String
    let contextWindowTokens: Int
    let maxOutputTokens: Int
    let temperature: Float
    let question: String
    let answer: String
    let metrics: GenerationMetrics?
    /// Whether thinking/reasoning was enabled for this run. Optional so history
    /// saved before the toggle existed still decodes (treated as off).
    let enableThinking: Bool?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        model: String,
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        temperature: Float,
        question: String,
        answer: String,
        metrics: GenerationMetrics?,
        enableThinking: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.model = model
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.question = question
        self.answer = answer
        self.metrics = metrics
        self.enableThinking = enableThinking
    }

    /// A short one-line summary used in the history list.
    var parameterSummary: String {
        String(format: "ctx %d · max %d · T %.2f", contextWindowTokens, maxOutputTokens, temperature)
            + ((enableThinking ?? false) ? " · think on" : " · think off")
    }
}

/// Persists Test Mode runs to `Application Support/DocumentAssistant/TestMode/history.json`.
///
/// This is deliberately a distinct file from the normal-mode `catalog.json` so test
/// records never mix with imported documents or notes. Records are kept newest-first
/// and capped so the file cannot grow without bound.
@MainActor
final class TestHistoryStore: ObservableObject {
    @Published private(set) var records: [TestRecord] = []

    /// Soft cap on stored runs; older entries are trimmed on append.
    private let maxRecords = 200
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.sc.boardiq", category: "TestMode")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support
                .appendingPathComponent("DocumentAssistant", isDirectory: true)
                .appendingPathComponent("TestMode", isDirectory: true)
                .appendingPathComponent("history.json")
        }
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([TestRecord].self, from: data)
        } catch {
            logger.error("Test history decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Test history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Inserts a new run at the front of the history and trims to ``maxRecords``.
    func append(_ record: TestRecord) {
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { records.indices.contains($0) ? records[$0].id : nil }
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func delete(_ record: TestRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }
}
