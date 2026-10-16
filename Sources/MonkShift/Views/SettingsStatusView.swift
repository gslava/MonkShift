import SwiftUI
import MonkShiftCore

struct SettingsStatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.busy || model.refreshing {
                ProgressView().controlSize(.small)
                    .padding(.top, 3)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.statusTitle).font(.headline)
                Text(model.statusDetail).font(.callout).foregroundStyle(.secondary)
                if model.statusNeedsAttention {
                    Label("Settings need attention. See the messages below.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch model.summary.status {
        case .allEnabled: return "checkmark.circle.fill"
        case .partiallyEnabled: return "circle.lefthalf.filled"
        case .off: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch model.summary.status {
        case .allEnabled: return .green
        case .partiallyEnabled: return .primary
        case .off: return .secondary
        case .unknown: return .orange
        }
    }
}
