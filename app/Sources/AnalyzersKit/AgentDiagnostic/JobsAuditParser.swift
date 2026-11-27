import Foundation

/// One row of a run's `jobs.tsv` (§2): the launchd inventory with its per-finding rows. A job with no finding
/// is still listed (the issue's one table of every launch agent and scheduled job) — its row carries no check
/// id. A finding row carries `check_id`, the 1-based line number and the verbatim line text, so the person can
/// judge every flag themselves.
public struct LaunchdJobAuditRow: Identifiable, Hashable, Sendable {
    public let label: String
    public let plistPath: String
    public let scriptPath: String
    /// A human sentence for the trigger (StartInterval / StartCalendarInterval / RunAtLoad / KeepAlive).
    public let trigger: String
    /// What `launchctl print` said, "not loaded" when absent, "system (not checked)" for a root-only job.
    public let loaded: String
    public let lastRun: String
    /// The purpose derived from the plist's own comment or the script's leading comment block; "unknown" is a
    /// grade, not a guess.
    public let purpose: String
    /// The static check that hit; nil on a job's own clean listing row.
    public let checkID: String?
    public let lineNumber: Int?
    /// The line as written in the script or plist.
    public let lineText: String?
    public let grade: FindingGrade

    public var id: String { "\(label)/\(checkID ?? "-")/\(lineNumber.map(String.init) ?? "-")" }

    /// Is this row a finding, not the job's own listing?
    public var isFinding: Bool { checkID != nil }

    /// The row as a graded Finding: the verbatim line is the detail and `label line N: text` the citation, so a
    /// confirmed row always carries its source (DEC-10). nil on a listing row.
    public var finding: Finding? {
        guard let checkID else { return nil }
        let line = lineNumber.map(String.init) ?? "-"
        return Finding(
            id: "\(label)/\(checkID)/\(line)",
            grade: grade,
            title: "\(checkID) on \(label)",
            detail: lineText ?? purpose,
            citation: "\(label) line \(line): \(lineText ?? purpose)")
    }
}

/// Parses `jobs.tsv` (§2) — the engine's audit output — into rows. The column list is the contract the probe
/// holds the engine to (header parity); the Swift side only turns rows into rows, every check itself stays in
/// the engine script.
public enum JobsAuditParser {

    /// The `jobs.tsv` columns (§2), exactly as the blueprint pins them.
    public static let columns = "label plist script trigger loaded last_run purpose check_id line_no line_text grade"
    public static let headerLine = RunTSV.header("jobs", columns: columns)

    /// `jobs.tsv` text → rows, in file order (the engine writes one row per job × check hit, then the job's
    /// own listing). An empty cell is written `-`; a check_id of `clean` is the job's own listing row, not a
    /// finding; a grade cell that is none of the three grades reads as `unknown` — listed, not dropped.
    public static func parse(tsv text: String) -> [LaunchdJobAuditRow] {
        RunTSV.dataRows(in: text).compactMap { line in
            let cells = line.components(separatedBy: "\t")
            guard cells.count >= 11 else { return nil }
            func cell(_ index: Int) -> String { cells[index] == "-" ? "" : cells[index] }
            return LaunchdJobAuditRow(
                label: cell(0),
                plistPath: cell(1),
                scriptPath: cell(2),
                trigger: cell(3),
                loaded: cell(4),
                lastRun: cell(5),
                purpose: cell(6),
                checkID: (cells[7] == "-" || cells[7] == "clean") ? nil : cells[7],
                lineNumber: cells[8] == "-" ? nil : Int(cells[8]),
                lineText: cells[9] == "-" ? nil : cells[9],
                grade: FindingGrade(rawValue: cells[10]) ?? .unknown)
        }
    }
}
