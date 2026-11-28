import Foundation

/// The metrics sidecar a report's analyzer writes next to itself
/// (`metrics.tsv`, issue #12): each number the report shows, scored against
/// this Mac — the value, what is normal for this Mac (RAM-scaled by the
/// engine, which knows the RAM), the status, and the deep-link targets of the
/// tools that act on it. The thresholds live in the analyzer, the same
/// variables its Diagnosis prose judges — the cards and the report can never
/// disagree.
public struct ReportMetric: Identifiable, Hashable, Sendable {

    public enum Status: String, Sendable, CaseIterable {
        case inRange = "in_range"
        case watch
        case act

        public var title: String {
            switch self {
            case .inRange: return "In range"
            case .watch: return "Watch"
            case .act: return "Act"
            }
        }
    }

    public let id: String          // metric name ("swap_used")
    public let value: String       // as the report says it ("80% of swap")
    public let normal: String      // what is normal for THIS Mac
    public let status: Status
    /// The deep-link targets of the buttons — each one opens a tool that acts
    /// on this number. Never applied from the card alone: previews and screens
    /// keep their own reviews.
    public let actions: [String]

    /// The columns the analyzer writes — the contract the probe holds.
    public static let columns = "metric value normal status actions"

    /// `metrics.tsv` text → rows, in file order. A row with the wrong column
    /// count or an unknown status is skipped (the report itself still renders),
    /// and a metric named twice keeps its first row.
    public static func parse(tsv text: String) -> [ReportMetric] {
        var seen = Set<String>()
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .compactMap { line in
                let cells = line.components(separatedBy: "\t")
                guard cells.count == 5, cells[0] != "metric",
                      let status = Status(rawValue: cells[3]), !seen.contains(cells[0]) else { return nil }
                seen.insert(cells[0])
                return ReportMetric(
                    id: cells[0], value: cells[1], normal: cells[2], status: status,
                    actions: cells[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty })
            }
    }

    /// Loads the sidecar that sits beside a report (`metrics.tsv` in the same
    /// folder); nil when this report predates the cards.
    public static func load(beside reportURL: URL) -> [ReportMetric]? {
        let sidecar = reportURL.deletingLastPathComponent().appending(path: "metrics.tsv")
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let rows = parse(tsv: text)
        return rows.isEmpty ? nil : rows
    }
}
