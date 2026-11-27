import Foundation

/// The evidence package (§6): the self-contained Markdown the toolbar's Copy Evidence button puts on the
/// pasteboard — the verdict, the timeline's headline rows, the memory-at-event figures in GB, the top audit
/// findings with their line numbers, the setup deltas, the coverage gaps and the decision list. EVERY string
/// goes through the one redactor first; the fixture probe plants a username, a hostname and a secret and
/// asserts none survive (acceptance criterion 5).
public enum EvidencePackage {

    /// The package for one diagnostic run. The inputs are raw strings and parsed rows; redaction happens here,
    /// once, before anything is built — never again in the view, and never only on copy.
    public static func build(redactor: EvidenceRedactor,
                             verdict: String,
                             timelineHeadline: [String],
                             memoryAtEvent: [String],
                             auditFindings: [Finding],
                             setupDeltas: [SetupRow],
                             coverageGaps: [String],
                             decisions: [Decision]) -> String {
        var lines: [String] = []
        lines.append("# Agent Diagnostic")
        lines.append("")
        lines.append(redactor.redact(verdict))
        if !timelineHeadline.isEmpty {
            lines.append("")
            lines.append("## Timeline")
            lines.append(contentsOf: timelineHeadline.map { "- " + redactor.redact($0) })
        }
        if !memoryAtEvent.isEmpty {
            lines.append("")
            lines.append("## Memory at the event")
            lines.append(contentsOf: memoryAtEvent.map { "- " + redactor.redact($0) })
        }
        if !auditFindings.isEmpty {
            lines.append("")
            lines.append("## Audit findings")
            for finding in auditFindings {
                let citation = finding.citation.map { " — " + redactor.redact($0) } ?? ""
                lines.append("- \(redactor.redact(finding.title)) [\(finding.grade.rawValue)]\(citation)")
            }
        }
        if !setupDeltas.isEmpty {
            lines.append("")
            lines.append("## Agent setup")
            lines.append(contentsOf: setupDeltas.map {
                "- \(redactor.redact($0.tool)) \($0.topic): \(redactor.redact($0.value)) [\($0.grade.rawValue)]"
            })
        }
        if !coverageGaps.isEmpty {
            lines.append("")
            lines.append("## Coverage gaps")
            lines.append(contentsOf: coverageGaps.map { "- " + redactor.redact($0) })
        }
        if !decisions.isEmpty {
            lines.append("")
            lines.append("## Decisions (recommended, not applied)")
            lines.append(contentsOf: Decision.ranked(decisions).map {
                "- \(redactor.redact($0.action)) [\($0.kind.rawValue) — \($0.reversibility.note)]"
            })
        }
        return lines.joined(separator: "\n")
    }
}
