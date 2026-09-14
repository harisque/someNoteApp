import SwiftUI
import DocumentAssistant

/// The standard floating "Fact Check" pill shown over a reader when text is
/// selected in a personal document. Shared by the document reader and the note
/// preview so the affordance looks identical everywhere.
struct FactCheckButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Fact Check", systemImage: "checkmark.seal.text")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color("SCBlue"), in: Capsule())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .padding(.bottom, 28)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Presents a fact check for a selected claim: a progress indicator while the web
/// search and on-device analysis run, then the streamed verdict (rendered as
/// markdown) and the sources it was based on. The run is cancelled automatically
/// when the sheet is dismissed.
struct FactCheckSheet: View {
    let claim: String
    let assistant: DocumentAssistant

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var stage: FactCheckStage = .searchingWeb
    @State private var verdict = ""
    @State private var sources: [WebResult] = []
    @State private var errorMessage: String?

    private var isRunning: Bool { stage != .finished && errorMessage == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    claimBlock

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(stageLabel).font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    if !verdict.isEmpty {
                        MarkdownAnswerView(text: verdict)
                    }

                    if !sources.isEmpty {
                        sourcesBlock
                    }
                }
                .padding()
            }
            .navigationTitle("Fact Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isRunning)
        .task { await run() }
    }

    // MARK: - Blocks

    private var claimBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAIM").font(.caption2).foregroundStyle(.secondary)
            Text(claim)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color("SCBlue").opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var stageLabel: String {
        switch stage {
        case .searchingWeb: return "Searching the web…"
        case .analyzing: return "Analyzing with on-device AI…"
        case .generating: return verdict.isEmpty ? "Starting on-device model…" : "Writing verdict…"
        case .finished: return "Done"
        }
    }

    private var sourcesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Button {
                    if let url = URL(string: source.url) { openURL(url) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(index + 1)]").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title).font(.subheadline).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !source.snippet.isEmpty {
                                Text(source.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text(source.url).font(.caption2).foregroundStyle(Color("SCBlue"))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Run

    private func run() async {
        let service = FactCheckService(assistant: assistant)
        do {
            for try await event in service.stream(claim: claim) {
                switch event {
                case .stage(let value): stage = value
                case .sources(let value): sources = value
                case .token(let value): verdict += value
                }
            }
        } catch is CancellationError {
            // Dismissed mid-run; nothing to surface.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
