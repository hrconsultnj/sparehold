import Foundation

/// How well supported a diagnostic finding is (DEC-10): a grade is a type, never a free-text column, so a
/// typo cannot quietly become a fourth grade. Unknown findings are rows like any other — listed, never dropped.
public enum FindingGrade: String, Sendable, CaseIterable {
    case confirmed
    case plausible
    case unknown
}

/// One graded finding of the Agent Diagnostic. A finding cannot be built `confirmed` without a non-empty
/// citation (a file:line, a log line, or a named fixture source) — the constructor refuses, which is stronger
/// than a lint (DEC-10). `init` returns nil for that one shape; every other finding builds.
public struct Finding: Identifiable, Hashable, Sendable {
    public let id: String
    public let grade: FindingGrade
    public let title: String
    public let detail: String
    /// The cited source: `file:line`, a log line, or a named fixture source. Never empty on a confirmed finding.
    public let citation: String?

    public init?(id: String, grade: FindingGrade, title: String, detail: String, citation: String? = nil) {
        if grade == .confirmed, citation?.isEmpty ?? true { return nil }
        self.id = id
        self.grade = grade
        self.title = title
        self.detail = detail
        self.citation = citation
    }
}
