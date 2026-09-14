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
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
}
