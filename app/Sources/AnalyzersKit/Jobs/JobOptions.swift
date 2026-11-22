import Foundation

/// The knobs a job's engine script takes, as data. Two jobs have the "same
/// options" when these compare equal — that is what ties an apply to the
/// preview the user reviewed.
public struct JobOptions: Sendable, Hashable, Codable {

    /// Storage clean: the engine's deep mode (stale node_modules, idle
    /// worktrees, package caches) plus Time Machine snapshot release.
    public var deep = false

    /// Temp & Agents: delete instead of moving to the Trash.
    public var permanent = false

    /// Eject: the mount point inside a temp folder.
    public var mountPoint: String?

    /// Recordings: the age the SCHEDULED clean prunes from
    /// (`--recordings-older-than`). 0 is the screen's own value — the preview
    /// looks at every recording, of every age, so the whole folder's size
    /// shows and the person picks a range there; the saved setting stays the
    /// automation's default and is never read by the screen.
    public var recordingsDays = 90

    /// Cache Guardian: a worktree must be idle this many days to be offered.
    public var worktreeIdleDays = 14
    /// Cache Guardian: parked local-only files may go once they are this old.
    public var parkedDays = 30
    /// Cache Guardian: dated report dirs may go once they are this old.
    public var reportsDays = 90

    /// Memory cleanup: also end busy orphaned tools, not only idle ones
    /// (`--orphans-all`).
    public var includeBusyOrphans = false

    /// Memory cleanup, "everything now": also ask these apps to quit, by name
    /// (`--apps-list`). Empty adds nothing. The names are part of what the
    /// preview was, so an apply carries exactly the same list.
    public var alsoQuit: [String] = []

    /// Time Machine: start a fresh backup after the snapshots are thinned (`tm-reclaim.sh` without `--no-backup`).
    public var startBackup = true
    /// Time Machine only: delete local snapshots older than this many days
    /// (nil = thin everything at once, as the permission's one command does).
    public var tmOlderThan: Int?


    /// A scheduled run replayed by hand ("Run Now"): the arguments from the
    /// installed launchd plist, after the script path. The store fills this in
    /// itself from the plist for a `.schedule(label)` run, and ignores whatever a
    /// caller put here: they usually include `--apply`.
    public var scheduleArguments: [String]?

    public init(deep: Bool = false, permanent: Bool = false, mountPoint: String? = nil,
                recordingsDays: Int = 90, scheduleArguments: [String]? = nil,
                includeBusyOrphans: Bool = false, alsoQuit: [String] = [], startBackup: Bool = true,
                tmOlderThan: Int? = nil,
                worktreeIdleDays: Int = 14, parkedDays: Int = 30, reportsDays: Int = 90) {
        self.deep = deep
        self.permanent = permanent
        self.mountPoint = mountPoint
        self.recordingsDays = recordingsDays
        self.scheduleArguments = scheduleArguments
        self.includeBusyOrphans = includeBusyOrphans
        self.alsoQuit = alsoQuit
        self.startBackup = startBackup
        self.tmOlderThan = tmOlderThan

        self.worktreeIdleDays = worktreeIdleDays
        self.parkedDays = parkedDays
        self.reportsDays = reportsDays
    }
}
