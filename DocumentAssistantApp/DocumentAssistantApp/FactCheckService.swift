import Foundation
import DocumentAssistant

/// Progress phases surfaced while a fact check runs.
enum FactCheckStage {
    case searchingWeb
    case analyzing
    case generating
    case finished
}

/// Events emitted by a fact check: stage changes, the evidence gathered, and the
/// model's streamed tokens.
enum FactCheckEvent {
    case stage(FactCheckStage)
    case sources([WebResult])
    case token(String)
}

/// Drives a fact check end to end: derive a query from the selected claim, gather
/// key-free DuckDuckGo evidence, then stream an on-device verdict built from that
/// evidence.
///
/// Web fetching is best-effort: the Instant Answer JSON endpoint is tried first and
/// the unofficial HTML endpoint second. Any failure (offline, rate-limit, markup
/// change) simply yields less/no evidence rather than aborting, so the model still
/// returns a cautious verdict.
struct FactCheckService {
    let assistant: DocumentAssistant

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    private static let timeout: TimeInterval = 20
    private static let maxEvidence = 6

    /// Streams stage updates, the sources used, and the verdict tokens for a claim.
    func stream(claim: String) -> AsyncThrowingStream<FactCheckEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.stage(.searchingWeb))
                    let query = FactCheckPrompt.deriveQuery(from: claim)
                    let evidence = await gather(query)
                    continuation.yield(.sources(evidence))
                    continuation.yield(.stage(.analyzing))
                    let prompt = FactCheckPrompt.build(claim: claim, evidence: evidence)
                    continuation.yield(.stage(.generating))
                    let tokens = await assistant.generate(prompt: prompt)
                    for try await token in tokens {
                        try Task.checkCancellation()
                        continuation.yield(.token(token))
                    }
                    continuation.yield(.stage(.finished))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Web search (DuckDuckGo, no key)

    /// Combines the Instant Answer and HTML endpoints, de-duplicating by URL and
    /// capping the evidence set so the prompt stays bounded.
    private func gather(_ query: String) async -> [WebResult] {
        var combined: [WebResult] = []
        var seen = Set<String>()
        func add(_ results: [WebResult]) {
            for result in results where !result.url.isEmpty && seen.insert(result.url).inserted {
                combined.append(result)
            }
        }
        if let data = await fetch(Self.instantAnswerURL(query)) {
            add(DuckDuckGo.parseInstantAnswer(data))
        }
        if let html = await fetch(Self.htmlURL(query)),
           let text = String(data: html, encoding: .utf8) {
            add(DuckDuckGo.parseHTML(text))
        }
        return Array(combined.prefix(Self.maxEvidence))
    }

    private func fetch(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    static func instantAnswerURL(_ query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.duckduckgo.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        return components.url
    }

    static func htmlURL(_ query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "html.duckduckgo.com"
        components.path = "/html/"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: "us-en"),
        ]
        return components.url
    }
}
