import Foundation

/// One row of the coverage table (§5): a layer × what is recorded today × how long it is kept × what links
/// records × what is missing. The recorded cells are read from what actually exists on disk, so the table is
/// true on a Mac where the flight recorder was never on; each gap names the decision that proposes the fix.
public struct TelemetryCoverageRow: Identifiable, Hashable, Sendable {
    public let layer: String
    /// What is recorded today, from what exists on this Mac right now.
    public let recorded: String
    /// How long it is kept (a rotation size, a log's own short retention — a limit, named honestly).
    public let retention: String
    /// What links records (a pid; nothing across agent tools).
    public let link: String
    /// What is missing — the flight recorder's exact answer on the host layer.
    public let gap: String

    /// The issue's four layers.
    public enum Layer: String, Sendable, CaseIterable {
        case host, agent, process, workflow
    }

    /// The known layer this row belongs to, nil when the collector names a new one — the row still shows,
    /// under its own name.
    public var layerKind: Layer? { Layer(rawValue: layer) }

    public var id: String { layer }
}

/// Parses `telemetry.tsv` (§5) into coverage rows.
public enum TelemetryCoverage {

    /// The `telemetry.tsv` columns.
    public static let columns = "layer recorded retention link gap"
    public static let headerLine = RunTSV.header("telemetry", columns: columns)

    /// `telemetry.tsv` text → rows.
    public static func parse(tsv text: String) -> [TelemetryCoverageRow] {
        RunTSV.dataRows(in: text).compactMap { line in
            let cells = line.components(separatedBy: "\t")
            guard cells.count >= 5 else { return nil }
            func cell(_ index: Int) -> String { cells[index] == "-" ? "" : cells[index] }
            return TelemetryCoverageRow(
                layer: cells[0], recorded: cell(1), retention: cell(2), link: cell(3), gap: cell(4))
        }
    }
}
