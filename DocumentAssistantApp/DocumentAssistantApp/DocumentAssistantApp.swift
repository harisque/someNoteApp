import SwiftUI
import OSLog
import DocumentAssistant
import protocol DocumentAssistant.LanguageModel
import MLX
import MLXLLM
import MLXEmbedders
import MLXVLM
import MLXLMCommon
import MLXLMTokenizers

@MainActor
final class QwenMLXLanguageModel: LanguageModel {
    private let directory: URL
    private let contextWindowTokens: Int
    private let maxOutputTokens: Int
    private let temperature: Float
    private var container: ModelContainer?
    private var isGenerating = false
    private let logger = Logger(subsystem: "com.localtest.DocumentAssistantApp", category: "Inference")

    init(directory: URL, config: ModelConfig) {
        self.directory = directory
        self.contextWindowTokens = config.contextWindowTokens
        self.maxOutputTokens = config.maxOutputTokens
        self.temperature = config.temperature
    }

    private func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                throw NSError(domain: "DocumentAssistant.Model", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Qwen model file missing: \(file). Rebuild the app with the Qwen3.5-4B resource folder."
                ])
            }
        }
        #if targetEnvironment(simulator)
        // This MLX version aborts in Metal Device::Device() on the tested simulator.
        // Check before entering C++: a Swift catch does not intercept SIGABRT.
        throw NSError(domain: "DocumentAssistant.Model", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Qwen files are present. This MLX build crashes during Metal initialization in the iOS Simulator. Run on a physical iPhone for on-device generation. Document import and browsing remain available here."
        ])
        #else
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        logger.error("Loading bundled model \(self.directory.lastPathComponent, privacy: .public) (text LLM factory)")
        print("[LLM] Loading bundled model: \(directory.lastPathComponent)")
        print("[LLM] Config: contextWindow=\(contextWindowTokens) maxOutput=\(maxOutputTokens) temperature=\(temperature)")
        let started = Date()
        let loaded = try await withThrowingTaskGroup(of: ModelContainer.self) { group in
            group.addTask { try await LLMModelFactory.shared.loadContainer(from: self.directory, using: TokenizersLoader()) }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw NSError(domain: "DocumentAssistant.Model", code: 6, userInfo: [NSLocalizedDescriptionKey: "Qwen model loading exceeded 3 minutes. Check available iPad storage and memory, then retry."])
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
        container = loaded
        logger.error("Model \(self.directory.lastPathComponent, privacy: .public) loaded in \(Date().timeIntervalSince(started)) seconds")
        print("[LLM] Model loaded")
        return loaded
        #endif
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            print("[LLM] stream() entered")
            logger.error("LLM stream entered")
            let task = Task { @MainActor in
                guard !isGenerating else {
                    continuation.finish(throwing: NSError(domain: "DocumentAssistant.Model", code: 4, userInfo: [NSLocalizedDescriptionKey: "A response is already running. Wait for it to finish."]))
                    return
                }
                isGenerating = true
                defer {
                    isGenerating = false
                    #if !targetEnvironment(simulator)
                    MLX.Memory.clearCache()
                    logger.notice("MLX active bytes: \(MLX.Memory.activeMemory); peak bytes: \(MLX.Memory.peakMemory)")
                    #endif
                }
                do {
                    let model = try await ensureLoaded()
                    try Task.checkCancellation()
                    logger.notice("Preparing prompt")
                    let input = try await model.prepare(input: UserInput(
                        prompt: prompt, additionalContext: ["enable_thinking": false]
                    ))
                    let tokenCount = input.text.tokens.size
                    logger.notice("Prepared prompt tokens: \(tokenCount)")
                    guard tokenCount <= contextWindowTokens else {
                        throw NSError(domain: "DocumentAssistant.Model", code: 5, userInfo: [NSLocalizedDescriptionKey: "The selected excerpts exceed the \(contextWindowTokens)-token context limit. Try a more specific question or a shorter document excerpt, or raise contextWindowTokens in ModelConfig.json."])
                    }
                    logger.notice("Starting generation")
                    let started = Date()
                    let generations = try await model.generate(
                        input: input, parameters: GenerateParameters(maxTokens: maxOutputTokens, temperature: temperature, prefillStepSize: 128)
                    )
                    var receivedText = false
                    for await generation in generations {
                        try Task.checkCancellation()
                        if case .chunk(let text) = generation, !text.isEmpty {
                            if !receivedText {
                                logger.notice("First text after \(Date().timeIntervalSince(started)) seconds")
                                receivedText = true
                            }
                            continuation.yield(text)
                        }
                    }
                    try Task.checkCancellation()
                    guard receivedText else {
                        throw NSError(domain: "DocumentAssistant.Model", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "The model finished without returning text. Check the Inference logs."
                        ])
                    }
                    logger.notice("Generation finished")
                    continuation.finish()
                } catch {
                    logger.error("Inference ended: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Releases the loaded container so another model (e.g. Test Mode) can use the
    /// memory. No-op if nothing is loaded or if a generation is in flight.
    func unload() {
        guard !isGenerating, container != nil else { return }
        container = nil
        #if !targetEnvironment(simulator)
        MLX.Memory.clearCache()
        #endif
        logger.notice("Normal model unloaded to free memory")
        print("[LLM] Unloaded model container")
    }

    /// Best-effort warm-up so the first document question after Test Mode is fast.
    /// Never throws: the lazy ``ensureLoaded()`` in ``stream(prompt:)`` still
    /// recovers if this is interrupted or fails.
    func warmUp() async {
        guard !isGenerating else { return }
        _ = try? await ensureLoaded()
    }
}

/// Exact prompt-token counting for the Ask packer, using the bundled LLM's
/// tokenizer. Loads only `tokenizer.json` via swift-tokenizers (no MLX/Metal),
/// so it works before the language model is loaded and never contends for model
/// memory. Returns nil on load failure, degrading packing to the package's
/// conservative character estimate instead of failing the question.
actor QwenTokenCounter: PromptTokenCounter {
    private let directory: URL
    private var tokenizer: (any MLXLMCommon.Tokenizer)?
    private let logger = Logger(subsystem: "com.localtest.DocumentAssistantApp", category: "Inference")
    init(directory: URL) { self.directory = directory }
    func tokenCount(_ text: String) async -> Int? {
        do {
            if tokenizer == nil {
                tokenizer = try await TokenizersLoader().load(from: directory)
            }
            guard let tokenizer else { return nil }
            return tokenizer.encode(text: text, addSpecialTokens: false).count
        } catch {
            logger.error("Token counter unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

@main
struct DocumentAssistantApp: App {
    private let assistant: DocumentAssistant
    private let coordinator: ModelCoordinator
    init() {
        let config = ModelConfig.loadFromBundle()
        let directory = Bundle.main.bundleURL.appendingPathComponent(config.activeModel.rawValue, isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DocumentAssistant", isDirectory: true)
        // One shared normal-mode model, also owned by the coordinator so Test Mode
        // can offload it on enter and warm it back up on exit.
        let normalModel = QwenMLXLanguageModel(directory: directory, config: config)
        // On-device embedder powering Deep Search's semantic pass. The 0.6B 4-bit
        // embedding model is bundled alongside the LLMs and lazily loaded on first
        // use; its small footprint lets it coexist with the active language model.
        let embeddingDirectory = Bundle.main.bundleURL.appendingPathComponent(
            "mlx-community:Qwen3-Embedding-0.6B-4bit-DWQ", isDirectory: true
        )
        assistant = DocumentAssistant(
            model: normalModel,
            store: support.appendingPathComponent("catalog.json"),
            embedder: QwenEmbeddingModel(directory: embeddingDirectory),
            legacyStore: FileManager.default.temporaryDirectory.appendingPathComponent("documents.json"),
            // Link retrieval packing to the configured context window: the excerpt
            // budget is derived from contextWindowTokens minus the reserved answer.
            // Packing measures real tokens with the LLM's tokenizer, so the prompt
            // provably fits the hard context guard instead of trusting a
            // characters-per-token estimate.
            tokenCounter: QwenTokenCounter(directory: directory),
            promptTokenBudget: config.contextWindowTokens,
            reservedAnswerTokens: config.maxOutputTokens
        )
        coordinator = ModelCoordinator(normalModel: normalModel, bundledConfig: config)
    }
    var body: some Scene { WindowGroup { ContentView(assistant: assistant, coordinator: coordinator) } }
}
