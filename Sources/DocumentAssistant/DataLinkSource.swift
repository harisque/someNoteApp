import Foundation

/// An official (later internal) source of structured data for a `DataLink`. The app
/// ships a key-free remote implementation (`RemoteDataLinkSource`); keeping this a
/// protocol means swapping in an internal endpoint later is a one-file change with no
/// UI or storage impact. Mirrors `ConfidentialSource`.
public protocol DataLinkSource: Sendable {
    /// Returns the recent daily series for `symbol`, chronologically ascending.
    /// Implementations should throw `DataLinkSourceError` when no usable rows come
    /// back so the caller can keep the previously stored snapshot.
    func fetchDailySeries(symbol: String) async throws -> [DataPoint]
}

public enum DataLinkSourceError: LocalizedError {
    case notConfigured
    case noData
    case parseFailed
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Data link source not configured."
        case .noData: return "The data source returned no rows."
        case .parseFailed: return "The data source response could not be parsed."
        }
    }
}

/// Placeholder source (mirrors `UnconfiguredConfidentialSource`) so a mis-wired UI
/// surfaces the "not configured" state instead of silently doing nothing.
public struct UnconfiguredDataLinkSource: DataLinkSource {
    public init() {}
    public func fetchDailySeries(symbol: String) async throws -> [DataPoint] {
        throw DataLinkSourceError.notConfigured
    }
}

/// Pure, network-free parsers so they can be unit-tested off device.
public enum Stooq {
    /// Parses Stooq's daily CSV (`Date,Open,High,Low,Close,Volume`). Skips the header,
    /// blank lines, and malformed rows (fewer than five columns or an unparseable
    /// date); empty/`N/D` cells become `nil` values. Dates are UTC `yyyy-MM-dd`. The
    /// result is chronologically ascending (Stooq already sorts ascending; we sort
    /// defensively). An invalid symbol yields an empty array rather than throwing.
    public static func parseDailyCSV(_ text: String) -> [DataPoint] {
        // Local formatter: DateFormatter is not Sendable, so it must not live in
        // shared/static state under Swift 6 strict concurrency.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"

        func numeric(_ column: String) -> Double? {
            let trimmed = column.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.uppercased() != "N/D" else { return nil }
            return Double(trimmed)
        }

        var points: [DataPoint] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.lowercased().hasPrefix("date") else { continue }
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 5, let date = formatter.date(from: columns[0]) else { continue }
            func column(_ index: Int) -> Double? {
                index < columns.count ? numeric(columns[index]) : nil
            }
            points.append(DataPoint(
                date: date, open: column(1), high: column(2),
                low: column(3), close: column(4), volume: column(5)
            ))
        }
        return points.sorted { $0.date < $1.date }
    }
}

/// Parser for Yahoo Finance's key-free `v8/finance/chart` JSON endpoint. The app's
/// remote source uses this because, unlike Stooq (which serves a JavaScript anti-bot
/// challenge that a native `URLSession` client cannot pass), Yahoo returns plain JSON
/// to a browser-like client at low request volume — exactly this app's manual/lazy
/// refresh pattern. Pure and network-free so it is unit-testable off device.
public enum Yahoo {
    /// Parses `{"chart":{"result":[{"timestamp":[…],"indicators":{"quote":[{…}]}}]}}`
    /// into chronologically ascending `DataPoint`s. Yahoo emits parallel arrays with
    /// `null`s for non-trading days; rows without a usable close are skipped — null, or
    /// a non-positive/non-finite placeholder, which is how Yahoo briefly represents a
    /// session whose exchange values it has not processed yet. A missing or errored
    /// chart yields an empty array rather than throwing, so the caller keeps its
    /// previously stored snapshot.
    public static func parseChartJSON(_ data: Data) -> [DataPoint] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let chart = root["chart"] as? [String: Any],
            let results = chart["result"] as? [[String: Any]],
            let series = results.first,
            let rawTimestamps = series["timestamp"] as? [Any]
        else { return [] }

        var opens: [Double?] = []
        var highs: [Double?] = []
        var lows: [Double?] = []
        var closes: [Double?] = []
        var volumes: [Double?] = []
        if let quote = ((series["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first {
            opens = numbers(quote["open"])
            highs = numbers(quote["high"])
            lows = numbers(quote["low"])
            closes = numbers(quote["close"])
            volumes = numbers(quote["volume"])
        }

        func value(_ array: [Double?], _ index: Int) -> Double? {
            index < array.count ? array[index] : nil
        }

        var points: [DataPoint] = []
        for (index, rawTimestamp) in rawTimestamps.enumerated() {
            guard let seconds = (rawTimestamp as? NSNumber)?.doubleValue else { continue }
            // Skip non-trading rows and Yahoo's "not yet processed" placeholders: the
            // newest bar can appear with a null or zeroed close while the exchange's
            // session values are still being finalized, and a 0.00 close must never reach
            // the stored series or the live figures.
            guard let close = value(closes, index), close.isFinite, close > 0 else { continue }
            points.append(DataPoint(
                date: Date(timeIntervalSince1970: seconds),
                open: value(opens, index), high: value(highs, index),
                low: value(lows, index), close: close, volume: value(volumes, index)
            ))
        }
        return points.sorted { $0.date < $1.date }
    }

    private static func numbers(_ value: Any?) -> [Double?] {
        guard let array = value as? [Any] else { return [] }
        return array.map { ($0 as? NSNumber)?.doubleValue }
    }
}
