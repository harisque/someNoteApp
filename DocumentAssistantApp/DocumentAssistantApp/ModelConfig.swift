import Foundation

/// Which bundled model the assistant loads. The raw value is the model's folder
/// name inside the app bundle. Both folders stay bundled in Phase 1, so either
/// case can be selected from `ModelConfig.json` with no project change.
enum BundledModel: String, CaseIterable, Identifiable {
    case qwen = "Qwen3.5-4B"
    case miniCPM5 = "miniCPM5_2B_MLX"

    var id: String { rawValue }

    /// Human-readable label for pickers and metrics.
    var displayName: String {
        switch self {
        case .qwen: return "Qwen3.5-4B"
        case .miniCPM5: return "MiniCPM5-2B"
        }
    }
}

/// Runtime-tunable inference settings loaded from the bundled `ModelConfig.json`.
///
/// Edit that file in the Xcode project and rebuild (Command+R) to apply changes.
/// Any missing or undecodable key falls back to ``defaults``, and every value is
/// clamped to a safe range so a stray edit cannot crash generation.
struct ModelConfig: Decodable {
    /// Folder name of the model to load (see ``BundledModel``).
    let activeModel: BundledModel
    /// Maximum prompt tokens accepted before generation is refused. The real
    /// ceiling is device RAM (KV cache grows with context), not the model's
    /// nominal context length, so raise it gradually and watch for memory pressure.
    let contextWindowTokens: Int
    /// Maximum tokens the model may generate for a single answer.
    let maxOutputTokens: Int
    /// Sampling temperature (0 = deterministic, higher = more random).
    let temperature: Float

    private enum CodingKeys: String, CodingKey {
        case activeModel, contextWindowTokens, maxOutputTokens, temperature
    }

    /// Values used when `ModelConfig.json` is absent or a key is missing/invalid.
    static let defaults = ModelConfig(
        activeModel: .miniCPM5,
        contextWindowTokens: 4096,
        maxOutputTokens: 256,
        temperature: 0.7
    )

    init(activeModel: BundledModel, contextWindowTokens: Int, maxOutputTokens: Int, temperature: Float) {
        self.activeModel = activeModel
        self.contextWindowTokens = min(max(contextWindowTokens, 512), 131_072)
        self.maxOutputTokens = min(max(maxOutputTokens, 1), 8_192)
        self.temperature = min(max(temperature, 0.0), 2.0)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        let rawModel = try container.decodeIfPresent(String.self, forKey: .activeModel) ?? fallback.activeModel.rawValue
        self.init(
            activeModel: BundledModel(rawValue: rawModel) ?? fallback.activeModel,
            contextWindowTokens: try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? fallback.contextWindowTokens,
            maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? fallback.maxOutputTokens,
            temperature: try container.decodeIfPresent(Float.self, forKey: .temperature) ?? fallback.temperature
        )
    }

    /// Loads `ModelConfig.json` from the app bundle, returning ``defaults`` if the
    /// file is missing or cannot be decoded.
    static func loadFromBundle() -> ModelConfig {
        guard
            let url = Bundle.main.url(forResource: "ModelConfig", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(ModelConfig.self, from: data)
        else {
            return .defaults
        }
        return config
    }
}
