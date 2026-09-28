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

/// Network-free stand-in for `RemoteDataLinkSource` so refresh is testable offline.
private struct StubSource: DataLinkSource {
    let points: [DataPoint]
    var shouldThrow = false
    func fetchDailySeries(symbol: String) async throws -> [DataPoint] {
        if shouldThrow { throw DataLinkSourceError.noData }
        return points
    }
}

@Suite("Data Links")
struct DataLinkTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAssistantDataLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAssistant(_ root: URL) -> DocumentAssistant {
        DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
    }

    /// A day-aligned UTC date so parser/snapshot assertions are deterministic.
    private func day(_ offset: Int, from base: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Date {
        base.addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    // MARK: - Parser

    @Test("Stooq CSV parser reads rows, sorts ascending, skips header/blank/malformed, nils N/D")
    func stooqParser() throws {
        let csv = """
        Date,Open,High,Low,Close,Volume
        2024-01-04,102,107,99,106,1500
        2024-01-02,100,110,95,105,1000
        bad,row
        2024-01-03,105,108,100,102,N/D

        """
        let points = Stooq.parseDailyCSV(csv)
        #expect(points.count == 3)
        #expect(points.map(\.date) == points.map(\.date).sorted())
        #expect(points.first?.close == 105)          // 2024-01-02 after sort
        #expect(points[1].close == 102)              // 2024-01-03
        #expect(points[1].open == 105)
        #expect(points[1].volume == nil)             // "N/D" -> nil
        #expect(points.last?.close == 106)           // 2024-01-04
        #expect(Stooq.parseDailyCSV("").isEmpty)
        #expect(Stooq.parseDailyCSV("Date,Open,High,Low,Close,Volume\n").isEmpty)
        #expect(Stooq.parseDailyCSV("No data").isEmpty)
    }

    @Test("Yahoo chart JSON parser reads parallel arrays, skips null-close rows, sorts ascending")
    func yahooParser() throws {
        let json = """
        {"chart":{"result":[{"timestamp":[1700006400,1700092800,1700179200],
        "indicators":{"quote":[{"open":[100.0,null,102.0],"high":[110.0,108.0,107.0],
        "low":[95.0,100.0,99.0],"close":[105.0,null,106.0],"volume":[1000,1200,1500]}]}}],
        "error":null}}
        """
        let points = Yahoo.parseChartJSON(Data(json.utf8))
        #expect(points.count == 2)                     // middle row has a null close -> skipped
        #expect(points.first?.close == 105)
        #expect(points.first?.volume == 1000)
        #expect(points.last?.close == 106)
        #expect(points.last?.high == 107)
        #expect(points.map(\.date) == points.map(\.date).sorted())

        // An errored chart or a non-JSON body yields no points and never throws.
        let errored = #"{"chart":{"result":null,"error":{"code":"Not Found"}}}"#
        #expect(Yahoo.parseChartJSON(Data(errored.utf8)).isEmpty)
        #expect(Yahoo.parseChartJSON(Data("not json".utf8)).isEmpty)
    }

    @Test("Yahoo parser skips placeholder rows with a zero close, keeping only published sessions")
    func yahooPlaceholderRows() throws {
        // Yahoo briefly publishes a session it has not processed yet as a placeholder:
        // open/high/low/volume are zeroed and close is 0 (or null). A 0.00 close must
        // never reach the stored series or the live figures.
        let json = """
        {"chart":{"result":[{"timestamp":[1700006400,1700092800],
        "indicators":{"quote":[{"open":[100.0,0.0],"high":[110.0,0.0],
        "low":[95.0,0.0],"close":[105.0,0.0],"volume":[1000,0]}]}}],
        "error":null}}
        """
        let points = Yahoo.parseChartJSON(Data(json.utf8))
        #expect(points.count == 1)                    // zero-close placeholder -> skipped
        #expect(points.first?.close == 105)
    }

    // MARK: - Seeding

    @Test("seedDataLinks is idempotent by symbol (case-insensitive) and updates changed fields")
    func seedIdempotency() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        let descriptor = DataLinkDescriptor(
            name: "Standard Chartered", symbol: "STAN.UK", sourceID: "stooq", scopeDescription: "Daily EOD."
        )
        try await assistant.seedDataLinks([descriptor])
        let firstID = try #require((await assistant.listDataLinks()).first?.id)
        #expect((await assistant.listDataLinks()).count == 1)

        // Re-seeding the same symbol adds nothing and keeps the stable id.
        try await assistant.seedDataLinks([descriptor])
        #expect((await assistant.listDataLinks()).count == 1)
        #expect((await assistant.listDataLinks()).first?.id == firstID)

        // A differently-cased symbol matches the same link and updates its fields.
        let updated = DataLinkDescriptor(
            name: "Standard Chartered PLC", symbol: "stan.uk", sourceID: "stooq", scopeDescription: "Updated scope."
        )
        try await assistant.seedDataLinks([updated])
        let links = await assistant.listDataLinks()
        #expect(links.count == 1)
        #expect(links.first?.id == firstID)
        #expect(links.first?.name == "Standard Chartered PLC")
        #expect(links.first?.scopeDescription == "Updated scope.")
    }

    // MARK: - Snapshots

    @Test("storeSnapshot bounds to the most recent points and stamps lastRefreshedAt")
    func storeSnapshotBounds() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([DataLinkDescriptor(name: "X", symbol: "X.UK")])
        let id = try #require((await assistant.listDataLinks()).first?.id)

        let total = DataLinkLimits.maxSnapshotPoints + 50
        let points = (0..<total).map { DataPoint(date: day($0), close: Double($0)) }
        try await assistant.storeSnapshot(linkID: id, points: points)

        let snapshot = try #require(await assistant.snapshot(for: id))
        #expect(snapshot.points.count == DataLinkLimits.maxSnapshotPoints)
        // Bounded to the suffix (most recent), still ascending.
        #expect(snapshot.points.last?.close == Double(total - 1))
        #expect(snapshot.points.first?.close == Double(total - DataLinkLimits.maxSnapshotPoints))
        #expect((await assistant.dataLink(id: id))?.lastRefreshedAt != nil)
    }

    @Test("A refresh returning older-ending data never rolls the series back")
    func refreshNeverRegresses() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([DataLinkDescriptor(name: "M", symbol: "M.UK")])
        let id = try #require((await assistant.listDataLinks()).first?.id)

        // An earlier refresh captured a newer session (e.g. Monday, fetched live yesterday).
        try await assistant.storeSnapshot(linkID: id, points: [
            DataPoint(date: day(0), close: 100),
            DataPoint(date: day(1), close: 105),
            DataPoint(date: day(2), close: 110),   // newest captured session
        ])
        #expect((await assistant.figures(for: id)).latestClose == 110)

        // The source now returns a series ending a day earlier (its newest session is an
        // unpublished placeholder the parser dropped) and corrects an older day.
        try await assistant.storeSnapshot(linkID: id, points: [
            DataPoint(date: day(0), close: 101),   // corrected older value -> incoming wins
            DataPoint(date: day(1), close: 105),
        ])

        let snapshot = try #require(await assistant.snapshot(for: id))
        // The newest captured session (day 2) is preserved: no regression to an older date.
        #expect(snapshot.points.count == 3)
        #expect(snapshot.points.last?.close == 110)
        // The overlapping older day took the freshly fetched (corrected) value.
        #expect(snapshot.points.first?.close == 101)
        #expect((await assistant.figures(for: id)).latestClose == 110)
        #expect((await assistant.figures(for: id)).asOf == day(2))
    }

    @Test("Data links and snapshots persist and reload in a fresh assistant instance")
    func persistenceRoundTrip() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("catalog.json")

        let first = DocumentAssistant(model: EchoModel(), store: store)
        try await first.seedDataLinks([
            DataLinkDescriptor(name: "Persisted", symbol: "P.UK", scopeDescription: "Scope.")
        ])
        let id = try #require((await first.listDataLinks()).first?.id)
        try await first.storeSnapshot(linkID: id, points: [
            DataPoint(date: day(0), close: 10),
            DataPoint(date: day(1), close: 12),
        ])

        let second = DocumentAssistant(model: EchoModel(), store: store)
        let links = await second.listDataLinks()
        #expect(links.count == 1)
        #expect(links.first?.symbol == "P.UK")
        let reloaded = try #require(links.first?.id)
        #expect(reloaded == id)
        #expect((await second.snapshot(for: reloaded))?.points.count == 2)
        let figures = await second.figures(for: reloaded)
        #expect(figures.latestClose == 12)
        #expect(figures.previousClose == 10)
        #expect(figures.change == 2)
    }

    // MARK: - Figures & queries

    @Test("figures and queryDataLink derive latest/min/max/average over the stored window")
    func figuresAndQuery() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([DataLinkDescriptor(name: "Q", symbol: "Q.UK")])
        let id = try #require((await assistant.listDataLinks()).first?.id)

        let closes: [Double] = [100, 105, 95, 110]
        try await assistant.storeSnapshot(linkID: id, points: closes.enumerated().map { index, close in
            DataPoint(date: day(index), high: close + 2, low: close - 2, close: close)
        })

        let figures = await assistant.figures(for: id)
        #expect(figures.latestClose == 110)
        #expect(figures.previousClose == 95)
        #expect(figures.change == 15)
        #expect(figures.pointCount == 4)
        #expect(figures.periodHigh == 112)   // max(high) = 110 + 2
        #expect(figures.periodLow == 93)     // min(low)  = 95 - 2
        #expect(!figures.isEmpty)

        let query = await assistant.queryDataLink(id: id, field: .close)
        #expect(query.field == .close)
        #expect(query.latest == 110)
        #expect(query.min == 95)
        #expect(query.max == 110)
        #expect(query.count == 4)
        #expect(query.average == 102.5)      // (100 + 105 + 95 + 110) / 4

        // A day-bounded window narrows to the most recent points.
        let recent = await assistant.queryDataLink(id: id, field: .close, days: 2)
        #expect(recent.count == 2)
        #expect(recent.min == 95)
        #expect(recent.max == 110)
        #expect(recent.average == 102.5)     // (95 + 110) / 2

        // High field over the full window.
        let highs = await assistant.queryDataLink(id: id, field: .high)
        #expect(highs.max == 112)
        #expect(highs.min == 97)             // 95 + 2
    }

    // MARK: - Refresh

    @Test("refreshDataLink stores fetched points; a failing refresh keeps the last snapshot")
    func refreshFlow() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([DataLinkDescriptor(name: "R", symbol: "R.UK")])
        let id = try #require((await assistant.listDataLinks()).first?.id)

        // No source injected yet -> .notConfigured.
        await #expect(throws: DataLinkSourceError.self) {
            try await assistant.refreshDataLink(id: id)
        }

        await assistant.configureDataLinkSource(StubSource(points: [
            DataPoint(date: day(0), close: 50),
            DataPoint(date: day(1), close: 55),
        ]))
        try await assistant.refreshDataLink(id: id)
        #expect((await assistant.snapshot(for: id))?.points.count == 2)
        #expect((await assistant.figures(for: id)).latestClose == 55)

        // A throwing source must not clobber the stored snapshot.
        await assistant.configureDataLinkSource(StubSource(points: [], shouldThrow: true))
        await #expect(throws: DataLinkSourceError.self) {
            try await assistant.refreshDataLink(id: id)
        }
        #expect((await assistant.snapshot(for: id))?.points.count == 2)
        #expect((await assistant.figures(for: id)).latestClose == 55)

        // refreshAllDataLinks is best-effort: it swallows the failure and keeps state.
        await assistant.refreshAllDataLinks()
        #expect((await assistant.figures(for: id)).latestClose == 55)
    }

    @Test("dataLinkNeedsRefresh is true before first fetch and honors the staleness interval")
    func needsRefresh() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([DataLinkDescriptor(name: "N", symbol: "N.UK")])
        let id = try #require((await assistant.listDataLinks()).first?.id)

        #expect(await assistant.dataLinkNeedsRefresh(id: id))   // never fetched
        try await assistant.storeSnapshot(linkID: id, points: [DataPoint(date: day(0), close: 1)])
        #expect(!(await assistant.dataLinkNeedsRefresh(id: id, interval: 3600)))  // fresh
        #expect(await assistant.dataLinkNeedsRefresh(id: id, interval: -1))       // any age is stale
    }

    // MARK: - OKF projection

    @Test("A data link is written as an OKF concept and surfaced by retrieve/searchConcepts")
    func okfProjection() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([
            DataLinkDescriptor(
                name: "Standard Chartered", symbol: "STAN.UK", sourceID: "stooq",
                scopeDescription: "Daily end-of-day prices."
            )
        ])
        let id = try #require((await assistant.listDataLinks()).first?.id)
        try await assistant.storeSnapshot(linkID: id, points: [
            DataPoint(date: day(0), close: 900),
            DataPoint(date: day(1), close: 925),
        ])

        // storeSnapshot -> persist() writes the bundle with the Data Link concept.
        let conceptID = "datalinks/\(id.uuidString.lowercased())"
        let bundle = OKFBundle(root: root.appendingPathComponent("OKFBundle"))
        let concept = try bundle.readConcept(id: conceptID)
        #expect(concept.type == "Data Link")
        #expect(concept.metadata["symbol"] == "STAN.UK")
        #expect(concept.metadata["source"] == "stooq")
        #expect(concept.metadata["data_link_id"] == id.uuidString)
        #expect(concept.metadata["last_refreshed"] != nil)
        #expect(concept.body.contains("Latest close price"))
        #expect(concept.body.contains("925.00"))

        // The concept is listed in the bundle index.
        let index = try String(
            contentsOf: bundle.root.appendingPathComponent("index.md"), encoding: .utf8
        )
        #expect(index.contains("# Data Links"))

        // retrieve surfaces it with a navigation-ready data-link citation.
        let passages = await assistant.retrieve("Standard Chartered price")
        #expect(passages.contains { $0.citation.conceptID == conceptID })
        #expect(passages.contains { $0.citation.documentID == nil && $0.citation.document == "Standard Chartered" })

        // searchConcepts (which wraps retrieve) surfaces it too.
        let hits = await assistant.searchConcepts(query: "Standard Chartered", limit: 20)
        #expect(hits.contains { $0.conceptID == conceptID })
    }

    @Test("searchConcepts scoped to a data-link id includes it; an unrelated scope excludes it")
    func scopeFiltering() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeAssistant(root)
        try await assistant.seedDataLinks([
            DataLinkDescriptor(
                name: "Standard Chartered", symbol: "STAN.L", sourceID: "yahoo",
                scopeDescription: "Daily end-of-day prices."
            )
        ])
        let id = try #require((await assistant.listDataLinks()).first?.id)
        try await assistant.storeSnapshot(linkID: id, points: [
            DataPoint(date: day(0), close: 900),
            DataPoint(date: day(1), close: 925),
        ])
        let conceptID = "datalinks/\(id.uuidString.lowercased())"

        // Scoping to the data link's own id surfaces its concept. Its citation has
        // documentID == nil, so this proves the filter matches it via the concept id.
        let scoped = await assistant.searchConcepts(
            query: "Standard Chartered price", filters: ConceptFilters(documentIDs: [id]), limit: 20
        )
        #expect(scoped.contains { $0.conceptID == conceptID })

        // Scoping to an unrelated id excludes the data link entirely.
        let unrelated = await assistant.searchConcepts(
            query: "Standard Chartered price", filters: ConceptFilters(documentIDs: [UUID()]), limit: 20
        )
        #expect(!unrelated.contains { $0.conceptID == conceptID })
    }
}
