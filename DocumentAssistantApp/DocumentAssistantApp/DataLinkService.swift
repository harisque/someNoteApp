import Foundation
import DocumentAssistant

/// Key-free remote `DataLinkSource` backed by Yahoo Finance's `v8/finance/chart` JSON
/// endpoint.
///
/// The plan first targeted Stooq's fixed six-column daily CSV, but on-device verification
/// showed Stooq serves a JavaScript anti-bot challenge ("This site requires JavaScript to
/// verify your browser") that a native `URLSession` client cannot pass — so it never
/// returns CSV. Yahoo returns plain JSON to a browser-like client at low request volume,
/// which matches this app's manual/lazy refresh pattern. The swap is confined to this one
/// file plus the seed symbol because the `DataLinkSource` protocol is unchanged.
///
/// Fetching is best-effort: any failure (offline, rate-limit, markup change, empty result)
/// throws `DataLinkSourceError` so the caller keeps the previously stored snapshot instead
/// of clobbering it with nothing.
struct RemoteDataLinkSource: DataLinkSource {
    /// Request roughly a year of daily bars; the library retains only the last 180 points.
    private static let range = "1y"
    private static let interval = "1d"
    private static let timeout: TimeInterval = 20
    // Browser-like User-Agent (mirrors FactCheckService) so Yahoo's light anti-bot
    // heuristic treats the request as an ordinary mobile browser fetch.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// `nonisolated`: this runs on the `DocumentAssistant` actor's behalf (background),
    /// so it must not inherit the app's default MainActor isolation. It touches only
    /// immutable Sendable static constants and local values, so the struct stays Sendable.
    nonisolated func fetchDailySeries(symbol: String) async throws -> [DataPoint] {
        guard let url = Self.chartURL(symbol: symbol) else { throw DataLinkSourceError.noData }
        // A live refresh must never be answered from a cache — URLSession's own cache, a
        // VPN/proxy in front of the device, or Yahoo's edge. Without this, a refresh can
        // silently store a stale response: on device, a snapshot that should have ended on
        // Monday's bar came back ending on Friday's, because the identical URL had been
        // fetched before. The URL therefore carries a unique per-request nonce and the
        // request opts out of every cache layer.
        var request = URLRequest(url: Self.cacheBusted(url))
        request.timeoutInterval = Self.timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DataLinkSourceError.noData
        }
        let points = Yahoo.parseChartJSON(data)
        guard !points.isEmpty else { throw DataLinkSourceError.noData }
        return points
    }

    /// Builds `https://query1.finance.yahoo.com/v8/finance/chart/<symbol>?range=1y&interval=1d`.
    /// Yahoo uses the exchange-suffixed symbol as-is (e.g. `STAN.L` for London), so the
    /// symbol is percent-encoded into the path unchanged rather than lowercased.
    nonisolated static func chartURL(symbol: String) -> URL? {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.percentEncodedPath = "/v8/finance/chart/\(encoded)"
        components.queryItems = [
            URLQueryItem(name: "range", value: range),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "events", value: "history"),
        ]
        return components.url
    }

    /// Appends a unique `_` nonce so every refresh is a distinct URL that no cache can
    /// answer with a previously stored response. Defaults to the current epoch
    /// milliseconds; callers may pass a fixed value (e.g. in tests).
    nonisolated static func cacheBusted(_ url: URL, nonce: Int = Int(Date().timeIntervalSince1970 * 1000)) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "_", value: String(nonce)))
        components.queryItems = items
        return components.url ?? url
    }
}

/// TEMPORARY demo backfill — remove after the demo (delete this struct and change the
/// call site in `ContentView` back to `RemoteDataLinkSource()`).
///
/// Yahoo Finance has not yet republished the official OHLC for STAN.L's Mon 2026-09-14
/// session: its chart row is still a zeroed/`null` placeholder (only volume has filled in),
/// so the Data Link would otherwise show Fri 2026-09-11 as the latest close. This wrapper
/// supplies that one session's real, already-published values — close 2311.0, day range
/// 2292.0–2332.0, previous close 2298.0, volume 1,443,000 (per the exchange / Google
/// Finance) — so the demo shows the correct latest close. It is a strict no-op once Yahoo
/// republishes the day (the fetched series then already contains a 2026-09-14 bar), and it
/// never alters any other symbol or session.
struct DemoBackfillSource: DataLinkSource {
    let wrapped: DataLinkSource

    /// The single session Yahoo is lagging on, keyed by uppercased symbol (prices in pence,
    /// GBX). The timestamp matches Yahoo's daily-bar convention (07:00 UTC = 08:00 London
    /// open) so a real republished bar lands on the same day and supersedes this cleanly.
    private static let missingSessions: [String: DataPoint] = [
        "STAN.L": DataPoint(
            date: Date(timeIntervalSince1970: 1_789_369_200),   // 2026-09-14 07:00 UTC
            open: 2298.0, high: 2332.0, low: 2292.0, close: 2311.0, volume: 1_443_000
        )
    ]

    /// `nonisolated`: mirrors `RemoteDataLinkSource` — runs on the `DocumentAssistant`
    /// actor's behalf, so it must not inherit the app's default MainActor isolation. It
    /// only delegates and does pure local computation, so the struct stays Sendable.
    nonisolated func fetchDailySeries(symbol: String) async throws -> [DataPoint] {
        var points = try await wrapped.fetchDailySeries(symbol: symbol)
        guard let session = Self.missingSessions[symbol.uppercased()] else { return points }
        // Fill the gap only if the source truly has not published that trading day yet.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.dateComponents([.year, .month, .day], from: session.date)
        let alreadyPublished = points.contains {
            calendar.dateComponents([.year, .month, .day], from: $0.date) == day
        }
        guard !alreadyPublished else { return points }
        points.append(session)
        return points.sorted { $0.date < $1.date }
    }
}
