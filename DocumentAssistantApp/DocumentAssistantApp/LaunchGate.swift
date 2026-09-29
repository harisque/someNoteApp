import SwiftUI
import Observation

/// Observable state for the launch gate. `ContentView` drives it during
/// bootstrap: seeding flips ``isPreparing`` off, the embedding poll fills
/// ``totalChunks``/``embeddedChunks``/``embeddingSettled``, and the chat-model
/// load mirrors into ``modelState``. The gate opens (``isReady``) only once the
/// library has finished embedding AND the model requirement is satisfied, so the
/// app is never interactive before on-device AI is warm.
@Observable
@MainActor
final class LaunchGate {
    /// Seeding Confidential/Data Links and loading the catalog.
    var isPreparing = true
    /// Whole-library chunk totals, refreshed by the embedding poll.
    var totalChunks = 0
    var embeddedChunks = 0
    /// True once every background embedding job has finished.
    var embeddingSettled = false
    /// Chat-model lifecycle, mirrored from `QwenMLXLanguageModel.loadState`.
    var modelState: ModelLoadState = .idle
    /// False on the Simulator, where MLX inference is unavailable.
    var modelRequired = true
    /// Set by "Enter anyway" so a failed/absent model can't lock the user out.
    var enteredManually = false

    var embeddingFraction: Double {
        guard totalChunks > 0 else { return embeddingSettled ? 1 : 0 }
        return Double(min(embeddedChunks, totalChunks)) / Double(totalChunks)
    }
    var modelSatisfied: Bool { !modelRequired || modelState == .ready || enteredManually }
    var isReady: Bool { !isPreparing && embeddingSettled && modelSatisfied }
    var modelFailure: String? {
        if case .failed(let message) = modelState { return message }
        return nil
    }
}

/// Full-screen, non-interactive cover shown until ``LaunchGate/isReady``. It
/// surfaces embedding progress and the on-device model start so the user always
/// knows why entry is blocked, and offers Retry / Enter anyway if the model
/// cannot load (Simulator, missing files, or a jetsam kill mid-load).
struct LaunchGateView: View {
    let gate: LaunchGate
    var onRetry: () -> Void
    var onEnterAnyway: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Image("SCLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 96)
                Text("BoardIQ")
                    .font(.largeTitle.bold())
                Text("Preparing your documents")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                embeddingRow
                Divider()
                modelRow
            }
            .padding(20)
            .frame(maxWidth: 460)
            .background(
                Color("SCBlue").opacity(0.08),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )

            if let failure = gate.modelFailure {
                failureBox(failure)
            }

            Spacer()

            Text("Everything runs on-device. Nothing leaves your iPad.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Rows

    private var embeddingRow: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: gate.embeddingSettled, active: !gate.isPreparing && !gate.embeddingSettled)
            VStack(alignment: .leading, spacing: 6) {
                Text(embeddingTitle)
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: gate.embeddingFraction)
                    .progressViewStyle(.linear)
                    .tint(Color("SCBlue"))
                Text(embeddingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var embeddingTitle: String {
        if gate.isPreparing { return "Preparing library…" }
        if gate.embeddingSettled { return "Documents indexed" }
        if gate.totalChunks > 0 && gate.embeddedChunks == 0 { return "Loading embedding model…" }
        return "Embedding documents…"
    }

    private var embeddingDetail: String {
        if gate.isPreparing { return "Loading your catalog" }
        if gate.embeddingSettled {
            return gate.totalChunks == 0
                ? "No documents to index yet"
                : "\(gate.totalChunks) passage\(gate.totalChunks == 1 ? "" : "s") ready"
        }
        if gate.totalChunks > 0 && gate.embeddedChunks == 0 {
            return "Warming up the on-device embedder"
        }
        return "\(gate.embeddedChunks) of \(gate.totalChunks) passage\(gate.totalChunks == 1 ? "" : "s") indexed"
    }

    private var modelRow: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: gate.modelState == .ready || !gate.modelRequired,
                       active: gate.modelRequired && (gate.modelState == .loading || gate.modelState == .idle),
                       failed: gate.modelFailure != nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(modelTitle)
                    .font(.subheadline.weight(.semibold))
                Text(modelDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelTitle: String {
        if !gate.modelRequired { return "Model skipped (Simulator)" }
        switch gate.modelState {
        case .ready: return "Model ready"
        case .failed: return "Model couldn't start"
        case .idle, .loading: return "Starting on-device model…"
        }
    }

    private var modelDetail: String {
        if !gate.modelRequired { return "On-device inference needs a physical device" }
        switch gate.modelState {
        case .ready: return "On-device AI is warm"
        case .failed: return "See the message below"
        case .idle, .loading: return "Loading the language model into memory"
        }
    }

    // MARK: - Failure

    private func failureBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Model couldn't start", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("SCBlue"))
                Button(action: onEnterAnyway) {
                    Text("Enter anyway").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

/// Small leading glyph for a gate row: a spinner while active, a green check when
/// done, an orange warning on failure, and a faint circle when idle/queued.
private struct StatusIcon: View {
    let done: Bool
    var active: Bool = false
    var failed: Bool = false

    init(done: Bool, active: Bool = false, failed: Bool = false) {
        self.done = done
        self.active = active
        self.failed = failed
    }

    var body: some View {
        Group {
            if failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color("SCGreen"))
            } else if active {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "circle").foregroundStyle(.quaternary)
            }
        }
        .font(.title3)
        .frame(width: 24, height: 24)
    }
}
