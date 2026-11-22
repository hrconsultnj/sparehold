import Foundation

/// One storage task on the Disk screen: what it could free, from which look,
/// and where it lives.
public struct StorageTask: Identifiable, Sendable {
    public let kind: JobKind
    /// Bytes a cleanup would free, as of the latest preview; nil when there has
    /// been no preview yet.
    public let reclaimableBytes: Int64?
    public let measuredAt: Date?
    /// A sentence on what the figure is made of.
    public let detail: String

    public init(kind: JobKind, reclaimableBytes: Int64?, measuredAt: Date?, detail: String) {
        self.kind = kind; self.reclaimableBytes = reclaimableBytes; self.measuredAt = measuredAt; self.detail = detail
    }

    public var id: String { kind.rawValue }
    public var title: String { Names.job(kind) }
}

/// The Disk screen's rows: one per storage task, each from the newest
/// preview in that task's own log, read whole. The row opens the task's own
/// screen; Time Machine, Unused Apps and Old Recordings are listed here too
/// (Storage's other panes), but only the four cleanups the screen previews
/// itself carry a "Preview All" and a byte figure a cleanup can promise.
public enum StorageTasks {

    public static func load() -> [StorageTask] {
        [caches(), downloads(), temp(), spotlight(), guardian(), timeMachine(), unusedApps(), recordings()]
    }

    private static func none(_ kind: JobKind, _ detail: String) -> StorageTask {
        StorageTask(kind: kind, reclaimableBytes: nil, measuredAt: nil, detail: detail)
    }

