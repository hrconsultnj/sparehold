import Foundation

/// One row on the diagnostic's single time axis (§3): `timeline.tsv` is `kind ⇥ iso ⇥ epoch ⇥ summary ⇥ source`,
/// with report rows anchored on the HEADER time — the file name's save time is shown separately in the screen,
/// never merged into the axis.
public struct TimelineRow: Identifiable, Hashable, Sendable {

    /// The row kinds the axis knows (§3). A row whose kind is none of these is a collector bug — the header
    /// parity rule holds the engine to the nine.
    public enum Kind: String, Sendable, CaseIterable {
        case report
        case jetsam
        case purge
        case boot
        case gap
        case `guard`
        case recorder
        case session
        case job
    }

    public let kind: Kind
    /// The row's time exactly as written (ISO8601 with offset); a gap row carries none.
    public let iso: String
    public let epoch: TimeInterval?
    public let summary: String
    /// Where the row was read from (the report's name, the unified log, guard.log, the ring file, …).
    public let source: String

    /// The row's date: the epoch is the axis's truth; the iso is kept for the citation texts.
    public let date: Date?
    public var time: Date? {
        epoch.map { Date(timeIntervalSince1970: $0) } ?? date
    }

    public init(kind: Kind, iso: String, epoch: TimeInterval?, summary: String, source: String) {
        self.kind = kind
        self.iso = iso
        self.epoch = epoch
        self.summary = summary
        self.source = source
        self.date = CrashReportParser.eventTime(from: iso)
    }

    public var id: String { "\(kind.rawValue):\(iso):\(source):\(summary)" }
}

/// Builds the one time axis (§3): the window an event is examined in, anchored on the header's event time, and
/// the window's rows in order with the quiet stretches shown as gap rows — never papered over (issue §1).
public enum TimelineBuilder {

    /// The `timeline.tsv` columns (§3), exactly as the blueprint pins them.
    public static let columns = "kind iso epoch summary source"
    public static let headerLine = RunTSV.header("timeline", columns: columns)

    /// A quiet stretch inside the window with no rows longer than this becomes a `gap` row.
    public static let gapThreshold: TimeInterval = 15 * 60

    /// The window an event is examined in: an hour back, ten minutes forward, anchored on the header's event
    /// time — never the file name's save time (acceptance criterion 1).
    public static func window(around eventTime: Date) -> ClosedRange<Date> {
        eventTime.addingTimeInterval(-60 * 60) ... eventTime.addingTimeInterval(10 * 60)
    }

    /// `timeline.tsv` text → rows.
    public static func parse(tsv text: String) -> [TimelineRow] {
        RunTSV.dataRows(in: text).compactMap { line in
            let cells = line.components(separatedBy: "\t")
            guard cells.count >= 5, let kind = TimelineRow.Kind(rawValue: cells[0]) else { return nil }
            func cell(_ index: Int) -> String { cells[index] == "-" ? "" : cells[index] }
            return TimelineRow(
                kind: kind, iso: cell(1), epoch: TimeInterval(cells[2]), summary: cell(3), source: cell(4))
        }
    }

    /// The rows inside `window`, in time order, with a `gap` row inserted for every quiet stretch between two
    /// rows longer than `gapThreshold`. The event's report row anchors the group the screen draws.
    public static func build(rows: [TimelineRow], window: ClosedRange<Date>) -> [TimelineRow] {
        let kept = rows
            .filter { row in row.time.map(window.contains) ?? false }
            .sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
        guard let first = kept.first else { return [] }
        var built: [TimelineRow] = [first]
        for row in kept.dropFirst() {
            if let previous = built.last?.time, let time = row.time {
                let quiet = time.timeIntervalSince(previous)
                if quiet > gapThreshold {
                    let minutes = Int((quiet / 60).rounded())
                    built.append(TimelineRow(
                        kind: .gap, iso: "",
                        epoch: previous.timeIntervalSince1970 + quiet / 2,
                        summary: "no recorded activity for \(minutes) min",
                        source: "the window's own gap"))
                }
            }
            built.append(row)
        }
        return built
    }
}
