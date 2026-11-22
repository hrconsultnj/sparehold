import SwiftUI
import AnalyzersKit

/// What can be pushed in the System group.
enum SystemRoute: Hashable, Codable, Sendable {
    /// One numbered section of the report open in Reports: the report by its path
    /// (a `ReportDocument`'s id) and the section's index. The screen reads the file
    /// again, the same read and split the reader did, so it stands on its own.
    case reportSection(report: String, index: Int)
}

/// Network, Login & Startup Items and Reports.
@MainActor
enum SystemGroup {

    static let network = SectionID("network")
    static let loginItems = SectionID("loginItems")
    static let reports = SectionID("reports")

    static let group = SidebarGroup(
        title: Names.Group.system,
        rows: [
            SidebarRow(network, Names.Screen.network, symbol: "network", tint: .orange),
            SidebarRow(loginItems, Names.Screen.loginItems, symbol: "person.crop.circle.badge.questionmark", tint: .orange),
            SidebarRow(reports, Names.Screen.reports, symbol: "doc.text.magnifyingglass", tint: .orange),
        ],
        root: screen,
        aliases: [
            "network": .main(Location(network)),
            "reports": .main(Location(reports)),
            "loginitems": .main(Location(loginItems)),
            "log:loginItems": .main(Location(loginItems)),
            // the startup-changes history is the Changes scope of Login & Startup Items
            "log:persistence": .mainWithIntent(Location(loginItems),
                                               SectionIntent(section: loginItems, payload: "changes")),
        ],
        resolveDynamic: resolveDynamic)

    /// Targets that carry a request for the screen to apply when it appears:
    ///  - `startup:changes|leftovers|select:<name>` — Login & Startup Items on the Changes scope,
    ///    filtered to leftovers, or with that item open in the inspector;
    ///  - `network:history|older|pick:<n>` — Network on History, on the previous snapshot, or
    ///    with the nth-largest program open;
    ///  - `reports:pick:<n>|section:<n>|raw` — Reports with the nth report open, its nth
    ///    section pushed, or its source pushed.
    /// Pure: the screen reads the data and applies the request when it has it.
    private static func resolveDynamic(_ target: String) -> Resolution? {
        let sections: [(prefix: String, section: SectionID)] = [
            ("startup:", loginItems), ("network:", network), ("reports:", reports),
        ]
        for (prefix, section) in sections where target.hasPrefix(prefix) {
            return .mainWithIntent(Location(section),
                                   SectionIntent(section: section, payload: String(target.dropFirst(prefix.count))))
        }
        return nil
    }

    @ViewBuilder private static func screen(_ section: SectionID) -> some View {
        switch section {
        case network: NetworkView()
        case loginItems: LoginItemsView()
        case reports: ReportsView()
        default: EmptyView()
        }
    }

    @ViewBuilder static func destination(for route: SystemRoute) -> some View {
        switch route {
        case .reportSection(let report, let index): ReportSectionScreen(report: report, index: index)
        }
    }
}
