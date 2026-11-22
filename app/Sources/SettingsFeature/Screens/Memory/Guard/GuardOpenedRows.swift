import AnalyzersKit

/// The rows the list opened, as the list showed them. An entry screen opened from the list shows exactly the row that
/// was clicked, whatever the log has done since (its read expired, the period's start moved on and shortened a group,
/// new alerts joined it); only an entry reached another way (a restored window, a link) is looked up in a read of the log.
/// The newest few are kept; nothing is written anywhere.
@MainActor
enum GuardOpenedRows {
    private static var kept: [GuardHistory.Row] = []
    private static let limit = 20

    static func remember(_ row: GuardHistory.Row) {
        kept.removeAll { $0.id == row.id }
        kept.append(row)
        if kept.count > limit { kept.removeFirst(kept.count - limit) }
    }

    static func row(id: String) -> GuardHistory.Row? { kept.first { $0.id == id } }

    /// The row for an id, for every screen a row opens: the one the list opened, as the
    /// list showed it, or — reached another way (a restored window, a link) — looked up
    /// in the list's own read (shared, so nothing is read twice) and then in the longest
    /// one. The entry screen and the raw-lines screen both come here, so they show the
    /// same row the same way.
    static func loaded(id: String) async -> GuardHistory.Row? {
        var found = row(id: id)
        if found == nil { found = await GuardHistoryModel.history(window: GuardHistoryModel.savedWindow())?.row(id: id) }
        if found == nil {
            found = await GuardHistoryModel.history(days: GuardHistory.windowDays)?.row(id: id)
        }
        return found
    }
}
