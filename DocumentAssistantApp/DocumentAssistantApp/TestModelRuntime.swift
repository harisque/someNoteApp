import SwiftUI
import Combine
import OSLog
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers

/// One performance sample captured from MLX's terminal `.info(GenerateCompletionInfo)`.
/// Prefill time is the model's `promptTime` (time to first token); decode throughput
/// is `tokensPerSecond` over the generation phase.
struct GenerationMetrics: Codable, Equatable {
    let promptTokens: Int
    let outputTokens: Int
    let prefillSeconds: Double
    let decodeSeconds: Double
    let decodeTokensPerSecond: Double
    let promptTokensPerSecond: Double

    init(
        promptTokens: Int,
        outputTokens: Int,
        prefillSeconds: Double,
        decodeSeconds: Double,
        decodeTokensPerSecond: Double,
        promptTokensPerSecond: Double
    ) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.prefillSeconds = prefillSeconds
        self.decodeSeconds = decodeSeconds
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.promptTokensPerSecond = promptTokensPerSecond
    }

    init(info: GenerateCompletionInfo) {
        self.init(
            promptTokens: info.promptTokenCount,
            outputTokens: info.generationTokenCount,
            prefillSeconds: info.promptTime,
            decodeSeconds: info.generateTime,
            decodeTokensPerSecond: info.tokensPerSecond,
            promptTokensPerSecond: info.promptTokensPerSecond
        )
    }
}

/// Events emitted by ``TestModelRuntime/stream(prompt:)``: streamed answer text
/// followed by a single terminal metrics sample.
enum TestEvent {
    case token(String)
    case metrics(GenerationMetrics)
}

/// A dedicated, runtime-configurable inference runtime for the hidden Test Mode.
///
/// Fully isolated from the normal document-assistant path: it owns its own
/// `ModelContainer`, its config is mutable (persisted to `UserDefaults`, never
/// written back to the bundled `ModelConfig.json`), and it can switch between the
/// bundled models at runtime. Prompts go straight to the model (no retrieval), and
/// generation reports native MLX metrics.
@MainActor
final class TestModelRuntime: ObservableObject {
    // MARK: Config (persisted; independent of bundled ModelConfig.json)

    @Published var model: BundledModel {
        didSet { if oldValue != model { unload() }; persist() }
    }
    @Published var contextWindowTokens: Int { didSet { persist() } }
    @Published var maxOutputTokens: Int { didSet { persist() } }
    @Published var temperature: Float { didSet { persist() } }
    /// When true, the model reasons inside a `<think>` block before answering
    /// (better for math/code, but slower and uses more of the output budget).
    /// Honored by both bundled models' chat templates. Off by default so Test Mode
    /// matches normal mode until you opt in.
    @Published var enableThinking: Bool { didSet { persist() } }

    private var container: ModelContainer?
    private var isGenerating = false
    private let logger = Logger(subsystem: "com.sc.boardiq", category: "TestMode")

    private enum Keys {
        static let model = "TestMode.model"
        static let contextWindow = "TestMode.contextWindowTokens"
        static let maxOutput = "TestMode.maxOutputTokens"
        static let temperature = "TestMode.temperature"
        static let enableThinking = "TestMode.enableThinking"
    }

    init(seedConfig: ModelConfig) {
        let defaults = UserDefaults.standard
        let rawModel = defaults.string(forKey: Keys.model) ?? seedConfig.activeModel.rawValue
        self.model = BundledModel(rawValue: rawModel) ?? seedConfig.activeModel
        self.contextWindowTokens = defaults.object(forKey: Keys.contextWindow) as? Int ?? seedConfig.contextWindowTokens
        self.maxOutputTokens = defaults.object(forKey: Keys.maxOutput) as? Int ?? seedConfig.maxOutputTokens
        self.temperature = defaults.object(forKey: Keys.temperature) as? Float ?? seedConfig.temperature
        self.enableThinking = defaults.object(forKey: Keys.enableThinking) as? Bool ?? false
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(model.rawValue, forKey: Keys.model)
        defaults.set(contextWindowTokens, forKey: Keys.contextWindow)
        defaults.set(maxOutputTokens, forKey: Keys.maxOutput)
        defaults.set(temperature, forKey: Keys.temperature)
        defaults.set(enableThinking, forKey: Keys.enableThinking)
    }

