import Foundation

/// The shared shape of a diagnostic run's TSVs (§9): one `#` header comment line naming the columns, then
/// tab-separated rows with `-` for an empty cell. The parsers carry their column lists as constants; the probe
/// holds the engine's output to them (header parity — `--probe-agents` is the parity for data, this for
/// formats).
public enum RunTSV {

    /// The header comment line for a run TSV: `# sparehold agent diagnostic <name> v1: <columns>`.
    public static func header(_ name: String, columns: String) -> String {
        "# sparehold agent diagnostic \(name) v1: \(columns)"
    }

    /// Does `text` open with exactly this header comment? A moved column fails here, loudly.
    public static func headerMatches(_ text: String, header: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.first.map { $0 == Substring(header) } ?? false
    }

    /// The data rows of a run TSV: no comment lines, no blanks.
    public static func dataRows(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// One diagnostic run as the app reads it: the run dir's TSVs parsed into rows (§6, §9). Every file is
/// optional — a `--jobs-only` run carries no timeline — and a file that is there parses or says why not.
public struct DiagnosticRun: Sendable {
    public let directory: URL
    public let timeline: [TimelineRow]
    public let jobs: [LaunchdJobAuditRow]
    public let setup: [SetupRow]
    public let telemetry: [TelemetryCoverageRow]
    /// The TSVs the run's own `run.log` named in its final line — what the run parser finds them by.
    public let namedFiles: [String]
}

/// Loads a run directory (`reports/agent-diagnostic/<date>/<run>/`, §9) into a `DiagnosticRun`.
public enum DiagnosticRunParser {

    public static let timelineFile = "timeline.tsv"
    public static let jobsFile = "jobs.tsv"
    public static let setupFile = "setup.tsv"
    public static let telemetryFile = "telemetry.tsv"
    public static let runLogFile = "run.log"

    /// Reads a run dir, parsing each TSV that is there. nil when the directory itself cannot be read.
    public static func load(directory: URL) -> DiagnosticRun? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return nil }
        func read(_ name: String) -> String? {
            manager.contents(atPath: directory.appending(path: name).path)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return DiagnosticRun(
            directory: directory,
            timeline: read(timelineFile).map(TimelineBuilder.parse(tsv:)) ?? [],
            jobs: read(jobsFile).map(JobsAuditParser.parse(tsv:)) ?? [],
            setup: read(setupFile).map(AgentSetupParser.parse(tsv:)) ?? [],
            telemetry: read(telemetryFile).map(TelemetryCoverage.parse(tsv:)) ?? [],
            namedFiles: read(runLogFile).map { namedFiles(inRunLog: $0) } ?? [])
    }

    /// A `run.log`'s final line names the TSVs the run wrote (`wrote: timeline.tsv jobs.tsv …`) — how the run
    /// parser finds them without globbing the directory.
    public static func namedFiles(inRunLog text: String) -> [String] {
        let last = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        guard last.hasPrefix("wrote:") else { return [] }
        return last.dropFirst("wrote:".count)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .filter { $0.hasSuffix(".tsv") }
            .map(String.init)
    }
}
