import Foundation

/// What the diagnostic recommends about a finding — exactly one of the seven. The screen says in its subtitle
/// what the issue says: the diagnostic recommends; it does not apply (there is no Apply button anywhere on it).
public enum DecisionKind: String, Sendable, CaseIterable {
    case keep, repair, configure, consolidate, `defer`, reject, unknown
}

/// How easily a recommendation undoes (the ranking's tie-break): a config key < a script edit < anything
/// destructive. Nothing in the diagnostic is destructive — the value exists so a future one cannot rank first.
public enum Reversibility: Int, Sendable, Comparable, CaseIterable {
    case configKey = 0
    case scriptEdit = 1
    case destructive = 2

    public static func < (lhs: Reversibility, rhs: Reversibility) -> Bool { lhs.rawValue < rhs.rawValue }

    public var note: String {
        switch self {
        case .configKey: "undone by one config key"
        case .scriptEdit: "undone by editing one script"
        case .destructive: "not undoable — nothing here recommends it"
        }
    }
}

/// One decision row (§6), ranked by `Decision.ranked`: confirmed-before-plausible-before-unknown, then the
/// more-reversible recommendation first.
public struct Decision: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: DecisionKind
    /// What to do, in one sentence ("cap the tool's parallel tasks at its documented 20").
    public let action: String
    /// Why, carrying the evidence grade of the finding behind it.
    public let why: String
    public let grade: FindingGrade
    public let reversibility: Reversibility

    public init(id: String, kind: DecisionKind, action: String, why: String,
                grade: FindingGrade, reversibility: Reversibility) {
        self.id = id
        self.kind = kind
        self.action = action
        self.why = why
        self.grade = grade
        self.reversibility = reversibility
    }

    /// The decision list's order: confirmed findings first, then plausible, then unknown; within a grade the
    /// more-reversible recommendation first.
    public static func ranked(_ decisions: [Decision]) -> [Decision] {
        let order: [FindingGrade] = [.confirmed, .plausible, .unknown]
        return decisions.sorted {
            let left = order.firstIndex(of: $0.grade) ?? order.count
            let right = order.firstIndex(of: $1.grade) ?? order.count
            return left != right ? left < right : $0.reversibility < $1.reversibility
        }
    }
}
