import AnalyzersKit
import SwiftUI
import UIComponents

/// The scored cards above a report (issue #12): one per number the report
/// shows — the value on this Mac, what is normal for it, a status, and a
/// button that opens the tool that acts on that number. The cards judge
/// nothing themselves: every verdict comes from the analyzer's sidecar, the
/// same variables its Diagnosis prose judged.
struct MetricCards: View {

    let cards: [ReportMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { card in
                MetricCardRow(card: card)
            }
        }
    }
}

/// One card: the number, its normal, the status word, and the button.
struct MetricCardRow: View {

    let card: ReportMetric
    @Environment(Navigator.self) private var navigator

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.value)
                    .font(.callout.weight(.medium))
                Text(card.normal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            statusBadge
            ForEach(card.actions, id: \.self) { target in
                Button(actionTitle(target)) {
                    navigator.open(target: target)
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(card.status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch card.status {
        case .inRange: .green
        case .watch: .orange
        case .act: .red
        }
    }

    /// The button's words: what the tool does, not what it is called.
    private func actionTitle(_ target: String) -> String {
        switch target {
        case "monitor": return "Open Monitor"
        case "memorykind:compressed": return "See who holds compressed memory"
        case "log:reclaim": return "Preview Free RAM Now"
        case "log:memoryClean": return "Preview Memory Cleanup"
        case "disk:capacity": return "Open the Disk Hub"
        case "disk:caches": return "Preview Caches & Builds"
        case "disk:downloads": return "Review Downloads"
        case "disk:unused": return "Review Unused Apps"
        case "disk:temp": return "Preview Temp Cleanup"
        default: return "Open"
        }
    }
}
