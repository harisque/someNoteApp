import SwiftUI
import OSLog

/// Namespace for the hidden Test Mode entry point.
enum TestMode {
    /// Typing exactly this in the Ask bar (trimmed) unlocks Test Mode instead of
    /// submitting a question. Kept obscure so it never collides with real queries.
    static let triggerPhrase = "/***test1357"
}

/// Coordinates the normal-mode model and the dedicated Test Mode runtime so that
/// only one model container is resident at a time.
///
/// Entering Test Mode offloads the normal model to free RAM; exiting unloads the
/// test model and warms the normal model back up in the background so document
/// Q&A is ready again.
@MainActor
final class ModelCoordinator {
    let normalModel: QwenMLXLanguageModel
    let test: TestModelRuntime
    /// Test Mode's own history, kept separate from the normal document catalog.
    /// Owned here (not in the view) so it survives entering/exiting Test Mode.
    let history = TestHistoryStore()

    private let logger = Logger(subsystem: "com.sc.boardiq", category: "TestMode")

    init(normalModel: QwenMLXLanguageModel, bundledConfig: ModelConfig) {
        self.normalModel = normalModel
        self.test = TestModelRuntime(seedConfig: bundledConfig)
    }

    /// Frees the normal-mode model before Test Mode loads its own.
    func enterTestMode() {
        logger.notice("Entering Test Mode: offloading normal model")
        print("[TestMode] Enter: offloading normal-mode model")
        normalModel.unload()
    }

    /// Frees the test model and reloads the normal model in the background.
    func exitTestMode() {
        logger.notice("Exiting Test Mode: unloading test model, warming normal model")
        print("[TestMode] Exit: unloading test model, reloading normal model")
        test.unload()
        let normal = normalModel
        Task { @MainActor in
            await normal.warmUp()
        }
    }
}
