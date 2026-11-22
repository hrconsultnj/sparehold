import SwiftUI
import AnalyzersKit

/// The explainer's four tabs: three kinds of thing the app looks after, and the files it keeps.
enum HowItWorksTab: String, CaseIterable, Hashable, Sendable {
    case memory, storage, system, yourData

    var title: String {
        switch self {
        case .memory: Names.Group.memory
        case .storage: Names.Group.storage
        case .system: Names.Group.system
        case .yourData: Names.HowItWorks.yourData
        }
    }

    var symbol: String {
        switch self {
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .system: "gearshape.2"
        case .yourData: "folder"
        }
    }
}

/// One thing the app explains. Its deep link is `howItWorks:<raw value>`; each data screen's help button names one.
enum HowItWorksTopic: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case measures, guardSteps, guardNever, rowLocks, cleanup
    case safeToRemove, downloadsTemp, timeMachine, unusedApps, oldRecordings
    case loginItems, network, askAgent
    case whereWritten, editByHand, healthReport, privacy, trashVsUndo

    var id: String { rawValue }

    var tab: HowItWorksTab {
        switch self {
        case .measures, .guardSteps, .guardNever, .rowLocks, .cleanup: .memory
        case .safeToRemove, .downloadsTemp, .timeMachine, .unusedApps, .oldRecordings: .storage
        case .loginItems, .network, .askAgent: .system
        case .whereWritten, .editByHand, .healthReport, .privacy, .trashVsUndo: .yourData
        }
    }

    var title: String {
        switch self {
        case .measures: Names.HowItWorks.measures
        case .guardSteps: Names.HowItWorks.guardSteps
        case .guardNever: Names.HowItWorks.guardNever
        case .rowLocks: Names.HowItWorks.rowLocks
        case .cleanup: Names.HowItWorks.cleanup
        case .safeToRemove: Names.HowItWorks.safeToRemove
        case .downloadsTemp: Names.HowItWorks.downloadsTemp
        case .timeMachine: Names.HowItWorks.timeMachine
        case .unusedApps: Names.HowItWorks.unusedApps
        case .oldRecordings: Names.HowItWorks.oldRecordings
        case .loginItems: Names.HowItWorks.loginItems
        case .network: Names.HowItWorks.network
        case .askAgent: Names.HowItWorks.askAgent
        case .whereWritten: Names.HowItWorks.whereWritten
        case .editByHand: Names.HowItWorks.editByHand
        case .healthReport: Names.HowItWorks.healthReport
        case .privacy: Names.HowItWorks.privacy
        case .trashVsUndo: Names.HowItWorks.trashVsUndo
        }
    }

    var symbol: String {
        switch self {
        case .measures: "gauge.with.dots.needle.67percent"
        case .guardSteps: "shield.lefthalf.filled"
        case .guardNever: "hand.raised"
        case .rowLocks: "lock.fill"
        case .cleanup: "sparkles"
        case .safeToRemove: "shippingbox"
        case .downloadsTemp: "arrow.down.circle"
        case .timeMachine: "clock.arrow.circlepath"
        case .unusedApps: "square.dashed"
        case .oldRecordings: "film"
        case .loginItems: "person.crop.circle.badge.questionmark"
        case .network: "network"
        case .askAgent: "sparkles"
        case .whereWritten: "doc.text"
        case .editByHand: "slider.horizontal.3"
        case .healthReport: "heart.text.square"
        case .privacy: "lock.shield"
        case .trashVsUndo: "arrow.uturn.backward.circle"
        }
    }

    /// A deep link target string for this topic.
    var target: String { "howItWorks:\(rawValue)" }

    static func parse(_ target: String) -> HowItWorksTopic? {
        guard target.hasPrefix("howItWorks:") else { return nil }
        return HowItWorksTopic(rawValue: String(target.dropFirst("howItWorks:".count)))
    }
}

/// What a topic's screen says, written with this Mac's numbers. A topic is a small lesson: what the thing is, why it
/// matters on this Mac (the real numbers), what it never does, the actions waiting on the screens it explains, and one
/// common question answered.
struct TopicContent {
    /// One named action, as a row: where it leads and what waits there, in the screen's own words.
    struct Action: Identifiable {
        let title: String
        let detail: String
        let target: String
        var id: String { title }
    }

    /// The one common question the topic answers.
    struct Question {
        let ask: String
        let answer: String
    }

    /// The one sentence on the topic's row in the list, with this Mac's number in it.
    var summary: String
    /// What this thing is, in one plain sentence a non-developer understands. It opens the lesson.
    var what: String?
    /// How it works, in sentences a person can act on.
    var does: [String] = []
    /// Why it matters on this Mac: only sentences that quote a figure this Mac's readings produced.
    var onThisMac: [String] = []
    var never: [String] = []
    var written: [String] = []
    /// The named actions available, each deep-linking to the exact screen (or screen and tab) that offers it.
    var actions: [Action] = []
    var question: Question?
}
