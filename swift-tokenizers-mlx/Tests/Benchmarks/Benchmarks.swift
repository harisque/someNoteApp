import BenchmarkHelpers
import HFAPI
import MLXEmbedders
import MLXEmbeddersTokenizers
import MLXLMTokenizers
import TestHelpers
import Testing

@Suite(.serialized)
struct Benchmarks {
    @Test func loadTokenizer() async throws {
        let stats = try await benchmarkTokenizerLoading(
            from: HFClient.default,
            using: TokenizersLoader()
        )
        stats.printSummary(label: "Tokenizer load (swift-tokenizers)")
    }

    @Test func tokenizeText() async throws {
        let sampleText = try await loadTokenizationBenchmarkText()
        let stats = try await benchmarkTokenization(
            from: HFClient.default,
            using: TokenizersLoader(),
            text: sampleText
        )
        stats.printSummary(label: "Tokenization (swift-tokenizers)")
    }

    @Test func decodeText() async throws {
        let sampleText = try await loadDecodingBenchmarkText()
        let stats = try await benchmarkDecoding(
            from: HFClient.default,
            using: TokenizersLoader(),
            text: sampleText
        )
        stats.printSummary(label: "Decoding (swift-tokenizers)")
    }

    @Test func loadLLM() async throws {
        let stats = try await benchmarkLLMLoading(
            from: HFClient.default,
            using: TokenizersLoader()
        )
        stats.printSummary(label: "LLM load (swift-tokenizers)")
    }

    @Test func loadVLM() async throws {
        let stats = try await benchmarkVLMLoading(
            from: HFClient.default,
            using: TokenizersLoader()
        )
        stats.printSummary(label: "VLM load (swift-tokenizers)")
    }

    @Test func loadEmbedding() async throws {
        let stats = try await benchmarkEmbeddingLoading(
            from: HFClient.default,
            using: TokenizersLoader()
        )
        stats.printSummary(label: "Embedding load (swift-tokenizers)")
    }

    @Test func embeddingConvenience() async throws {
        let config = EmbedderRegistry.minilm_l6_4bit
        let hub = HFClient.default

        // Free function loadModelContainer (downloader, default TokenizersLoader)
        let container = try await MLXEmbeddersTokenizers.loadModelContainer(
            from: hub, configuration: config)
        let modelDirectory = try await container.modelDirectory

        // Free function loadModel (downloader)
        _ = try await MLXEmbeddersTokenizers.loadModel(
            from: hub, configuration: config)

        // Free function loadModelContainer (directory)
        _ = try await MLXEmbeddersTokenizers.loadModelContainer(from: modelDirectory)

        // Free function loadModel (directory)
        _ = try await MLXEmbeddersTokenizers.loadModel(from: modelDirectory)

        // EmbedderModelFactory extension loadContainer (downloader, default TokenizersLoader)
        _ = try await EmbedderModelFactory.shared.loadContainer(
            from: hub, configuration: config)

        // EmbedderModelFactory extension load (downloader)
        _ = try await EmbedderModelFactory.shared.load(
            from: hub, configuration: config)

        // EmbedderModelFactory extension loadContainer (directory)
        _ = try await EmbedderModelFactory.shared.loadContainer(from: modelDirectory)

        // EmbedderModelFactory extension load (directory)
        _ = try await EmbedderModelFactory.shared.load(from: modelDirectory)
    }
}
