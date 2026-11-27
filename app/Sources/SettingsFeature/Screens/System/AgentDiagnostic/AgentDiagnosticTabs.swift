import AnalyzersKit
import SwiftUI

/// The six tabs of the Agent Diagnostic screen. Each is rows over what the
/// kit parsed — none of them decides what the data means beyond naming it.
/// Findings and decisions share the sections-and-ranks rule: confirmed
/// first, unknown listed, never dropped (the issue's grading rule).

/// The one time axis: grouped rows under their kinds, newest first. A row
/// that opens (a report) shows the triggering text one level down — the
/// disclosure-audit rule, not inline on the axis.
struct TimelineTab: View {
    let rows: [TimelineRow]
    let reportNames: [String]

    var body: some View {
        if rows.isEmpty {
            EmptyState("No Rows in the Window", systemImage: "clock.arrow.circlepath",
                       description: Text("The run found nothing recorded in the hour around the event — the unified log's retention is short; the flight recorder is the durable answer."))
        } else {
            List {
                ForEach(grouped, id: \.key) { group in
                    Section {
                        ForEach(group.rows) { row in
                            TimelineRowView(row: row)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var grouped: [(key: String, title: String, rows: [TimelineRow])] {
        let order: [TimelineRow.Kind] = [.report, .jetsam, .purge, .boot, .guard, .recorder, .session, .job, .gap]
        return order.compactMap { kind in
            let members = rows.filter { $0.kind == kind }
            guard !members.isEmpty else { return nil }
            return (key: kind.rawValue, title: title(of: kind), rows: members)
        }
    }

    private func title(of kind: TimelineRow.Kind) -> String {
        switch kind {
        case .report: "Reports"
        case .jetsam: "Jetsam Baselines"
        case .purge: "Freed Disk"
        case .boot: "Boots"
        case .guard: "Memory Guard"
        case .recorder: "Flight Recorder"
        case .session: "Agent Sessions"
        case .job: "Scheduled Jobs"
        case .gap: "Quiet Stretches"
        }
    }
}

/// One axis row: what happened, when, and where it was read from.
struct TimelineRowView: View {
    let row: TimelineRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.summary)
            HStack {
                if let time = row.time {
                    Text(time, format: .dateTime.hour().minute().second())
                } else {
                    Text("time unknown")
                }
                Text("·")
                Text(row.source)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

/// Every launchd job, its trigger, and its findings with the line that trips
/// them. A clean job is still listed (the issue: one table), folded under its
/// own "clean" row so three broken jobs are never buried in thirty clean ones.
struct JobsAuditTab: View {
    let rows: [LaunchdJobAuditRow]

    var body: some View {
        if rows.isEmpty {
            EmptyState("No Jobs Read", systemImage: "list.bullet.rectangle",
                       description: Text("The run read no launchd plists — check the engine's access to ~/Library/LaunchAgents."))
        } else {
            List {
                ForEach(grouped, id: \.label) { group in
                    Section {
                        ForEach(group.rows.filter(\.isFinding)) { row in
                            JobFindingView(row: row)
                        }
                        if group.rows.allSatisfy({ !$0.isFinding }) {
                            Label("Clean — every check the audit knows came back empty", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text(group.label)
                            Spacer()
                            Text(group.rows.first?.trigger ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var grouped: [(label: String, rows: [LaunchdJobAuditRow])] {
        Dictionary(grouping: rows, by: \.label)
            .sorted { $0.key < $1.key }
            .map { (label: $0.key, rows: $0.value) }
    }
}

/// One audit finding: the grade, and the triggering line verbatim.
struct JobFindingView: View {
    let row: LaunchdJobAuditRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.checkID ?? "")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(row.grade.rawValue)
                    .font(.caption)
                    .foregroundStyle(gradeColor)
            }
            if let line = row.lineText {
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let number = row.lineNumber {
                Text("line \(number)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }

    private var gradeColor: Color {
        switch row.grade {
        case .confirmed: .red
        case .plausible: .orange
        case .unknown: .secondary
        }
    }
}

/// What Claude Code and Codex are set to, per tool. Secret keys show their
/// name and the value unread — that was decided at parse time, not here.
struct AgentSetupTab: View {
    let rows: [SetupRow]

    var body: some View {
        if rows.isEmpty {
            EmptyState("No Setup Read", systemImage: "switch.2",
                       description: Text("The run read no agent configuration — nothing is graded unknown here by a guess; the row would say the config was not found."))
        } else {
            List {
                ForEach(grouped, id: \.tool) { group in
                    Section {
                        ForEach(group.rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.key)
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Text(row.grade.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(row.value.isEmpty ? "not set" : row.value)
                                    .font(.caption)
                                    .foregroundStyle(row.value == AgentSetupParser.valueNotRead ? .orange : .secondary)
                                Text(row.citation)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 1)
                        }
                    } header: {
                        Text(group.tool)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var grouped: [(tool: String, rows: [SetupRow])] {
        Dictionary(grouping: rows, by: \.tool)
            .sorted { $0.key < $1.key }
            .map { (tool: $0.key, rows: $0.value) }
    }
}

/// The coverage table: what is recorded today, said honestly from disk.
struct TelemetryTab: View {
    let rows: [TelemetryCoverageRow]

    var body: some View {
        if rows.isEmpty {
            EmptyState("No Coverage Read", systemImage: "waveform.path.ecg")
        } else {
            List {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.layer.capitalized)
                            .font(.callout.weight(.medium))
                        LabeledContent("recorded", value: row.recorded)
                        LabeledContent("kept", value: row.retention)
                        LabeledContent("linked by", value: row.link)
                        LabeledContent("missing", value: row.gap)
                    }
                    .font(.caption)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
    }
}

/// The findings, in the issue's three sections: confirmed, plausible, unknown —
/// unknowns listed, never dropped.
struct FindingsTab: View {
    let findings: [Finding]

    var body: some View {
        if findings.isEmpty {
            EmptyState("No Findings", systemImage: "flag.2.crossed",
                       description: Text("Nothing the audit and the reports found is graded above unknown."))
        } else {
            List {
                ForEach([FindingGrade.confirmed, .plausible, .unknown], id: \.self) { grade in
                    let members = findings.filter { $0.grade == grade }
                    if !members.isEmpty {
                        Section {
                            ForEach(members) { finding in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.title)
                                        .font(.callout.weight(.medium))
                                    Text(finding.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let citation = finding.citation {
                                        Text(citation)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                        } header: {
                            Text("\(grade.rawValue) (\(members.count))")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// The decision list, ranked by evidence then reversibility — the screen
/// recommends and never applies (there is no Apply anywhere on it).
struct DecisionsTab: View {
    let decisions: [Decision]

    var body: some View {
        if decisions.isEmpty {
            EmptyState("No Decisions", systemImage: "checklist",
                       description: Text("Decisions come from findings; this run had none to act on."))
        } else {
            List {
                ForEach(decisions) { decision in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(decision.action)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(decision.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(decision.why)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
            .listStyle(.inset)
        }
    }
}

/// The rule that turns a finding into its one decision, in the screen's own
/// voice. Nothing here applies anything: the words are the recommendation.
enum DecisionList {
    static func forFindings(_ findings: [Finding]) -> [Decision] {
        findings.compactMap { finding -> Decision? in
            let (kind, action): (DecisionKind, String) = {
                switch finding.id.split(separator: "/").dropFirst().first.map(String.init) ?? "" {
                case "dangerous-action": (.repair, "Review the job by hand: it acts on things a schedule should not decide alone.")
                case "missing-path": (.repair, "Remove the job or restore the path it points at — as written it fails every run.")
                case "unbounded-log": (.configure, "Give the job's log a bound — a size check or a trim — so it cannot grow forever.")
                case "no-timeout": (.configure, "Wrap the call in a timeout so a hung network cannot hang the job.")
                case "no-log": (.configure, "Send the job's output to a log, so its next failure can be read.")
                case "repeating-error": (.repair, "Fix what the job's own log keeps reporting.")
                default: (.defer, "Look at this one with the evidence on the Findings tab.")
                }
            }()
            let reversibility: Reversibility = kind == .repair ? .scriptEdit : .configKey
            return Decision(id: "decision-" + finding.id, kind: kind, action: action,
                            why: finding.grade.rawValue + ": " + (finding.citation ?? finding.title),
                            grade: finding.grade, reversibility: reversibility)
        }
        .sorted { Decision.ranked([$0, $1]).first?.id == $0.id }
    }
}
