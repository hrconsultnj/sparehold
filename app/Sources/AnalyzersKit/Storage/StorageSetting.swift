import Foundation

/// The setting a cleanup preview was made with — Daily or Deep for Caches & Builds, Trash or
/// Delete Permanently for Temp & Agents — belongs to the PREVIEW, not to the screen.
///
/// An apply runs with the preview's options (`JobStore.apply(from:)` copies them), so whatever a
/// screen shows, asks and words must come from the same place or a person approves one thing and
/// the engine does another. This is the one rule for which setting a Storage screen shows:
/// the preview's, when one is on screen; the newest logged preview's, when that is what the
/// screen shows read-only; and only with neither, the person's own pick for the next preview.
public enum StorageSetting {

    /// The setting the screen shows, words and acts under.
    public static func shown(kind: JobKind, preview: JobOptions?, lastKnownBanner: String?,
                             chosen: JobOptions) -> JobOptions {
        if let preview { return normalized(kind, preview) }
        if let lastKnownBanner { return options(kind: kind, banner: lastKnownBanner) }
        return normalized(kind, chosen)
    }

    /// What the screen asks and words its Apply with: the words of the setting `shown` decides, in one
    /// place so a screen cannot word one setting and send another.
    public static func words(kind: JobKind, preview: JobOptions?, lastKnownBanner: String?, chosen: JobOptions) -> CleanWords {
        CleanWords.words(kind: kind, setting: shown(kind: kind, preview: preview, lastKnownBanner: lastKnownBanner, chosen: chosen))
            ?? CleanWords.caches(deep: false)
    }

    /// Whether choosing `picked` in the menu changes what is on screen: only then is the preview
    /// (or the last-known list) put away, because it was made with the other setting.
    public static func isChange(kind: JobKind, shown: JobOptions, picked: JobOptions) -> Bool {
        normalized(kind, shown) != normalized(kind, picked)
    }

    /// The setting a logged run was made with, read from its banner.
    public static func options(kind: JobKind, banner: String) -> JobOptions {
        switch kind {
        case .storageClean: JobOptions(deep: banner.contains("mode=deep"))
        case .tempClean: JobOptions(permanent: banner.lowercased().contains("permanent"))
        case .tmReclaim: JobOptions(startBackup: !banner.contains("backup=off"))
        case .guardian: JobOptions(worktreeIdleDays: number("idle", in: banner) ?? 14,
                                   parkedDays: number("parked", in: banner) ?? 30,
                                   reportsDays: number("reports", in: banner) ?? 90)
        default: JobOptions()
        }
    }

    /// `idle=14` in a Guardian banner.
    private static func number(_ name: String, in banner: String) -> Int? {
        banner.range(of: #"\#(name)=(\d+)"#, options: .regularExpression)
            .flatMap { Int(banner[$0].split(separator: "=")[1]) }
    }

    /// Only the fields a kind's screen offers count as its setting.
    public static func normalized(_ kind: JobKind, _ options: JobOptions) -> JobOptions {
        switch kind {
        case .storageClean: JobOptions(deep: options.deep)
        case .tempClean: JobOptions(permanent: options.permanent)
        case .tmReclaim: JobOptions(startBackup: options.startBackup)
        case .guardian: JobOptions(worktreeIdleDays: options.worktreeIdleDays,
                                   parkedDays: options.parkedDays, reportsDays: options.reportsDays)
        default: JobOptions()
        }
    }
}

/// The words an Apply and its confirmation use for a setting: one place, so the title, the
/// question and the second question can only follow the setting that was passed in.
public struct CleanWords: Equatable, Sendable {
    public let applyTitle: String
    public let verb: String
    public let destination: String
    public let message: String
    /// The second, plainer question for something that cannot be undone; nil when it can.
    public let permanentWarning: String?