    private var directory: URL {
        Bundle.main.bundleURL.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    /// Releases the loaded model so only one container is resident at a time.
    func unload() {
        guard container != nil else { return }
        container = nil
        #if !targetEnvironment(simulator)
        MLX.Memory.clearCache()
        #endif
        logger.notice("Test model unloaded")
        print("[TestMode] Unloaded model container")
    }

    private func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        let dir = directory
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) else {
                throw NSError(domain: "DocumentAssistant.TestMode", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Model file missing: \(file) in \(dir.lastPathComponent)."
                ])
            }
        }
        #if targetEnvironment(simulator)
        // This MLX build aborts in Metal Device::Device() on the simulator; a Swift
        // catch cannot intercept SIGABRT, so refuse before entering C++.
        throw NSError(domain: "DocumentAssistant.TestMode", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "On-device generation is unavailable in the iOS Simulator (Metal init aborts). Run on a physical device."
        ])
        #else
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        print("[TestMode] Loading model: \(dir.lastPathComponent)")
        logger.error("Loading test model \(dir.lastPathComponent, privacy: .public)")
        let started = Date()
        let loaded = try await withThrowingTaskGroup(of: ModelContainer.self) { group in
            group.addTask { try await LLMModelFactory.shared.loadContainer(from: dir, using: TokenizersLoader()) }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw NSError(domain: "DocumentAssistant.TestMode", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Model loading exceeded 3 minutes. Check available storage/memory, then retry."
                ])
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
        container = loaded
        let elapsed = Date().timeIntervalSince(started)
        print("[TestMode] Model loaded in \(elapsed)s")
        logger.notice("Test model loaded in \(elapsed) seconds")
        return loaded
        #endif
    }

    /// Streams the raw prompt directly to the model (no retrieval), yielding text
    /// chunks followed by a single terminal ``TestEvent/metrics(_:)`` sample.
    func stream(prompt: String) -> AsyncThrowingStream<TestEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard !isGenerating else {
                    continuation.finish(throwing: NSError(domain: "DocumentAssistant.TestMode", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "A test response is already running. Wait for it to finish."
                    ]))
                    return
                }
                isGenerating = true
                defer {
                    isGenerating = false
                    #if !targetEnvironment(simulator)
                    MLX.Memory.clearCache()
                    logger.notice("Test MLX active bytes: \(MLX.Memory.activeMemory); peak bytes: \(MLX.Memory.peakMemory)")
                    #endif
                }
                do {
                    let loaded = try await ensureLoaded()
                    try Task.checkCancellation()
                    let input = try await loaded.prepare(input: UserInput(
                        prompt: prompt, additionalContext: ["enable_thinking": enableThinking]
                    ))
                    let tokenCount = input.text.tokens.size
                    guard tokenCount <= contextWindowTokens else {
                        throw NSError(domain: "DocumentAssistant.TestMode", code: 5, userInfo: [
                            NSLocalizedDescriptionKey: "Prompt is \(tokenCount) tokens, over the \(contextWindowTokens)-token test limit. Raise the context window or shorten the prompt."
                        ])
                    }
                    let started = Date()
                    let generations = try await loaded.generate(
                        input: input,
                        parameters: GenerateParameters(maxTokens: maxOutputTokens, temperature: temperature, prefillStepSize: 128)
                    )
                    var sawMetrics = false
                    for await generation in generations {
                        try Task.checkCancellation()
                        switch generation {
                        case .chunk(let text):
                            if !text.isEmpty { continuation.yield(.token(text)) }
                        case .info(let info):
                            sawMetrics = true
                            continuation.yield(.metrics(GenerationMetrics(info: info)))
                        case .toolCall:
                            break
                        }
                    }
                    if !sawMetrics {
                        continuation.yield(.metrics(GenerationMetrics(
                            promptTokens: tokenCount, outputTokens: 0,
                            prefillSeconds: Date().timeIntervalSince(started), decodeSeconds: 0,
                            decodeTokensPerSecond: 0, promptTokensPerSecond: 0
                        )))
                    }
                    continuation.finish()
                } catch {
                    logger.error("Test inference ended: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
