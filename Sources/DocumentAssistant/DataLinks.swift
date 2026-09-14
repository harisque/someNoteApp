import Foundation

/// Data Links: read-only structured-data assets under Confidential. This extension
/// owns seeding, on-device snapshot storage, manual/lazy refresh through an injected
/// `DataLinkSource`, derived figures/queries, and the compact text summary that is
/// projected into the OKF bundle so Ask can surface and cite live data.
///
/// Stored state (`dataLinks`, `dataSnapshots`, `dataLinkSource`) lives on the actor in
/// `DocumentAssistant.swift`; Swift extensions cannot add stored properties.
/// Namespace for Data Link limits. Kept as a top-level enum because Swift extensions
/// cannot declare stored properties (including static ones); mirrors `OKFToolLimits`.
public enum DataLinkLimits {
    /// Upper bound on stored points per snapshot (~9 months of daily bars).
    public static let maxSnapshotPoints = 180
    /// A link is stale (and lazily refreshed on open) after this many seconds.
    public static let stalenessInterval: TimeInterval = 15 * 60
}

@available(macOS 10.15, iOS 13.0, *)
extension DocumentAssistant {
    // MARK: - Locations

    nonisolated var dataLinksURL: URL {
        store.deletingLastPathComponent().appendingPathComponent("dataLinks.json")
    }
    nonisolated var dataSnapshotsDirectory: URL {
        store.deletingLastPathComponent().appendingPathComponent("DataSnapshots", isDirectory: true)
    }
    nonisolated func dataSnapshotURL(_ id: UUID) -> URL {
        dataSnapshotsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Injection

    /// Injects the source used by `refreshDataLink`. Called from the app so the library
    /// stays free of any concrete network type. Pass `nil` to disable refreshing.
    public func configureDataLinkSource(_ source: DataLinkSource?) {
        dataLinkSource = source
    }

    // MARK: - Seeding & listing

    /// Idempotently applies bundled descriptors, keyed by `symbol` (case-insensitive),
    /// preserving each link's stable id and last-refresh time. Safe to run every launch
    /// and to re-run after editing the bundle seed.
    public func seedDataLinks(_ descriptors: [DataLinkDescriptor]) throws {
        var changed = false
        for descriptor in descriptors {
            let symbol = descriptor.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !symbol.isEmpty else { continue }
            if let index = dataLinks.firstIndex(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) {
                if dataLinks[index].name != descriptor.name {
                    dataLinks[index].name = descriptor.name; changed = true
                }
                if dataLinks[index].scopeDescription != descriptor.scopeDescription {
                    dataLinks[index].scopeDescription = descriptor.scopeDescription; changed = true
                }
                if dataLinks[index].sourceID != descriptor.sourceID {
                    dataLinks[index].sourceID = descriptor.sourceID; changed = true
                }
            } else {
                dataLinks.append(DataLink(
                    name: descriptor.name, symbol: symbol, sourceID: descriptor.sourceID,
                    scopeDescription: descriptor.scopeDescription
                ))
                changed = true
            }
        }
        if changed { try persist() }
    }

    public func listDataLinks() -> [DataLink] { dataLinks }
    public func dataLink(id: UUID) -> DataLink? { dataLinks.first { $0.id == id } }
    public func snapshot(for id: UUID) -> DataSnapshot? { dataSnapshots[id] }

    // MARK: - Snapshots

    /// Bounds and stores a fetched series, stamps `lastRefreshedAt`, and re-projects the
    /// OKF bundle (via `persist`) so Ask can cite the refreshed data.
    func storeSnapshot(linkID: UUID, points: [DataPoint]) throws {
        guard let index = dataLinks.firstIndex(where: { $0.id == linkID }) else { return }
        let sorted = points.sorted { $0.date < $1.date }
        let bounded = Array(sorted.suffix(DataLinkLimits.maxSnapshotPoints))
        let snapshot = DataSnapshot(linkID: linkID, points: bounded, fetchedAt: Date())
        dataSnapshots[linkID] = snapshot
        dataLinks[index].lastRefreshedAt = snapshot.fetchedAt
        try FileManager.default.createDirectory(at: dataSnapshotsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: dataSnapshotURL(linkID), options: .atomic)
        try persist()
    }

    // MARK: - Refresh

    /// Fetches and stores one link's series. Throws `.notConfigured` when no source is
    /// injected; a fetch/parse failure propagates so the caller keeps the last snapshot.
    public func refreshDataLink(id: UUID) async throws {
        guard let source = dataLinkSource else { throw DataLinkSourceError.notConfigured }
        guard let link = dataLinks.first(where: { $0.id == id }) else { return }
        let points = try await source.fetchDailySeries(symbol: link.symbol)
        guard !points.isEmpty else { throw DataLinkSourceError.noData }
        try storeSnapshot(linkID: id, points: points)
    }

    /// Best-effort refresh of every link; individual failures are swallowed so one bad
    /// symbol can't block the others. Used on launch.
    public func refreshAllDataLinks() async {
        guard dataLinkSource != nil, !dataLinks.isEmpty else { return }
        for link in dataLinks { try? await refreshDataLink(id: link.id) }
    }

    /// True when a link has never been fetched or its snapshot is older than `interval`.
    /// The single source of truth for the UI's lazy-refresh-on-open behavior.
    public func dataLinkNeedsRefresh(id: UUID, interval: TimeInterval = DataLinkLimits.stalenessInterval) -> Bool {
        guard let link = dataLinks.first(where: { $0.id == id }) else { return false }
        guard let last = link.lastRefreshedAt else { return true }
        return Date().timeIntervalSince(last) > interval
    }

    // MARK: - Derived figures & queries

    /// The only numeric view surfaced in the UI: latest close, change vs previous close,
    /// and period high/low over the stored window. No raw series is exposed.
    public func figures(for id: UUID) -> DataLinkFigures { computeFigures(id) }

    /// Deterministic latest/min/max/average for one field over the stored window
    /// (optionally the most recent `days` points). Precise-value counterpart to the
    /// prose summary projected into OKF.
    public func queryDataLink(id: UUID, field: DataLinkField = .close, days: Int? = nil) -> DataLinkQueryResult {
        let points = windowPoints(id, days: days)
        let values = points.compactMap { value($0, field: field) }
        guard !values.isEmpty else { return DataLinkQueryResult(field: field) }
        let sum = values.reduce(0, +)
        return DataLinkQueryResult(
            field: field,
            latest: values.last,
            min: values.min(),
            max: values.max(),
            average: sum / Double(values.count),
            count: values.count,
            asOf: points.last?.date
        )
    }

    // MARK: - OKF projection

    /// Compact per-link text summaries, keyed by link id. Written into the OKF bundle by
    /// `persist` and scored by `retrieve`, so Ask can surface and cite live data.
    func dataLinkSummaries() -> [UUID: String] {
        var summaries: [UUID: String] = [:]
        for link in dataLinks { summaries[link.id] = summaryText(for: link) }
        return summaries
    }

    // MARK: - Internal helpers

    func computeFigures(_ id: UUID) -> DataLinkFigures {
        let points = dataSnapshots[id]?.points ?? []
        guard !points.isEmpty else { return DataLinkFigures() }
        let closes = points.compactMap { $0.close }
        let latest = closes.last
        let previous = closes.count >= 2 ? closes[closes.count - 2] : nil
        var change: Double?
        var changePercent: Double?
        if let latest, let previous {
            change = latest - previous
            if previous != 0 { changePercent = (latest - previous) / previous * 100 }
        }
        let highs = points.compactMap { $0.high ?? $0.close }
        let lows = points.compactMap { $0.low ?? $0.close }
        return DataLinkFigures(
            asOf: points.last?.date,
            latestClose: latest,
            previousClose: previous,
            change: change,
            changePercent: changePercent,
            periodHigh: highs.max(),
            periodLow: lows.min(),
            pointCount: points.count
        )
    }

    private func windowPoints(_ id: UUID, days: Int?) -> [DataPoint] {
        let points = dataSnapshots[id]?.points ?? []
        guard let days, days > 0 else { return points }
        return Array(points.suffix(days))
    }

    private func value(_ point: DataPoint, field: DataLinkField) -> Double? {
        switch field {
        case .open: return point.open
        case .high: return point.high
        case .low: return point.low
        case .close: return point.close
        case .volume: return point.volume
        }
    }

    private func summaryText(for link: DataLink) -> String {
        let figures = computeFigures(link.id)
        // Local formatters: DateFormatter is not Sendable, so it must not live in
        // shared/static state under Swift 6 strict concurrency.
        let dateTime = makeFormatter("yyyy-MM-dd HH:mm 'UTC'")
        let dateOnly = makeFormatter("yyyy-MM-dd")
        var lines: [String] = []
        lines.append("\(link.name) (\(link.symbol)) is a read-only live data link.")
        let scope = link.scopeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty { lines.append("Data scope: \(scope)") }
        lines.append("Data source: \(link.sourceID).")
        if let last = link.lastRefreshedAt {
            lines.append("Last refreshed: \(dateTime.string(from: last)).")
        } else {
            lines.append("Last refreshed: never.")
        }
        if let close = figures.latestClose {
            var line = "Latest close price: \(number(close))"
            if let asOf = figures.asOf { line += " as of \(dateOnly.string(from: asOf))" }
            if let change = figures.change, let percent = figures.changePercent {
                line += " (\(signed(change)), \(signed(percent))% vs previous close \(number(figures.previousClose ?? 0)))"
            }
            lines.append(line + ".")
        }
        if let high = figures.periodHigh, let low = figures.periodLow, figures.pointCount > 0 {
            lines.append("Period high/low across the stored \(figures.pointCount)-day window: \(number(high)) / \(number(low)).")
        }
        return lines.joined(separator: "\n")
    }

    private func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private func number(_ value: Double) -> String { String(format: "%.2f", value) }
    private func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + String(format: "%.2f", value)
    }
}
