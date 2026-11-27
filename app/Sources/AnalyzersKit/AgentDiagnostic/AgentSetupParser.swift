import Foundation

/// One row of a run's `setup.tsv` (§4): a tool × topic cell with its value, grade and citation. Secret keys
/// carry the NAME only — the parser never reads their values at all (DEC-7), so a redacted value can never
/// reach a grade, a decision or the evidence builder.
public struct SetupRow: Identifiable, Hashable, Sendable {
    public let tool: String
    /// permission mode · hooks · concurrency · connectors · sessions in window · stale
    public let topic: String
    public let key: String
    /// `<value not read>` on a key the name-only allowlist covers; the value the tool documents otherwise.
    public let value: String
    public let grade: FindingGrade
    /// Where the row was read from (`~/.claude/settings.json:env`), or where the tool documents it.
    public let citation: String

    public var id: String { "\(tool):\(topic):\(key)" }
}

/// Parses `setup.tsv` (§4) — the agent setup report — into rows, with the DEC-7 rule enforced here rather than
/// in a view: values of name-matched keys are dropped at parse time, before any grade, decision or evidence
/// text can see them.
public enum AgentSetupParser {

    /// The `setup.tsv` columns — the contract the probe holds the engine's phase-two collector to.
    public static let columns = "tool topic key value grade citation"
    public static let headerLine = RunTSV.header("setup", columns: columns)

    /// What a secret-key row shows instead of a value (DEC-7).
    public static let valueNotRead = "<value not read>"

    /// The documented concurrency limit the incident ran five times over (the issue: 100 vs 20), carried as a
    /// cited kit constant so the screen can show actual vs documented with the figure's source.
    public static let documentedConcurrency = 20
    public static let documentedConcurrencyCitation =
        "the tools' documented limit, carried as AgentSetupParser.documentedConcurrency"

    /// The name-only allowlist (DEC-7): a settings key whose NAME matches loses its value at parse time.
    private static let sensitiveNameParts: Set<String> =
        ["env", "token", "key", "secret", "apikey", "header", "authorization"]

    /// Does this settings key's NAME match the allowlist? Matched on name parts, never substrings, so a
    /// "monkey" path is not a key: `ANTHROPIC_API_KEY` yes (`…_API_…_KEY`), a concurrency knob like
    /// `CLAUDE_CODE_PARALLEL_TASK_COUNT` no — its value must read so actual can compare with documented.
    public static func isSensitive(key: String) -> Bool {
        let parts = key.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.contains { sensitiveNameParts.contains(String($0)) }
    }

    /// `setup.tsv` text → rows, values dropped for sensitive keys at parse time — even if a collector ever
    /// wrote one, the value cannot survive the parse (DEC-7).
    public static func parse(tsv text: String) -> [SetupRow] {
        RunTSV.dataRows(in: text).compactMap { line in
            let cells = line.components(separatedBy: "\t")
            guard cells.count >= 6 else { return nil }
            let key = cells[2]
            return SetupRow(
                tool: cells[0],
                topic: cells[1],
                key: key,
                value: isSensitive(key: key) ? valueNotRead : (cells[3] == "-" ? "" : cells[3]),
                grade: FindingGrade(rawValue: cells[4]) ?? .unknown,
                citation: cells[5] == "-" ? "" : cells[5])
        }
    }

    /// The incident's concurrency finding: actual over the documented limit is confirmed, citing the settings
    /// path + key and the kit's documented constant. nil when the tool stays at or under the limit.
    public static func concurrencyFinding(tool: String, key: String, actual: Int, settingsPath: String) -> Finding? {
        guard actual > documentedConcurrency else { return nil }
        return Finding(
            id: "concurrency-\(tool)-\(key)",
            grade: .confirmed,
            title: "\(tool) runs \(actual) parallel tasks — \(documentedConcurrency) documented",
            detail: "The env key \(key) is set to \(actual), \(actual - documentedConcurrency) over the documented limit; every session pays for it whether or not it has work.",
            citation: "\(settingsPath):\(key) (\(documentedConcurrencyCitation))")
    }

    /// A tool whose config is missing is UNKNOWN, never absent (issue §5's rule): "not found where the tool
    /// documents" is a row with its grade, not a finding that the tool is not there.
    public static func missingConfigRow(tool: String, documentedPath: String) -> SetupRow {
        SetupRow(
            tool: tool, topic: "config", key: "config",
            value: "not found where \(tool) documents it",
            grade: .unknown, citation: documentedPath)
    }

    /// Whether a hook event can block anything (§4's static table): PreToolUse can deny a call; PostToolUse
    /// cannot un-call it; Stop and SessionStart never block. The screen reads this, not a parser rule.
    public static func hookCanBlock(event: String) -> Bool {
        event.lowercased() == "pretooluse"
    }
}
