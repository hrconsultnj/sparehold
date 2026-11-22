import AnalyzersKit
import SwiftUI

/// The order of the sidebar groups, and lookups across them. This is the only
/// shared list: what a group contains lives in its own file.
@MainActor
enum SectionRegistry {

    static let groups: [SidebarGroup] = {
        let groups = [
            AskGroup.group,
            OverviewGroup.group,
            StorageGroup.group,
            MemoryGroup.group,
            SystemGroup.group,
            HistoryGroup.group,
            SettingsGroup.group,
            AppGroup.group,
        ]
        assertNoDuplicates(in: groups)
        return groups
    }()

    /// The sidebar row a section shows as selected: itself when it has a row of
    /// its own, else its group's first visible row — a category's nested screens
    /// keep the category highlighted, the way System Settings keeps "General"
    /// selected while a pane under it is open (Storage stays lit while Caches &
    /// Builds, Time Machine or Old Recordings is on screen). nil for the app
    /// group, whose foot item highlights itself.
    static func sidebarSelection(for section: SectionID) -> SectionID? {
        guard let group = groups.first(where: { $0.sections.contains(section) }) else { return nil }
        if group.rows.contains(where: { $0.section == section && $0.inSidebar }) { return section }
        return group.rows.first(where: \.inSidebar)?.section
    }

    /// The results view a group supplied for a kind of task, if any (the run screen's slot).
    static func runResults(for row: ActivityRow) -> ((ActivityRow) -> AnyView)? {
        let kind = row.kind ?? JobKind.allCases.first { $0.isCleaner && $0.log == row.log && row.log != nil }
        guard let kind else { return nil }
        for group in groups { if let view = group.runResults[kind] { return view } }
        return nil
    }

    /// Opened when there is nothing to restore.
    static var home: Location { Location(OverviewGroup.overview) }

    static func contains(_ section: SectionID) -> Bool {
        groups.contains { $0.sections.contains(section) }
    }

    static func root(for section: SectionID) -> AnyView {
        groups.first { $0.sections.contains(section) }?.root(section)
            ?? OverviewGroup.group.root(OverviewGroup.overview)
    }

    /// Two groups claiming the same target or section is a mistake that would
    /// otherwise be settled silently by group order. Checked once, in debug
    /// builds, the first time the registry is used.
    private static func assertNoDuplicates(in groups: [SidebarGroup]) {
        #if DEBUG
        var targets = Set<String>()
        var sections = Set<SectionID>()
        for group in groups {
            for target in group.aliases.keys {
                assert(targets.insert(target).inserted,
                       "deep-link target \"\(target)\" is claimed by more than one group")
            }
            for section in group.sections {
                assert(sections.insert(section).inserted,
                       "section \"\(section.rawValue)\" is owned by more than one group")
            }
        }
        #endif
    }
}
