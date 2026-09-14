import SwiftUI
import DocumentAssistant

/// Read-only detail view for a Confidential Data Link. It surfaces only a scope
/// description, the last-refresh time, and a small text summary of the latest
/// figures (close, day change, period high/low) — never a chart and never the raw
/// series. Refreshing is manual (button) plus a lazy on-open fetch when the stored
/// snapshot is missing or stale; failures are best-effort and keep the last snapshot.
struct DataLinkView: View {
    let assistant: DocumentAssistant
    let link: DataLink
    /// Lets the host reload its `dataLinks` after a refresh so the sidebar and any
    /// "last refreshed" text elsewhere stay in sync.
    var onChanged: () -> Void

    @State private var figures = DataLinkFigures()
    @State private var lastRefreshedAt: Date?
    @State private var refreshing = false
    @State private var errorMessage: String?
    /// Guards the on-open lazy refresh so a re-run of `.task` can't refetch in a loop.
    @State private var didAutoRefresh = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                scopeSection
                refreshSection
                figuresSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(link.name)
        .task(id: link.id) {
            await load()
            await autoRefreshIfNeeded()
        }
    }

    // MARK: - Sections

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(link.name).font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Text(link.symbol).font(.subheadline).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text("Read-only live data").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var scopeSection: some View {
        let scope = link.scopeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(scope).font(.subheadline)
            }
        }
    }

    @ViewBuilder private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last refreshed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let last = lastRefreshedAt {
                        Text(last.formatted(.relative(presentation: .named))).font(.subheadline)
                    } else {
                        Text("Never").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { Task { await refresh() } } label: {
                    HStack(spacing: 6) {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(refreshing ? "Refreshing…" : "Refresh")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(refreshing)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var figuresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest figures").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if figures.isEmpty {
                Text("Tap Refresh to fetch the latest snapshot.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let close = figures.latestClose {
                    figureRow("Close", value: number(close), prominent: true)
                }
                if let change = figures.change {
                    figureRow(
                        "Day change",
                        value: changeText(change, percent: figures.changePercent),
                        tint: change >= 0 ? .green : .red
                    )
                }
                if let high = figures.periodHigh { figureRow("Period high", value: number(high)) }
                if let low = figures.periodLow { figureRow("Period low", value: number(low)) }
                if let asOf = figures.asOf {
                    Text(asOfText(asOf))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func figureRow(_ label: String, value: String, tint: Color? = nil, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(prominent ? .title3.weight(.semibold) : .body)
                .foregroundStyle(tint ?? Color.primary)
                .monospacedDigit()
        }
    }

    // MARK: - Loading & refresh

    /// Pulls the derived figures and last-refresh stamp from the assistant so the view
    /// reflects on-device state immediately (and after every refresh).
    private func load() async {
        figures = await assistant.figures(for: link.id)
        lastRefreshedAt = await assistant.dataLink(id: link.id)?.lastRefreshedAt ?? link.lastRefreshedAt
    }

    /// Lazily refreshes once on open when the snapshot is missing or stale.
    private func autoRefreshIfNeeded() async {
        guard !didAutoRefresh else { return }
        didAutoRefresh = true
        if await assistant.dataLinkNeedsRefresh(id: link.id) { await refresh() }
    }

    /// Manual/lazy refresh. Best-effort: a failure surfaces a message but keeps the
    /// previously stored snapshot (and its figures) intact.
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        errorMessage = nil
        do {
            try await assistant.refreshDataLink(id: link.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        await load()
        refreshing = false
        onChanged()
    }

    // MARK: - Formatting

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func changeText(_ change: Double, percent: Double?) -> String {
        let signed = change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2)))
        guard let percent else { return signed }
        let signedPercent = percent.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2)))
        return "\(signed) (\(signedPercent)%)"
    }

    private func asOfText(_ asOf: Date) -> String {
        let date = asOf.formatted(date: .abbreviated, time: .omitted)
        return figures.pointCount > 0
            ? "As of \(date) · \(figures.pointCount)-day window"
            : "As of \(date)"
    }
}
