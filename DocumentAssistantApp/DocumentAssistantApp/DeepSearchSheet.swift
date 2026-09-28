import SwiftUI
import DocumentAssistant

/// An Identifiable wrapper so the deep-search sheet can be presented via
/// `.sheet(item:)`, mirroring `FactCheckRequest`.
struct DeepSearchRequest: Identifiable {
    let id = UUID()
    let text: String
}

/// The standard floating "Deep Search" pill shown over a reader when text is
/// selected. Styled identically to `FactCheckButton` so the two sit side by
/// side as one affordance family. Unlike Fact Check, Deep Search is offered on
/// every document: it only reads the on-device index.
struct DeepSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Deep Search", systemImage: "text.magnifyingglass")
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

/// Cross-document deep search results: exact occurrence counts per document
/// with tappable links into each passage, plus semantically similar passages
/// found with the on-device embedding model. Tapping a result navigates the
/// host to that exact location via `onOpenCitation` **without dismissing** —
/// the results stay open so the user can step through multiple hits; Close
/// reveals the last opened passage.
struct DeepSearchSheet: View {
    let query: String
    let assistant: DocumentAssistant
    var onOpenCitation: ((Citation) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var result: DeepSearchResult?
    @State private var indexing: (done: Int, total: Int)?
    @State private var errorMessage: String?
    @State private var expandedDocs: Set<UUID> = []
    /// The last tapped citation, re-delivered on dismiss as a safety net: on
    /// compact layout the push may be queued behind the sheet and only applied
    /// once it closes. Re-delivery is idempotent (the host just re-sets the
    /// same navigation state).
    @State private var pendingCitation: Citation?

    private var isRunning: Bool { result == nil && errorMessage == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    queryBlock

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

                    if let result {
                        occurrencesBlock(result)
                        semanticBlock(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Deep Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await run() }
        .onDisappear {
            if let citation = pendingCitation { onOpenCitation?(citation) }
        }
    }

    // MARK: - Blocks

    private var queryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUERY").font(.caption2).foregroundStyle(.secondary)
            Text(query)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color("SCBlue").opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var stageLabel: String {
        if let indexing {
            return "Building semantic index… \(indexing.done)/\(indexing.total)"
        }
        return "Searching all documents…"
    }

    // MARK: - Results

    @ViewBuilder private func occurrencesBlock(_ result: DeepSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OCCURRENCES").font(.caption2).foregroundStyle(.secondary)
            Text(result.totalOccurrences == 0
                 ? "No exact matches in any document."
                 : "\(result.totalOccurrences) match\(result.totalOccurrences == 1 ? "" : "es") across \(result.groups.count) document\(result.groups.count == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(result.groups) { group in
                documentCard(group)
            }
        }
    }

    /// One collapsible card per document: name + exact count, expanding to the
    /// matched passages (capped for display; the count is always exact).
    @ViewBuilder private func documentCard(_ group: DocumentOccurrences) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedDocs.contains(group.documentID) { expandedDocs.remove(group.documentID) }
                    else { expandedDocs.insert(group.documentID) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.subheadline).foregroundStyle(Color("SCBlue"))
                    Text(group.documentName).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(group.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color("SCBlue").opacity(0.15), in: Capsule())
                        .foregroundStyle(Color("SCBlue"))
                    Image(systemName: expandedDocs.contains(group.documentID) ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedDocs.contains(group.documentID) {
                Divider().padding(.horizontal, 10)
                ForEach(group.occurrences) { occurrence in
                    Button { open(occurrence.citation) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(occurrence.snippet)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let page = occurrence.citation.page {
                                Text("Page \(page)").font(.caption2).foregroundStyle(Color("SCBlue"))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.horizontal, 10)
                }
                if group.count > group.occurrences.count {
                    Text("Showing first \(group.occurrences.count) of \(group.count) matches")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func semanticBlock(_ result: DeepSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIMILAR PASSAGES").font(.caption2).foregroundStyle(.secondary)
            if !result.semanticAvailable {
                Text("Semantic matching is unavailable on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if result.semanticMatches.isEmpty {
                Text("No similar passages above the relevance threshold.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Passages with similar meaning, not necessarily the same words.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(result.semanticMatches, id: \.citation.id) { passage in
                    Button { open(passage.citation) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(Int((passage.score * 100).rounded()))%")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color("SCBlue").opacity(0.15), in: Capsule())
                                .foregroundStyle(Color("SCBlue"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(passage.text)
                                    .font(.caption)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(sourceLabel(passage.citation))
                                    .font(.caption2).foregroundStyle(Color("SCBlue"))
                                    .lineLimit(1)
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sourceLabel(_ citation: Citation) -> String {
        var label = citation.document
        if let page = citation.page { label += ", page \(page)" }
        return label
    }

    // MARK: - Actions

    /// Navigates the host to the tapped citation immediately and keeps the
    /// sheet open, so the result list survives browsing into a hit (the detail
    /// pane swaps behind the sheet; Close reveals it).
    private func open(_ citation: Citation) {
        pendingCitation = citation
        onOpenCitation?(citation)
    }

    private func run() async {
        indexing = nil
        result = await assistant.deepSearch(query) { done, total in
            Task { @MainActor in indexing = (done, total) }
        }
        indexing = nil
    }
}
