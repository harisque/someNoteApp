import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXLMTokenizers
import DocumentAssistant
import OSLog

/// On-device embedding model powering Deep Search's semantic pass.
///
/// This is an `actor`, not `@MainActor`: a first-run index build embeds every
/// chunk back-to-back, and scheduling that on the main actor starves the UI and
/// concentrates memory pressure on the main thread. `EmbedderModelContainer` is
/// `Sendable` and serializes model access internally, so nothing is lost by
/// running off-main.
actor QwenEmbeddingModel: DocumentEmbedder {
    private let directory: URL
    private var container: EmbedderModelContainer?
    /// In-flight container load, so a launch-time `preload()` and a query that
    /// arrives while it's still loading share ONE load instead of each
    /// allocating the 320 MB model (a double load can spike memory enough to be
    /// jetsam-killed on device).
    private var loadTask: Task<EmbedderModelContainer, any Error>?
    /// Embeds since the last MLX cache clear. Long index builds accumulate
    /// Metal buffers in the global cache; clearing periodically keeps the
    /// working set flat so the app isn't jetsam-killed mid-build on device.
    private var embedsSinceClear = 0
    private let logger = Logger(subsystem: "com.sc.boardiq", category: "Embedding")
    init(directory: URL) { self.directory = directory }
    private func loaded() async throws -> EmbedderModelContainer {
        if let container { return container }
        // Share one load across concurrent callers (launch preload + a query that
        // arrives mid-load) so the 320 MB model is allocated once, not twice.
        if let loadTask { return try await loadTask.value }
        #if targetEnvironment(simulator)
        // Same MLX/Metal limitation as the language model: this build aborts in
        // Metal Device::Device() on the simulator, and a Swift catch does not
        // intercept SIGABRT. Check before entering C++. Deep Search degrades to
        // literal occurrences only when embedding is unavailable.
        throw NSError(domain: "DocumentAssistant.Embedder", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "On-device embedding is unavailable in the iOS Simulator. Deep Search returns exact occurrences only."
        ])
        #else
        // Cap the shared MLX Metal buffer cache before allocating weights. The
        // LLM sets the same limit, but only when it loads first; a deep search
        // before any Ask would otherwise run with the (large) default.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let task = Task<EmbedderModelContainer, any Error> { [directory, logger] in
            logger.error("Loading embedding model from \(directory.path, privacy: .public)")
            print("[Embedding] Loading model from \(directory.path)")
            let started = Date()
            do {
                let value = try await EmbedderModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
                logger.error("Embedding model loaded in \(Date().timeIntervalSince(started)) seconds")
                print("[Embedding] Model loaded")
                return value
            } catch {
                logger.error("[Embedding] loadContainer FAILED after \(Date().timeIntervalSince(started))s: \(error.localizedDescription, privacy: .public)")
                print("[Embedding] loadContainer FAILED: \(error)")
                throw error
            }
        }
        loadTask = task
        do {
            let value = try await task.value
            container = value
            loadTask = nil
            return value
        } catch {
            loadTask = nil
            throw error
        }
        #endif
    }
    /// Loads the model container now, off the query path, so Ask's query-vector
    /// embed — which runs under a short timeout — finds the model already
    /// resident instead of cold-loading and being cancelled by that timeout
    /// (which degraded every question to keyword-only).
    func preload() async {
        #if !targetEnvironment(simulator)
        do {
            _ = try await loaded()
            logger.error("[Embedding] preload: model resident")
        } catch {
            logger.error("[Embedding] preload FAILED: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
    func embed(_ text: String) async throws -> [Float] {
        let model = try await loaded()
        logger.error("Embedding chunk (\(text.count) characters)")
        print("[Embedding] Chunk \(text.count) characters")
        let result = try await model.perform { context in
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
        #if !targetEnvironment(simulator)
        embedsSinceClear += 1
        if embedsSinceClear >= 16 {
            MLX.Memory.clearCache()
            embedsSinceClear = 0
            logger.notice("MLX cache cleared during embedding; active bytes: \(MLX.Memory.activeMemory)")
        }
        #endif
        return result
    }
}