    public static func caches(deep: Bool) -> CleanWords {
        CleanWords(applyTitle: "Remove", verb: "Remove", destination: "permanently",
                   message: deep
                       ? "These are caches and builds that are made again the next time they are needed. A Deep cleanup also deletes Time Machine's local snapshots, if that row is ticked."
                       : "These are caches and builds that are made again the next time they are needed.",
                   permanentWarning: "They are deleted, not moved to the Trash, so this can't be undone.")
    }

    public static func temp(permanent: Bool) -> CleanWords {
        permanent
            ? CleanWords(applyTitle: "Delete", verb: "Delete", destination: "permanently",
                         message: "Nothing here is open, recent, live or someone else's.",
                         permanentWarning: "Deleted items can't be put back.")
            : CleanWords(applyTitle: "Move to Trash", verb: "Move", destination: "to the Trash",
                         message: "You can put them back from Undo. The space returns when the Trash is emptied.",
                         permanentWarning: nil)
    }

    /// Delete the local snapshots: what it does in plain words. The sentence about the backup disk is chosen by the
    /// screen from what `tmutil destinationinfo` says (`diskSentence`), never left out.
    public static func timeMachine(backup: Bool, disk: TimeMachineDestination.Reach? = nil) -> CleanWords {
        CleanWords(applyTitle: "Delete Snapshots", verb: "Delete", destination: "now",
                   message: "Deletes the local snapshots Time Machine keeps on this Mac, which releases the space they hold. They can't be brought back. "
                       + diskSentence(disk) + " Backups on the Time Machine disk aren't touched."
                       + (backup ? " A backup starts afterwards, unless you turn off Start a Backup Afterwards in Options." : ""),
                   permanentWarning: nil)
    }

    /// Why the local snapshots may matter: they are the only copies of changes since the last backup while the
    /// backup disk is away.
    public static func diskSentence(_ disk: TimeMachineDestination.Reach?) -> String {
        switch disk {
        case .connected: "Your backup disk is connected."
        case .notConnected: "Your backup disk isn't connected right now, so these snapshots are the only copies of changes since your last backup."
        case .notSetUp: "No backup disk is set up, so these snapshots are the only copies of recent versions of your files."
        case .unknown, nil: "While your backup disk isn't connected, local snapshots are the only copies of changes since your last backup."
        }
    }

    /// The words for the cleanups whose setting is fixed: everything reviewed goes
    /// to the Trash (Downloads, Unused Apps, Old Recordings), wherever they are
    /// asked about — a screen or a finished preview's results.
    public static func pathsToTrash() -> CleanWords {
        CleanWords(applyTitle: "Move to Trash", verb: "Move", destination: "to the Trash",
                   message: "You can put them back from Undo. The space returns when the Trash is emptied.",
                   permanentWarning: nil)
    }

    /// The Guardian's removals, in plain words: what parking did (the ledger row is
    /// the receipt), what survives, and what goes for good. The ages name the setting
    /// the preview was made with.
    public static func guardian(idle: Int, parked: Int, reports: Int) -> CleanWords {
        CleanWords(applyTitle: "Remove", verb: "Remove", destination: "permanently",
                   message: "Each removed worktree's local-only files are copied into Sparehold's reports folder first, "
                       + "with instructions to bring it back; its branch and commits stay. Worktrees idle more than \(idle) days "
                       + "are offered, parked files older than \(parked) days and report folders older than \(reports) days.",
                   permanentWarning: "Removed folders are not moved to the Trash. A removed worktree can be rebuilt with the "
                       + "restore commands in Sparehold's removal ledger; old report folders can't be brought back.")
    }

    public static func words(kind: JobKind, setting: JobOptions) -> CleanWords? {
        switch kind {
        case .storageClean: caches(deep: setting.deep)
        case .tempClean: temp(permanent: setting.permanent)
        case .tmReclaim: timeMachine(backup: setting.startBackup)
        case .guardian: guardian(idle: setting.worktreeIdleDays, parked: setting.parkedDays, reports: setting.reportsDays)
        case .janitor, .unusedApps, .recordings: pathsToTrash()
        default: nil
        }
    }
}
