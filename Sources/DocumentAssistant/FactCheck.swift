import Foundation

/// One web-search result used as fact-check evidence.
public struct WebResult: Sendable, Hashable, Identifiable {
    public var id: String { url }
    public let title: String
    public let snippet: String
    public let url: String
    public init(title: String, snippet: String, url: String) {
        self.title = title
        self.snippet = snippet
        self.url = url
    }
}

/// Key-free DuckDuckGo response parsers. These are pure functions (no network)
/// so they can be unit-tested with fixtures.
public enum DuckDuckGo {

    // MARK: - Instant Answer API (JSON)

    private struct InstantAnswer: Decodable {
        let AbstractText: String?
        let AbstractSource: String?
        let AbstractURL: String?
        let Answer: String?
        let Definition: String?
        let DefinitionURL: String?
        let Heading: String?
        let RelatedTopics: [RelatedTopic]?
    }

    private struct RelatedTopic: Decodable {
        let Text: String?
        let FirstURL: String?
        let Result: String?
        let Topics: [RelatedTopic]?
    }

    /// Maps a DuckDuckGo Instant Answer payload to evidence results: the direct
    /// answer, the abstract, the definition, then related topics (flattening the
    /// nested `Topics` grouping DuckDuckGo sometimes returns).
    public static func parseInstantAnswer(_ data: Data) -> [WebResult] {
        guard let root = try? JSONDecoder().decode(InstantAnswer.self, from: data) else { return [] }
        var results: [WebResult] = []
        let heading = nonEmpty(root.Heading) ?? "DuckDuckGo"
        let fallbackURL = "https://duckduckgo.com/"

        if let answer = nonEmpty(root.Answer) {
            results.append(WebResult(
                title: "\(heading) — Answer",
                snippet: answer,
                url: nonEmpty(root.AbstractURL) ?? fallbackURL
            ))
        }
        if let abstract = nonEmpty(root.AbstractText) {
            results.append(WebResult(
                title: "\(heading) — \(nonEmpty(root.AbstractSource) ?? "Summary")",
                snippet: abstract,
                url: nonEmpty(root.AbstractURL) ?? fallbackURL
            ))
        }
        if let definition = nonEmpty(root.Definition),
           definition.lowercased() != nonEmpty(root.AbstractText)?.lowercased() {
            results.append(WebResult(
                title: "\(heading) — Definition",
                snippet: definition,
                url: nonEmpty(root.DefinitionURL) ?? fallbackURL
            ))
        }
        appendRelated(root.RelatedTopics, into: &results)
        return results
    }

    private static func appendRelated(_ topics: [RelatedTopic]?, into results: inout [WebResult]) {
        guard let topics else { return }
        for topic in topics {
            if let nested = topic.Topics {
                appendRelated(nested, into: &results)
                continue
            }
            guard let url = nonEmpty(topic.FirstURL) else { continue }
            let text = nonEmpty(topic.Text) ?? nonEmpty(topic.Result) ?? ""
            guard !text.isEmpty else { continue }
            // Related-topic text is usually "Title - snippet"; split on the first " - ".
            let title: String
            let snippet: String
            if let range = text.range(of: " - ") {
                title = String(text[..<range.lowerBound])
                snippet = String(text[range.upperBound...])
            } else {
                title = String(text.prefix(60))
                snippet = text
            }
            results.append(WebResult(title: title, snippet: snippet, url: url))
        }
    }

    // MARK: - HTML endpoint (best-effort organic results)

    /// Best-effort parse of the `html.duckduckgo.com/html/` results page: pairs each
    /// `result__a` anchor (title + href) with the corresponding `result__snippet`.
    public static func parseHTML(_ html: String) -> [WebResult] {
        var results: [WebResult] = []
        let anchors = matches(of: "<a\\b([^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*)>(.*?)</a>", in: html)
        let snippets = matches(of: "class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</a>", in: html)
        for (index, anchor) in anchors.enumerated() {
            guard anchor.count >= 2 else { continue }
            let attrs = anchor[0]
            let inner = anchor[1]
            guard let hrefMatch = matches(of: "href=\"([^\"]+)\"", in: attrs).first,
                  !hrefMatch.isEmpty else { continue }
            let href = resolveRedirect(hrefMatch[0])
            let title = stripTags(inner)
            guard !href.isEmpty, !title.isEmpty else { continue }
            let snippet = index < snippets.count ? stripTags(snippets[index][0]) : ""
            results.append(WebResult(title: title, snippet: snippet, url: href))
        }
        return results
    }

