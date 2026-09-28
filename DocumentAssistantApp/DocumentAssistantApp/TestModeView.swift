import SwiftUI
import Combine

/// Hidden, full-screen benchmarking surface for the on-device models.
///
/// Prompts are sent straight to the model (no retrieval, no documents). The view
/// lets you switch bundled model, tune inference params, ask a raw question, and
/// read back native MLX metrics (prefill/TTFT, decode TPS, token counts). Runs are
/// saved to Test Mode's own history, fully separate from normal mode.
///
/// Entering offloads the normal-mode model to free RAM; leaving unloads the test
/// model and warms the normal model back up in the background (see ``ModelCoordinator``).
struct TestModeView: View {
    let coordinator: ModelCoordinator

    @ObservedObject private var test: TestModelRuntime
    @ObservedObject private var history: TestHistoryStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var prompt = ""
    @State private var answer = ""
    @State private var metrics: GenerationMetrics?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var streamTask: Task<Void, Never>?

    @State private var showConfig = true
    @State private var expandedRecordID: UUID?
    @State private var compactPane: CompactPane = .run

    private enum CompactPane: String, CaseIterable, Identifiable {
        case run = "Run"
        case history = "History"
        var id: String { rawValue }
    }

    init(coordinator: ModelCoordinator) {
        self.coordinator = coordinator
        self._test = ObservedObject(wrappedValue: coordinator.test)
        self._history = ObservedObject(wrappedValue: coordinator.history)
    }

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    HStack(alignment: .top, spacing: 0) {
                        mainColumn
                            .frame(maxWidth: .infinity)
                        Divider()
                        historyColumn
                            .frame(width: 380)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $compactPane) {
                            ForEach(CompactPane.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        if compactPane == .run { mainColumn } else { historyColumn }
                    }
                }
            }
            .navigationTitle("Test Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { history.clear() } label: {
                        Label("Clear history", systemImage: "trash")
                    }
                    .disabled(history.records.isEmpty)
                }
            }
        }
        .onAppear { coordinator.enterTestMode() }
        .onDisappear {
            streamTask?.cancel()
            coordinator.exitTestMode()
        }
    }

    // MARK: - Main (run) column

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                configPanel
                Divider()
                askPanel
                Divider()
                answerPanel
            }
            .padding()
        }
    }

    private var configPanel: some View {
        DisclosureGroup("Configuration", isExpanded: $showConfig) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Model", selection: $test.model) {
                    ForEach(BundledModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .disabled(isRunning)

                Stepper(value: $test.contextWindowTokens, in: 512...32_768, step: 512) {
                    valueLabel("Context window", "\(test.contextWindowTokens) tok")
                }
                .disabled(isRunning)

                Stepper(value: $test.maxOutputTokens, in: 1...4_096, step: 64) {
                    valueLabel("Max output", "\(test.maxOutputTokens) tok")
                }
                .disabled(isRunning)

                VStack(alignment: .leading, spacing: 4) {
                    valueLabel("Temperature", String(format: "%.2f", test.temperature))
                    Slider(value: $test.temperature, in: 0...2, step: 0.05)
                        .disabled(isRunning)
                }

                Toggle(isOn: $test.enableThinking) {
                    Text("Thinking mode")
                }
                .disabled(isRunning)

                Text("On: the model reasons in a `<think>` block first (better for math/code, slower, uses more of the output budget). Honored by MiniCPM5's chat template.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Switching model reloads the container; changes apply to the next run. Settings persist to this device only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func valueLabel(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var askPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt · sent raw (no retrieval)")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 160)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
                .disabled(isRunning)
            HStack(spacing: 10) {
                Button { runTest() } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isRunning {
                    Button(role: .destructive) { streamTask?.cancel() } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Answer").font(.subheadline.weight(.semibold))
                Spacer()
                if isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(answer.isEmpty ? "Loading model…" : "Generating…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(answer.isEmpty
                 ? (isRunning ? "Loading model and generating…" : "Send a prompt to see the raw model output here.")
                 : answer)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(answer.isEmpty ? Color.secondary : Color.primary)
            if let metrics { metricsPanel(metrics) }
        }
    }

    // MARK: - Metrics

    private func metricsPanel(_ m: GenerationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metrics").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 10) {
                metricCell("Prefill / TTFT", String(format: "%.2f s", m.prefillSeconds))
                metricCell("Decode speed", String(format: "%.1f tok/s", m.decodeTokensPerSecond))
                metricCell("Prompt tokens", "\(m.promptTokens)")
                metricCell("Output tokens", "\(m.outputTokens)")
                metricCell("Prompt speed", String(format: "%.1f tok/s", m.promptTokensPerSecond))
                metricCell("Decode time", String(format: "%.2f s", m.decodeSeconds))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metricCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    // MARK: - History column

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(history.records.count) run(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 8)

            if history.records.isEmpty {
                ContentUnavailableView(
                    "No test runs yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Completed runs are saved here, separate from normal mode.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.records) { record in
                        historyRow(record)
                    }
                    .onDelete { history.delete(at: $0) }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ record: TestRecord) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedRecordID == record.id },
            set: { expandedRecordID = $0 ? record.id : nil }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                labeledBlock("Question", record.question)
                labeledBlock("Answer", record.answer)
                if let m = record.metrics { metricsPanel(m) }
                Text(record.parameterSummary)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.model).font(.caption.weight(.semibold))
                Text(record.question).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: record.date))
                    if let m = record.metrics {
                        Text(String(format: "%.1f tok/s", m.decodeTokensPerSecond))
                        Text(String(format: "%.2fs prefill", m.prefillSeconds))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func labeledBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(body).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Run

    private func runTest() {
        let question = prompt
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isRunning else { return }
        answer = ""
        metrics = nil
        errorMessage = nil
        isRunning = true
        streamTask = Task {
            var collected = ""
            var captured: GenerationMetrics?
            defer {
                isRunning = false
                if !collected.isEmpty {
                    history.append(TestRecord(
                        model: test.model.displayName,
                        contextWindowTokens: test.contextWindowTokens,
                        maxOutputTokens: test.maxOutputTokens,
                        temperature: test.temperature,
                        question: question,
                        answer: collected,
                        metrics: captured,
                        enableThinking: test.enableThinking
                    ))
                }
            }
            do {
                for try await event in test.stream(prompt: question) {
                    try Task.checkCancellation()
                    switch event {
                    case .token(let text):
                        collected += text
                        answer = collected
                    case .metrics(let m):
                        captured = m
                        metrics = m
                    }
                }
            } catch is CancellationError {
                // Keep any partial answer/metrics; the defer block persists them.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
