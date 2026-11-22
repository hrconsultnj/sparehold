import SwiftUI
import AnalyzersKit

/// What can be pushed in the History group.
enum HistoryRoute: Hashable, Codable, Sendable {
    case trends(TrendsRoute)
    /// One cleanup of the Undo screen, by its run id: everything that run
    /// moved to the Trash, with its Restore actions.
    case cleanup(String)
}

/// Trends (and its drill-downs), Undo, and Reports — the past: what happened,
/// what the analyzers wrote down about it, and taking a cleanup back.
@MainActor
enum HistoryGroup {

    static let trends = SectionID("trends")
    static let undo = SectionID("undo")
    static let reports = SectionID("reports")

    static let group = SidebarGroup(
        title: Names.Group.history,
        rows: [
            SidebarRow(trends, Names.Screen.trends, symbol: "chart.xyaxis.line", tint: .teal),
            SidebarRow(undo, Names.Screen.undo, symbol: "arrow.uturn.backward", tint: .teal),
            SidebarRow(reports, Names.Screen.reports, symbol: "doc.text.magnifyingglass", tint: .teal),
        ],
        root: screen,
        aliases: [
            "trends": .main(Location(trends)),
            "undo": .main(Location(undo)),
            "reports": .main(Location(reports)),
            "undo:trashed": undoIntent("trashed"),
            "undo:servers": undoIntent("servers"),
            "undo:opened": undoIntent("opened"),
            // the drill-downs, for 30 days (also what the snapshot renders open)
            "trends:kills": drill(.kills(.month)),
            "trends:spikes": drill(.spikes(.month)),
            "trends:pressure": drill(.pressure(.month)),
            "trends:cpu": drill(.cpuHogs(.month)),
            "trends:memory-freed": drill(.memoryFreed(.month)),
            // the two tabs: the screen opens on the one named
            "trends:memory": tab(.memory),
            "trends:storage": tab(.storage),
            "trends:disk": drill(.diskReclaimed(.month)),
            "trends:reclaimable": drill(.reclaimableNow),
        ],
        resolveDynamic: { target in
            // `undo:cleanup:<run id>` — one cleanup's screen (the id a row carries)
            if target.hasPrefix("undo:cleanup:") {
                return .main(Location(undo, path: [.history(.cleanup(String(target.dropFirst("undo:cleanup:".count))))]))
            }
            // `reports:pick:<n>|section:<n>|raw` — Reports with the nth report open, its nth
            // section pushed, or its source pushed.
            if target.hasPrefix("reports:") {
                return .mainWithIntent(Location(reports),
                                       SectionIntent(section: reports, payload: String(target.dropFirst("reports:".count))))
            }
            // `trends:memory:24h`, `trends:storage:7d`: a tab with the period it should show
            for category in TrendCategory.allCases where target.hasPrefix("trends:\(category.rawValue):") {
                let name = String(target.dropFirst("trends:\(category.rawValue):".count))
                if let period = ReportPeriod(linkName: name) {
                    return .mainWithIntent(Location(trends), SectionIntent(section: trends, payload: "\(category.rawValue)|\(period.rawValue)"))
                }
            }
            // `trends:offender:<name>` — that process's timeline over 30 days
            guard target.hasPrefix("trends:offender:") else { return nil }
            return drill(.offender(String(target.dropFirst("trends:offender:".count)), .month))
        })

    private static func undoIntent(_ payload: String) -> Resolution {
        .mainWithIntent(Location(undo), SectionIntent(section: undo, payload: payload))
    }

    private static func tab(_ category: TrendCategory) -> Resolution {
        .mainWithIntent(Location(trends), SectionIntent(section: trends, payload: category.rawValue))
    }

    private static func drill(_ route: TrendsRoute) -> Resolution {
        .main(Location(trends, path: [.history(.trends(route))]))
    }

    @ViewBuilder private static func screen(_ section: SectionID) -> some View {
        switch section {
        case trends: TrendsSettingsView()
        case undo: UndoView()
        case reports: ReportsView()
        default: EmptyView()
        }
    }

    @ViewBuilder static func destination(for route: HistoryRoute) -> some View {
        switch route {
        case .trends(let route): trendsDestination(route)
        case .cleanup(let runID): UndoCleanupScreen(runID: runID)
        }
    }
}
