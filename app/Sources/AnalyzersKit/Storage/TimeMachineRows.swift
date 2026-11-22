import Foundation

/// The only tab of Time Machine: the local snapshots.
public enum TimeMachineCategory: String, StorageCategory {
    case snapshots
    public var title: String { Names.Screen.timeMachine }
    public var symbol: String { "clock.arrow.circlepath" }
}

/// What a `tm-reclaim.sh` run printed, as the rows Storage screens share: one group per age band (under 7 days,
/// 7 to 30, 30 to 90, older), one row per local snapshot named by its time, so the WHOLE folder is visible at
/// once — every snapshot `tmutil` lists is in exactly one band, whatever the schedule thins. There are no sizes:
/// APFS cannot say how much one snapshot holds, and a made-up number would be worse than none. The real measure
/// is the free space before and after, which the run prints.
public struct TimeMachineReview: Sendable {
    public let rows: StorageRows
    /// "51Gi" as `df` printed it, before and after (after only for an apply).
    public let freeBefore: String?
    public let freeAfter: String?
    /// The run could not delete because the permission is missing.
    public let needsPermission: Bool
    /// How many snapshots Apply would delete (the ones that are not the system's).
    public let deletable: Int

    /// `now` and `calendar` are injected so a probe gets the same day names every day.
    public static func build(lines: [String], results: Bool = false, now: Date = Date(),
                             calendar: Calendar = .current) -> TimeMachineReview {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let time = DateFormatter(); time.dateStyle = .none; time.timeStyle = .short
        let day = DateFormatter(); day.dateStyle = .medium; day.timeStyle = .none
        var rows: [StorageRow] = []
        var before: String?, after: String?
        var denied = false
        let notDone = lines.contains { $0.hasPrefix("NOT DONE") }
        for line in lines {
            if line.hasPrefix("FREE_BEFORE ") { before = String(line.dropFirst(12)) }
            else if line.hasPrefix("FREE_AFTER ") { after = String(line.dropFirst(11)) }
            else if line.contains("needs permission") { denied = true }
            else if line.hasPrefix("SNAPSHOT "), let date = stamp.date(from: String(line.dropFirst(9))) {
                let band = AgeBand(date: date, now: now, calendar: calendar)
                rows.append(StorageRow(id: String(line.dropFirst(9)), category: TimeMachineCategory.snapshots.rawValue, group: band.title,
                                       title: time.string(from: date),
                                       detail: results ? nil : "Local snapshot · \(day.string(from: date))",
                                       valueText: results ? (notDone ? "Couldn't Delete" : "Deleted") : nil,
                                       band: band))
            } else if line.hasPrefix("OSSNAPSHOT ") {
                // macOS's own update snapshots are not ours: shown, never offered
                rows.append(StorageRow(id: String(line.dropFirst(11)), category: TimeMachineCategory.snapshots.rawValue,
                                       group: Names.Temp.managedByMacOS, title: "macOS Update Snapshot",
                                       detail: "Kept so the last update can be undone", keptReason: Names.Kept.leftForOwner))
            }
        }
        var facts: [String] = []
        if results, let before, let after { facts.append("free space \(before) → \(after)") }
        else if let before { facts.append("free space \(before)") }
        return TimeMachineReview(rows: StorageRows(rows, facts: facts), freeBefore: before, freeAfter: after,
                                 needsPermission: denied, deletable: rows.filter(\.isChoosable).count)
    }
}
