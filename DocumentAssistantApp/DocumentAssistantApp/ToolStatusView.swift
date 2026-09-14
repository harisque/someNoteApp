import SwiftUI

/// One row in the live tool-status feed. `active` shows a spinner, `done` a checkmark.
struct ActivityStep: Identifiable, Equatable {
    enum State { case active, done }
    let id: String
    var label: String
    var state: State
    var detail: String? = nil
}

/// Vertical stepper that surfaces what the deterministic tool layer is doing
/// (searching, reading sources, composing the prompt, generating) so the user is
/// never left wondering whether work is progressing.
struct ToolStatusView: View {
    let steps: [ActivityStep]

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Group {
                            switch step.state {
                            case .active:
                                ProgressView().controlSize(.small)
                            case .done:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color("SCGreen"))
                            }
                        }
                        .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.label).font(.caption)
                            if let detail = step.detail {
                                Text(detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
