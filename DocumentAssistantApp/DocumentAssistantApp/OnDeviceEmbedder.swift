import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXLMTokenizers
import DocumentAssistant
import OSLog

@MainActor
final class QwenEmbeddingModel: DocumentEmbedder {
    private let directory: URL
    private var container: EmbedderModelContainer?
    private let logger = Logger(subsystem: "com.localtest.DocumentAssistantApp", category: "Embedding")
    init(directory: URL) { self.directory = directory }
    private func loaded() async throws -> EmbedderModelContainer {
        if let container { return container }
        logger.error("Loading embedding model from \(self.directory.path, privacy: .public)")
        print("[Embedding] Loading model from \(self.directory.path)")
        let started = Date()
        let value = try await EmbedderModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
        container = value
        logger.error("Embedding model loaded in \(Date().timeIntervalSince(started)) seconds")
        print("[Embedding] Model loaded")
        return value
    }
    func embed(_ text: String) async throws -> [Float] {
        let model = try await loaded()
        logger.error("Embedding chunk (\(text.count) characters)")
        print("[Embedding] Chunk \(text.count) characters")
        return try await model.perform { context in
            let tokenizer = context.tokenizer
            let ids = tokenizer.encode(text: String(text.prefix(1200)), addSpecialTokens: true)
            let length = min(max(ids.count, 8), 512)
            let padded = ids.prefix(length) + Array(repeating: tokenizer.eosTokenId ?? 0, count: max(0, length - ids.count))
            let input = MLXArray(Array(padded))
            let mask = input .!= (tokenizer.eosTokenId ?? 0)
            let types = MLXArray.zeros(like: input)
            let output = context.pooling(context.model(input[.newAxis, .ellipsis], positionIds: nil, tokenTypeIds: types[.newAxis, .ellipsis], attentionMask: mask[.newAxis, .ellipsis]), normalize: true, applyLayerNorm: true)
            output.eval()
            return output[0].asArray(Float.self)
        }
    }
}
