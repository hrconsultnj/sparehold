import Foundation

/// One parsed diagnostic report (§1): the model carries the header's event time and the file name's save time
/// SEPARATELY — the issue's whole point is that the name can be the wrong clock — and the memory figures in GB,
/// never in pages. A field the report lacks stays `nil`; the finding says so instead of inventing a figure.
public struct CrashReport: Identifiable, Hashable, Sendable {

    /// What kind of report this is: 210 kernel panic · 28 crash · 29 jetsam · the hang family as `hang`; any
    /// unrecognized `bug_type` is kept as `.other(name)` — unknown is listed, not dropped (issue §1).
    public enum BugType: Hashable, Sendable {
        case panic
        case crash
        case jetsam
        case hang
        case other(String)

        public var label: String {
            switch self {
            case .panic: "kernel panic"
            case .crash: "crash"
            case .jetsam: "jetsam"
            case .hang: "hang"
            case .other(let name): name
            }
        }

        /// The header's `bug_type` cell read as a kind.
        public init(headerBugType raw: String) {
            switch raw {
            case "210": self = .panic
            case "28": self = .crash
            case "29": self = .jetsam
            case "hang": self = .hang
            default: self = .other(raw)
            }
        }
    }

    /// The incident id when the header carried one, else the file name.
    public let id: String
    public let bugType: BugType
    /// When the event really happened — the header's `captureTime`, parsed as ISO8601 with offset.
    public let eventTime: Date?
    /// The header's `captureTime` exactly as written (the divergence citation quotes both times as written).
    public let captureTimeText: String
    /// When the file says it was saved (its `-YYYY-MM-DD-HHMMSS` name part); nil when the name carries no time.
    public let fileTime: Date?
    /// `fileTime − eventTime`. A divergence over `significantDivergence` is its own confirmed finding.
    public var timeDivergence: TimeInterval? {
        guard let eventTime, let fileTime else { return nil }
        return fileTime.timeIntervalSince(eventTime)
    }
    /// The panic text: a panic's own `panicString`, a crash's first exception line, nil when the body has none.
    public let panicString: String?
    public let pagesFreeGB: Double?
    public let wiredGB: Double?
    public let compressedGB: Double?
    public let compressorSegmentLimitReached: Bool?
    public let swapFiles: Int?
    public let swapUsedGB: Double?
    /// The report's own process (crash and jetsam rows) — the jetsam rows are the past wired-memory baseline
    /// the issue compares against.
    public let procName: String?
    public let fileName: String

    /// A divergence over five minutes is its own confirmed finding — both times as written are the citation
    /// ("report saved N minutes after the event"). nil when the times agree or either is unknown.
    public var divergenceFinding: Finding? {
        guard let divergence = timeDivergence, divergence > Self.significantDivergence else { return nil }
        let minutes = Int((divergence / 60).rounded())
        return Finding(
            id: "time-divergence-" + fileName,
            grade: .confirmed,
            title: "Report saved \(minutes) minutes after the event",
            detail: "The header says the \(bugType.label) happened at \(captureTimeText); the file name says it was saved at \(fileTimeText). The name is the wrong clock to anchor a timeline on.",
            citation: "captureTime \(captureTimeText) vs file name \(fileName)")
    }

    /// The panic string's first line — the timeline's one-line shape; the full text stays for the redacted detail.
    public var panicHeadline: String? {
        let firstLine = panicString?.split(separator: "\n", omittingEmptySubsequences: true).first
        return firstLine.map(String.init) ?? panicString
    }

    /// "yyyy-MM-dd HH:mm:ss" in local time — how every diagnostic time is shown; "unknown" when absent.
    public var eventTimeText: String { Self.timeText(eventTime) }
    public var fileTimeText: String { Self.timeText(fileTime) }

    /// Five minutes: a file saved five minutes or more after its event is a divergence worth a finding.
    public static let significantDivergence: TimeInterval = 5 * 60

    static func timeText(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
