import Foundation
import Testing
@testable import DocumentAssistant

@Suite("Fact check")
struct FactCheckTests {

    // MARK: - Query derivation

    @Test("Query trims, strips wrapping quotes and collapses whitespace")
    func queryCleanup() {
        #expect(FactCheckPrompt.deriveQuery(from: "  \"Hello world\"  ") == "Hello world")
        #expect(FactCheckPrompt.deriveQuery(from: "a   b\n\tc") == "a b c")
    }

    @Test("Long claims shorten to the first sentence")
    func queryFirstSentence() {
        let claim = "The quick brown fox jumps over the lazy dog. " + String(repeating: "extra ", count: 40)
        #expect(FactCheckPrompt.deriveQuery(from: claim) == "The quick brown fox jumps over the lazy dog")
    }

    // MARK: - Instant Answer JSON

    @Test("Instant answer maps abstract, related and nested topics")
    func instantAnswer() throws {
        let json = """
        {
          "Heading": "Paris",
          "AbstractText": "Paris is the capital of France.",
          "AbstractSource": "Wikipedia",
          "AbstractURL": "https://en.wikipedia.org/wiki/Paris",
          "Answer": "",
          "Definition": "",
          "RelatedTopics": [
            {"Text": "Paris population - About 2.1 million.", "FirstURL": "https://example.com/paris-pop"},
            {"Name": "group", "Topics": [
              {"Text": "Eiffel Tower - A wrought-iron tower.", "FirstURL": "https://example.com/eiffel"}
            ]}
          ]
        }
        """
        let results = DuckDuckGo.parseInstantAnswer(Data(json.utf8))
        #expect(results.count == 3)
        #expect(results[0].url == "https://en.wikipedia.org/wiki/Paris")
        #expect(results[0].snippet == "Paris is the capital of France.")
        #expect(results[1].title == "Paris population")
        #expect(results[1].snippet == "About 2.1 million.")
        #expect(results[2].url == "https://example.com/eiffel")
    }

    @Test("Instant answer ignores empty fields and malformed data")
    func instantAnswerEmpty() {
        #expect(DuckDuckGo.parseInstantAnswer(Data("not json".utf8)).isEmpty)
        let results = DuckDuckGo.parseInstantAnswer(Data("{\"Heading\":\"X\"}".utf8))
        #expect(results.isEmpty)
    }

    // MARK: - HTML endpoint

    @Test("HTML parse pairs result links with snippets and unwraps redirects")
    func htmlParse() {
        let html = """
        <div class="result results_links">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=abc">Example <b>Title</b></a>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">This is the snippet text.</a>
        </div>
        <div class="result">
          <a class="result__a" href="https://second.com/x">Second Title</a>
          <a class="result__snippet">Second snippet.</a>
        </div>
        """
        let results = DuckDuckGo.parseHTML(html)
        #expect(results.count == 2)
        #expect(results[0].title == "Example Title")
        #expect(results[0].snippet == "This is the snippet text.")
        #expect(results[0].url == "https://example.com/page")
        #expect(results[1].title == "Second Title")
        #expect(results[1].url == "https://second.com/x")
    }

    @Test("Redirect resolution unwraps uddg and normalizes protocol-relative hrefs")
    func redirectResolution() {
        #expect(DuckDuckGo.resolveRedirect("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com") == "https://example.com")
        #expect(DuckDuckGo.resolveRedirect("//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com&rut=x") == "https://a.com")
        #expect(DuckDuckGo.resolveRedirect("//example.org/y") == "https://example.org/y")
        #expect(DuckDuckGo.resolveRedirect("   ") == "")
    }

    // MARK: - Prompt build

    @Test("Prompt carries the claim, instruction, numbered evidence and truncates snippets")
    func promptBuild() {
        let evidence = [WebResult(title: "T", snippet: String(repeating: "a", count: 400), url: "https://e.com")]
        let prompt = FactCheckPrompt.build(claim: "The Earth is flat.", evidence: evidence)
        #expect(prompt.contains("CLAIM:"))
        #expect(prompt.contains("The Earth is flat."))
        #expect(prompt.contains("**Verdict:"))
        #expect(prompt.contains("[1] T"))
        #expect(prompt.contains("https://e.com"))
        #expect(prompt.contains(String(repeating: "a", count: 300)))
        #expect(!prompt.contains(String(repeating: "a", count: 301)))
    }

    @Test("Prompt caps evidence at six results")
    func promptCap() {
        let evidence = (1...8).map { WebResult(title: "R\($0)", snippet: "s\($0)", url: "https://e.com/\($0)") }
        let prompt = FactCheckPrompt.build(claim: "c", evidence: evidence)
        #expect(prompt.contains("[6] R6"))
        #expect(!prompt.contains("[7] R7"))
    }

    @Test("Prompt with no evidence asks for a cautious assessment")
    func promptNoEvidence() {
        let prompt = FactCheckPrompt.build(claim: "Something.", evidence: [])
        #expect(prompt.contains("No external evidence was found"))
    }

    @Test("Prompt requires an English assessment and repeats it after the evidence")
    func promptLanguage() {
        let prompt = FactCheckPrompt.build(
            claim: "地球是平的。",
            evidence: [WebResult(title: "T", snippet: "s", url: "https://e.com")]
        )
        // Stated with the instructions and repeated as the closing line, so a
        // non-English claim can't set the assessment's language.
        #expect(prompt.contains("Write the whole assessment in English"))
        #expect(prompt.hasSuffix("Respond in English now, beginning with the \"**Verdict: X**\" line."))
    }
}
