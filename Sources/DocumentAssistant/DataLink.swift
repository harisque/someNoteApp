import Foundation

/// One observation in a structured data series. For a daily financial snapshot this
/// is an OHLCV bar. Every value field is optional so a source that supplies only a
/// subset (or uses `N/D` for "no data") still round-trips cleanly.
public struct DataPoint: Codable, Hashable, Sendable {
    public var date: Date
    public var open: Double?
    public var high: Double?
    public var low: Double?
    public var close: Double?
    public var volume: Double?
    public init(
        date: Date, open: Double? = nil, high: Double? = nil,
        low: Double? = nil, close: Double? = nil, volume: Double? = nil
    ) {
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

/// A read-only structured-data asset that lives under Confidential. The raw series
/// is fetched from a `DataLinkSource` and stored on device, but it is never shown
/// directly: the UI exposes only `scopeDescription`, `lastRefreshedAt`, and derived
/// summary figures, and the OKF layer exposes a compact text summary that Ask can
/// cite. Seeded from the app bundle; see `DataLinkDescriptor`.
public struct DataLink: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// Source-native ticker (for Stooq, e.g. `STAN.UK`); lowercased when fetched.
    public var symbol: String
    public var sourceID: String
    public var scopeDescription: String
    public var category: DocumentCategory
    public var lastRefreshedAt: Date?
    public init(
        id: UUID = UUID(), name: String, symbol: String, sourceID: String = "stooq",
        scopeDescription: String = "", category: DocumentCategory = .confidential,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.sourceID = sourceID
        self.scopeDescription = scopeDescription
        self.category = category
        self.lastRefreshedAt = lastRefreshedAt
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, sourceID, scopeDescription, category, lastRefreshedAt
    }
    /// Tolerant decoder (mirrors `Document`/`Folder`) so one partial or legacy entry
    /// can't fail the whole `dataLinks.json` decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Data Link"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? "stooq"
        scopeDescription = try c.decodeIfPresent(String.self, forKey: .scopeDescription) ?? ""
        lastRefreshedAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        let raw = try c.decodeIfPresent(String.self, forKey: .category)
        category = (raw == "personal") ? .personal : .confidential
    }
}

/// A stored snapshot of a data link's series at a point in time. Persisted under
/// `DataSnapshots/<linkID>.json` and kept in memory for fast summaries/figures.
public struct DataSnapshot: Codable, Hashable, Sendable {
    public let linkID: UUID
    public var points: [DataPoint]
    public var fetchedAt: Date
    public init(linkID: UUID, points: [DataPoint], fetchedAt: Date = Date()) {
        self.linkID = linkID
        self.points = points
        self.fetchedAt = fetchedAt
    }
}

/// Codable seed descriptor loaded from the app bundle. `seedDataLinks` is idempotent
/// by `symbol`, so this can ship in `dataLinks.json` and be applied on every launch.
public struct DataLinkDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var symbol: String
    public var sourceID: String
    public var scopeDescription: String
    public init(name: String, symbol: String, sourceID: String = "stooq", scopeDescription: String = "") {
        self.name = name
        self.symbol = symbol
        self.sourceID = sourceID
        self.scopeDescription = scopeDescription
    }
    private enum CodingKeys: String, CodingKey { case name, symbol, sourceID, scopeDescription }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Data Link"
        symbol = try c.decode(String.self, forKey: .symbol)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? "stooq"
        scopeDescription = try c.decodeIfPresent(String.self, forKey: .scopeDescription) ?? ""
    }
}

/// Derived, user-facing figures for a data link's most recent stored window. This is
/// the only numeric view surfaced in the UI (no chart, no raw table).
public struct DataLinkFigures: Hashable, Sendable {
    public var asOf: Date?
    public var latestClose: Double?
    public var previousClose: Double?
    public var change: Double?
    public var changePercent: Double?
    public var periodHigh: Double?
    public var periodLow: Double?
    public var pointCount: Int
    public init(
        asOf: Date? = nil, latestClose: Double? = nil, previousClose: Double? = nil,
        change: Double? = nil, changePercent: Double? = nil, periodHigh: Double? = nil,
        periodLow: Double? = nil, pointCount: Int = 0
    ) {
        self.asOf = asOf
        self.latestClose = latestClose
        self.previousClose = previousClose
        self.change = change
        self.changePercent = changePercent
        self.periodHigh = periodHigh
        self.periodLow = periodLow
        self.pointCount = pointCount
    }
    /// True when there is no stored data yet (nothing to summarize).
    public var isEmpty: Bool { pointCount == 0 && latestClose == nil }
}

/// Which numeric field of a `DataPoint` a `queryDataLink` request targets.
public enum DataLinkField: String, Codable, Hashable, Sendable {
    case open, high, low, close, volume
}

/// Deterministic result of a `queryDataLink` request over the stored window. This is
/// the precise-value tool counterpart to the prose summary projected into OKF.
public struct DataLinkQueryResult: Hashable, Sendable {
    public var field: DataLinkField
    public var latest: Double?
    public var min: Double?
    public var max: Double?
    public var average: Double?
    public var count: Int
    public var asOf: Date?
    public init(
        field: DataLinkField, latest: Double? = nil, min: Double? = nil, max: Double? = nil,
        average: Double? = nil, count: Int = 0, asOf: Date? = nil
    ) {
        self.field = field
        self.latest = latest
        self.min = min
        self.max = max
        self.average = average
        self.count = count
        self.asOf = asOf
    }
}