    /// Unwraps DuckDuckGo's redirect (`//duckduckgo.com/l/?uddg=<percent-encoded>`)
    /// to the real destination; otherwise normalizes a protocol-relative or bare
    /// href to an absolute https URL.
    public static func resolveRedirect(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalizedAmp = trimmed.replacingOccurrences(of: "&amp;", with: "&")
        if let range = normalizedAmp.range(of: "uddg=") {
            let encoded = normalizedAmp[range.upperBound...].prefix(while: { $0 != "&" })
            if let decoded = String(encoded).removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
        }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Runs a case-insensitive regex, returning each match's capture groups (the
    /// full match at index 0 is dropped).
    private static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = text as NSString
        var out: [[String]] = []
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            var groups: [String] = []
            for g in 1..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out.append(groups)
        }
        return out
    }

    private static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(noTags).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

/// Builds the search query and the on-device analysis prompt for a fact check.
public enum FactCheckPrompt {

    /// Turns a selected claim into a concise search query: trims, strips wrapping
    /// quotes, collapses whitespace, and shortens very long claims to the first
    /// sentence (or a leading slice) so the query stays focused.
    public static func deriveQuery(from claim: String) -> String {
        var q = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        while q.count >= 2, let first = q.first, let last = q.last, isQuotePair(first, last) {
            q = String(q.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        q = q.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard q.count > 140 else { return q }
        let terminators = CharacterSet(charactersIn: ".!?")
        if let end = q.unicodeScalars.firstIndex(where: { terminators.contains($0) }) {
            let firstSentence = String(q.unicodeScalars[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if firstSentence.count >= 20 { return String(firstSentence.prefix(140)) }
        }
        return String(q.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isQuotePair(_ a: Character, _ b: Character) -> Bool {
        (a == "\"" && b == "\"") || (a == "'" && b == "'") || (a == "\u{201C}" && b == "\u{201D}")
    }

    /// Composes the analysis prompt from the claim and the gathered evidence. The
    /// model is told to open with an explicit verdict line, cite evidence by number,
    /// avoid inventing facts, and admit when evidence is insufficient.
    public static func build(
        claim: String,
        evidence: [WebResult],
        maxEvidence: Int = 6,
        maxSnippetChars: Int = 300
    ) -> String {
        let trimmedClaim = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        lines.append("You are a meticulous fact-checker. Assess the CLAIM using ONLY the numbered WEB EVIDENCE below.")
        lines.append("Begin with a single verdict line exactly in the form \"**Verdict: X**\" where X is one of: Supported, Contradicted, Mixed, Insufficient evidence.")
        lines.append("Then explain briefly, referencing evidence by number (for example [1]). Do not invent facts beyond the evidence. If the evidence is thin or conflicting, say so.")
        lines.append("")
        lines.append("CLAIM:")
        lines.append(trimmedClaim.isEmpty ? "(none)" : trimmedClaim)
        lines.append("")
        lines.append("WEB EVIDENCE:")
        let capped = Array(evidence.prefix(maxEvidence))
        if capped.isEmpty {
            lines.append("No external evidence was found. State that you could not verify the claim against sources and give a cautious assessment.")
        } else {
            for (index, item) in capped.enumerated() {
                lines.append("[\(index + 1)] \(item.title)")
                let snippet = truncate(item.snippet, to: maxSnippetChars)
                if !snippet.isEmpty { lines.append("    \(snippet)") }
                lines.append("    Source: \(item.url)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ s: String, to limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        return String(t.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