    private static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func caches() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .storageClean) else {
            return none(.storageClean, "No preview yet. Preview to see what could go.")
        }
        let review = CacheReview.build(lines: run.lines, banner: run.banner, modified: { _ in nil })
        let sized = review.rows.rows.filter { $0.bytes != nil }
        let inProjects = review.rows.rows(in: CacheCategory.projects).filter { $0.bytes != nil }
        let projects = Set(inProjects.compactMap(\.group)).count
        let appCaches = review.rows.rows(in: CacheCategory.appCaches).filter { $0.bytes != nil }.count
        let tools = review.rows.rows(in: CacheCategory.developerTools).filter { $0.bytes != nil }.count
        var parts: [String] = []
        if !inProjects.isEmpty { parts.append("\(plural(inProjects.count, "folder")) in \(plural(projects, "project"))") }
        if appCaches > 0 { parts.append(plural(appCaches, "app cache")) }
        if tools > 0 { parts.append(plural(tools, "developer tool cache")) }
        return StorageTask(kind: .storageClean, reclaimableBytes: review.rows.totalBytes,
                           measuredAt: RunDate.date(of: run.banner),
                           detail: sized.isEmpty ? "Nothing to clean."
                                                 : "\(review.mode.title) preview: " + ListFormatter.localizedString(byJoining: parts) + ".")
    }

    static func downloads() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .janitor) else {
            return none(.janitor, "No preview yet. Preview to see what could go.")
        }
        let review = DownloadReview.build(lines: run.lines, info: { _ in (nil, false) })
        let count = review.rows.choosable.count
        return StorageTask(kind: .janitor, reclaimableBytes: review.rows.choosableBytes,
                           measuredAt: RunDate.date(of: run.banner),
                           detail: count == 0 ? "Nothing old enough to move."
                                              : "\(plural(count, "old item")) can go to the Trash.")
    }

    static func temp() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .tempClean) else {
            return none(.tempClean, "No audit yet. Preview to see what could go.")
        }
        let review = TempReview.build(from: TempCleanParser.parse(runHeader: run.banner, lines: run.lines))
        let count = review.ready.count
        return StorageTask(kind: .tempClean, reclaimableBytes: review.readyBytes,
                           measuredAt: RunDate.date(of: run.banner),
                           detail: count == 0 ? "Nothing is ready to clear." : "\(plural(count, "item")) ready to clear.")
    }

    static func spotlight() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .spotlight) else {
            return none(.spotlight, "No audit yet. Preview to see what Spotlight indexes.")
        }
        let review = SpotlightReview.build(from: SpotlightAuditParser.parse(runHeader: run.banner, lines: run.lines),
                                           current: { _ in nil })
        let count = review.unfenced.count
        return StorageTask(kind: .spotlight, reclaimableBytes: nil, measuredAt: RunDate.date(of: run.banner),
                           detail: count == 0 ? "Every developer folder is fenced."
                                              : "\(plural(count, "developer folder")) still indexed.")
    }

    /// What the last Guardian preview found: the merged worktrees agents left
    /// behind, the store prunes it can run, and Sparehold's own old reports.
    static func guardian() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .guardian) else {
            return none(.guardian, "No preview yet. Preview to see what agents left behind.")
        }
        let review = GuardianReview.build(lines: run.lines, banner: run.banner)
        let worktrees = review.rows.rows(in: GuardianCategory.worktrees).filter { $0.isChoosable && $0.bytes != nil }
        let stores = review.rows.rows(in: GuardianCategory.stores).filter { $0.isChoosable }
        let reports = review.rows.rows(in: GuardianCategory.retention).filter { $0.isChoosable && $0.bytes != nil }
        var parts: [String] = []
        if !worktrees.isEmpty { parts.append(plural(worktrees.count, "merged worktree")) }
        if !stores.isEmpty { parts.append(plural(stores.count, "store prune")) }
        if !reports.isEmpty { parts.append(plural(reports.count, "old report folder")) }
        return StorageTask(kind: .guardian, reclaimableBytes: review.rows.choosableBytes,
                           measuredAt: RunDate.date(of: run.banner),
                           detail: parts.isEmpty ? "Nothing to clear."
                                                 : ListFormatter.localizedString(byJoining: parts) + " to clear.")
    }

    /// Every local snapshot, of every age — the screen shows the whole folder,
    /// banded by age. There is no byte figure on purpose: APFS cannot say how
    /// much one snapshot holds, and the row does not invent one.
    static func timeMachine() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .tmReclaim) else {
            return none(.tmReclaim, "No preview yet. Open it to see every local snapshot.")
        }
        let review = TimeMachineReview.build(lines: run.lines)
        let count = review.deletable
        return StorageTask(kind: .tmReclaim, reclaimableBytes: nil, measuredAt: RunDate.date(of: run.banner),
                           detail: count == 0 ? "No local snapshots to thin."
                                              : "\(plural(count, "local snapshot")) holding just-deleted blocks.")
    }

    static func unusedApps() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .unusedApps) else {
            return none(.unusedApps, "No preview yet. Open it to see what unused apps hold.")
        }
        let rows = UnusedReview.apps(lines: run.lines)
        let apps = Set(rows.choosable.compactMap(\.group)).count
        return StorageTask(kind: .unusedApps, reclaimableBytes: rows.choosableBytes,
                           measuredAt: RunDate.date(of: run.banner),
                           detail: apps == 0 ? "Nothing is waiting to be reviewed."
                                             : "\(plural(apps, "app")) can go to the Trash, every file that goes with them.")
    }

    /// The newest recordings preview lists every age (the screen previews the
    /// whole folder; the saved days are the scheduled clean's own limit).
    static func recordings() -> StorageTask {
        guard let run = StorageLog.newestPreview(of: .recordings) else {
            return none(.recordings, "No preview yet. Open it to see what your recording folders hold.")
        }
        let rows = UnusedReview.recordings(lines: run.lines)
        let count = rows.choosable.count
        return StorageTask(kind: .recordings, reclaimableBytes: rows.choosableBytes,
                           measuredAt: RunDate.date(of: run.banner),
                           detail: count == 0 ? "No recordings in the folders you chose."
                                              : "\(plural(count, "recording")) of every age.")
    }
}
