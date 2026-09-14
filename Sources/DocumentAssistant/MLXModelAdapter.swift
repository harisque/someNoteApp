import Foundation

/// Serializes generation requests because MLX GPU work must not overlap.
public actor MLXGenerationGate {
    private var busy = false
    public init() {}
    public func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        while busy { await Task.yield() }
        busy = true
        defer { busy = false }
        return try await operation()
    }
}

public struct ModelStatus: Sendable, Equatable {
    public var name: String
    public var loaded: Bool
    public var memoryMB: Int
    public init(name: String, loaded: Bool = false, memoryMB: Int = 0) { self.name = name; self.loaded = loaded; self.memoryMB = memoryMB }
}

/// Adapter seam for the upstream MLX Swift runtime. Implement `generate` with
/// the selected MLX model's token stream; lifecycle and serialization stay here.
@available(macOS 10.15, iOS 13.0, *)
public final class MLXLanguageModel: LanguageModel, @unchecked Sendable {
    private let gate = MLXGenerationGate()
    public private(set) var status: ModelStatus
    private let generate: @Sendable (String) -> AsyncThrowingStream<String, Error>
    public init(name: String = "MODEL_NAME", generate: @escaping @Sendable (String) -> AsyncThrowingStream<String, Error>) {
        status = ModelStatus(name: name)
        self.generate = generate
    }
    public func load() async { status.loaded = true }
    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { for try await token in await gate.run({ generate(prompt) }) { try Task.checkCancellation(); continuation.yield(token) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct GenerationMetrics: Sendable, Equatable {
    public let loadTime: TimeInterval
    public let firstTokenLatency: TimeInterval?
    public let tokensPerSecond: Double?
    public init(loadTime: TimeInterval = 0, firstTokenLatency: TimeInterval? = nil, tokensPerSecond: Double? = nil) { self.loadTime = loadTime; self.firstTokenLatency = firstTokenLatency; self.tokensPerSecond = tokensPerSecond }
}
