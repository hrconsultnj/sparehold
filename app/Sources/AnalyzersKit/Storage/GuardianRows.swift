import Foundation

/// How far the Cache Guardian's keep-before-offer ages go. The ages are per-preview
/// options (the apply repeats the preview's numbers), so the mode is only the words
/// for a choice of them — what the screen SHOWS always comes from the preview
/// (`StorageSetting`), exactly as Daily/Deep does for Caches & Builds.
public enum GuardianMode: String, CaseIterable, Identifiable, Sendable {
    case balanced, keepLonger, reclaimSooner
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balanced: Names.Guardian.balanced
        case .keepLonger: Names.Guardian.keepLonger
        case .reclaimSooner: Names.Guardian.reclaimSooner
        }
    }

    /// One sentence for the control.
    public var sentence: String {
        switch self {
        case .balanced: "Worktrees idle two weeks, parked files older than a month, reports older than three months."
        case .keepLonger: "Worktrees idle a month, parked files older than three months, reports older than six months."
        case .reclaimSooner: "Worktrees idle a week, parked files older than two weeks, reports older than two months."
        }
    }

    public var options: JobOptions {
        switch self {
        case .balanced: JobOptions(worktreeIdleDays: 14, parkedDays: 30, reportsDays: 90)
        case .keepLonger: JobOptions(worktreeIdleDays: 30, parkedDays: 90, reportsDays: 180)
        case .reclaimSooner: JobOptions(worktreeIdleDays: 7, parkedDays: 14, reportsDays: 60)
        }
    }

    public init(options: JobOptions) {
        if options.worktreeIdleDays <= 7 {
            self = .reclaimSooner
        } else if options.worktreeIdleDays >= 30 {
            self = .keepLonger
        } else {
            self = .balanced
        }
    }
}

/// The tabs of the Cache Guardian.
public enum GuardianCategory: String, StorageCategory {
    case worktrees, stores, retention, guidance

    public var title: String {
        switch self {
        case .worktrees: Names.Guardian.tabWorktrees
        case .stores: Names.Guardian.tabStores
        case .retention: Names.Guardian.tabRetention
        case .guidance: Names.Guardian.tabGuidance
        }
    }

    public var symbol: String {
        switch self {
        case .worktrees: "arrow.triangle.branch"
        case .stores: "shippingbox"
        case .retention: "archivebox"
        case .guidance: "lightbulb"
        }
    }
}

/// What a Guardian preview found (or an apply did), as the rows Storage screens
/// share. The engine's line shapes are the contract (storage/guardian.sh's header):
/// sized rows tagged `worktree` / `retention` with the path fields after them,
/// `prune:<id>` rows exactly as the scheduled clean words them, kept rows in
/// parentheses, and `info:` / `guide:` / `store:` lines that are never actions.
public struct GuardianReview: Sendable {
    public let mode: GuardianMode
    public let rows: StorageRows
    public let freeSpace: String?

    /// Builds the rows from a run's whole block. `results` includes what an apply
    /// did (removed, left alone, couldn't remove) instead of only what a preview offers.
    public static func build(lines: [String], banner: String, results: Bool = false) -> GuardianReview {
        var rows: [StorageRow] = []
        var notes: [String] = []
        var tabNotes: [String: [String]] = [:]
        var free: String?
        var seenIDs = Set<String>()
        func note(_ text: String, for tab: String? = nil) {
            guard !text.isEmpty else { return }
            if let tab { tabNotes[tab, default: []].append(text) } else { notes.append(text) }
        }
        func push(_ row: StorageRow) {
            var id = row.id
            var n = 2
            while seenIDs.contains(id) {
                id = "\(row.id)-\(n)"
                n += 1
            }
            seenIDs.insert(id)
            rows.append(StorageRow(id: id, category: row.category, group: row.group, title: row.title,
                                   detail: row.detail, bytes: row.bytes, valueText: row.valueText,
                                   iconPath: row.iconPath, keptReason: row.keptReason))
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // free space, as a fact like the other Storage screens show
            if trimmed.hasPrefix("Free space now:") {
                free = String(trimmed.dropFirst("Free space now:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            // kept worktrees: never offered, shown with why
            if let kept = keptRow(from: trimmed) { push(kept); continue }
            // the run's tally over the worktrees, as a note over the tab
            if trimmed.contains("recent, live, locked, protected or unmerged") {
                note(tallySentence(trimmed), for: GuardianCategory.worktrees.rawValue)
                continue
            }
            // what an apply parked, as a note over the tab
            if trimmed.hasPrefix("(parked:"), let dash = trimmed.range(of: " — ") {
                let head = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "(parked:".count)..<dash.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                note("Copied local-only files to \(StorageLog.short(head)) before the remove.",
                     for: GuardianCategory.worktrees.rawValue)
                continue
            }
            // the prunes that are not paths: a preview's row, or what an apply did
            if let prune = pruneRow(from: trimmed, results: results) { push(prune); continue }
            // sized rows: worktrees and retention dirs
            if let row = markerRow(from: trimmed, results: results) { push(row); continue }
            // a path the apply left alone (unticked, changed since, a session in it)
            if let row = skipRow(from: trimmed) { push(row); continue }
            // advisory rows and sizes that are never actions
            if let row = advisoryRow(from: trimmed) { push(row); continue }
            // sentences that are not rows
            if trimmed.hasPrefix("("), trimmed.hasSuffix(")") {
                let inner = String(trimmed.dropFirst().dropLast())
                if inner == "sccache not installed" {
                    note("sccache is not installed, so there is no sccache cache to size.",
                         for: GuardianCategory.stores.rawValue)
                } else if inner == "no global-store guidance for this Mac" {
                    note("No global-store guidance for this Mac.", for: GuardianCategory.guidance.rawValue)
                } else if inner == "no project has two or more worktrees" {
                    note("No project has two or more worktrees, so no dependency folders are duplicated.",
                         for: GuardianCategory.guidance.rawValue)
                }
            }
        }
        // the preview's own facts: the ages it offered under
        var facts: [String] = []
        if let idle = bannerNumber("idle", in: banner) { facts.append("worktrees idle > \(idle) days") }
        if let parked = bannerNumber("parked", in: banner) { facts.append("parked files > \(parked) days") }
        if let reports = bannerNumber("reports", in: banner) { facts.append("reports > \(reports) days") }
        if let free { facts.append("free space \(free)") }
        return GuardianReview(mode: GuardianMode(options: StorageSetting.options(kind: .guardian, banner: banner)),
                              rows: StorageRows(rows, notes: notes, facts: facts, tabNotes: tabNotes),
                              freeSpace: free)
    }

    // MARK: - the engine's lines

    /// What a run line says happened, from the engine's bracket tag.
    private enum Status: String {
        case dry = "DRY"
        case deleted = "DELETED"
        case failed = "FAILED"

        /// Only an offer (`DRY`) is sized rows in a preview.
        var isOffer: Bool { self == .dry }
        /// The size column's word for a run that acted; nil for an offer (the bytes speak).
        var valueText: String? {
            switch self {
            case .dry: nil
            case .deleted: Names.Guardian.removed
            case .failed: Names.Guardian.couldNotRemove
            }
        }
    }

    /// `[DRY]      1.2 GB  worktree  <path>  <repo>  <detail>` and the retention shape.
    private static func markerRow(from line: String, results: Bool) -> StorageRow? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        guard let status = Status(rawValue: String(line[line.index(after: line.startIndex)..<close])),
              results || status.isOffer
        else { return nil }
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard let sizeRange = rest.range(of: #"^[\d.]+ [KMGT]?B\s+"#, options: .regularExpression) else { return nil }
        let bytes = ByteSize.parse(String(rest[sizeRange]).trimmingCharacters(in: .whitespaces)) ?? 0
        var after = String(rest[sizeRange.upperBound...])
        let marker: String
        if after.hasPrefix("worktree ") {
            marker = "worktree"
        } else if after.hasPrefix("retention ") {
            marker = "retention"
        } else {
            return nil
        }
        after = String(after.dropFirst(marker.count + 1))
        let fields = after.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if marker == "worktree" {
            // fields: <path> <repo> <detail>
            guard let path = fields.first else { return nil }
            let repo = fields.count > 1 ? fields[1] : projectGroup(of: path)
            let detail = fields.count > 2 ? plainDetail(fields[2]) : ""
            return StorageRow(id: path, category: GuardianCategory.worktrees.rawValue,
                              group: (repo as NSString).lastPathComponent,
                              title: (path as NSString).lastPathComponent,
                              detail: [StorageLog.short(path), detail].filter { !$0.isEmpty }.joined(separator: " · "),
                              bytes: bytes, valueText: status.valueText,
                              iconPath: path, keptReason: nil)
        }
        // retention: fields: <dir> <note>
        guard let path = fields.first else { return nil }
        let note = fields.count > 1 ? fields[1] : ""
        let parked = note.hasPrefix("parked worktree files")
        let age = note.range(of: #"(\d+)d old"#, options: .regularExpression)
            .flatMap { Int(String(note[$0].split(separator: " ")[0])) }
        let what = parked ? Names.Guardian.parkedFiles : Names.Guardian.reportRuns
        let kind = parked ? "parked local-only files from a removed worktree" : "one run's report"
        var detail = "\(StorageLog.short(path)) · \(what) — \(kind)"
        if let age { detail += " · \(age) days old" }
        return StorageRow(id: path, category: GuardianCategory.retention.rawValue, group: what,
                          title: (path as NSString).lastPathComponent,
                          detail: detail, bytes: bytes, valueText: status.valueText,
                          iconPath: path, keptReason: nil)
    }

    /// `(kept: <path> — <reason>)`, `(left alone: <path> — <reason>)`,
    /// `(stale record: <path> — its folder is gone; …)`.
    private static func keptRow(from line: String) -> StorageRow? {
        guard line.hasPrefix("("), line.hasSuffix(")") else { return nil }
        let inner = String(line.dropFirst().dropLast())
        for prefix in ["kept: ", "left alone: ", "stale record: "] where inner.hasPrefix(prefix) {
            let rest = String(inner.dropFirst(prefix.count))
            guard let dash = rest.range(of: " — ") else { return nil }
            let path = String(rest[..<dash.lowerBound])
            let reason = keptWords(String(rest[dash.upperBound...]))
            return StorageRow(id: path, category: GuardianCategory.worktrees.rawValue,
                              group: projectGroup(of: path),
                              title: (path as NSString).lastPathComponent,
                              detail: StorageLog.short(path),
                              bytes: nil, iconPath: path, keptReason: reason)
        }
        return nil
    }

    /// `[SKIP]    not in approved set  <path>` and its siblings: a path the apply left
    /// alone. (The `prune:` skips are `pruneRow`'s.)
    private static func skipRow(from line: String) -> StorageRow? {
        guard line.hasPrefix("[SKIP]"), let close = line.firstIndex(of: "]") else { return nil }
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.hasPrefix("prune:") else { return nil }
        let fields = rest.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let path = fields.last, path.hasPrefix("/") else { return nil }
        let reason = fields.count > 1 ? fields[0] : ""
        let kept: String
        if reason.contains("no preview") {
            kept = "No preview in this app offered it, so it was never removed."
        } else if reason.contains("running") {
            kept = "Something started running in it just now."
        } else if reason.contains("live session") {
            kept = "A live coding session is sitting in it."
        } else if reason.contains("protect") {
            kept = "It is on your protect list."
        } else if reason.contains("already gone") {
            kept = "It was already gone."
        } else {
            kept = "Not ticked in the review, so it was left alone."
        }
        let category = path.contains("/reports/") ? GuardianCategory.retention.rawValue : GuardianCategory.worktrees.rawValue
        return StorageRow(id: path, category: category, group: projectGroup(of: path),
                          title: (path as NSString).lastPathComponent,
                          detail: StorageLog.short(path), bytes: nil,
                          valueText: Names.Guardian.leftAlone, iconPath: path, keptReason: kept)
    }

    /// `[DRY]     prune:pnpm  Unused packages in the pnpm store (size not known until it runs)`
    /// and what an apply printed for each (`running:`, `done:`, `failed:`, `[SKIP] prune:<id>`).
    private static func pruneRow(from line: String, results: Bool) -> StorageRow? {
        func words(_ id: String) -> String { id == "pnpm" ? Names.Prune.pnpm : Names.Prune.npm }
        func row(_ id: String, _ value: String, _ detail: String) -> StorageRow {
            StorageRow(id: "prune:\(id)", category: GuardianCategory.stores.rawValue,
                       group: Names.StorageTab.packageManagers, title: words(id), detail: detail,
                       bytes: nil, valueText: value)
        }
        func id(in command: String) -> String? {
            command.contains("pnpm") ? "pnpm" : (command.contains("npm") ? "npm" : nil)
        }
        if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
           String(line[line.index(after: line.startIndex)..<close]) == "DRY" {
            let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("prune:"), let space = rest.firstIndex(of: " ") else { return nil }
            let key = String(rest[rest.index(rest.startIndex, offsetBy: "prune:".count)..<space])
            guard key == "pnpm" || key == "npm" else { return nil }
            return row(key, "When Applied", String(rest[rest.index(after: space)...]).trimmingCharacters(in: .whitespaces))
        }
        guard results else { return nil }
        for prefix in ["running: ", "done: ", "failed: "] where line.hasPrefix(prefix) {
            let command = String(line.dropFirst(prefix.count))
            guard let key = id(in: command) else { return nil }
            switch prefix {
            case "done: ": return row(key, Names.Prune.ran,
                                      key == "pnpm" ? "Unused packages were removed from the pnpm store."
                                                    : "The npm cache was emptied; it downloads again when needed.")
            case "failed: ":
                let code = command.range(of: #"\(exit (\d+)\)"#, options: .regularExpression)
                    .map { String(command[$0].filter(\.isNumber)) }
                return row(key, Names.Prune.couldNotRun,
                           "It ran but reported an error\(code.map { " (exit \($0))" } ?? ""), so it may not have finished. The raw output has the details.")
            default: return row(key, Names.Prune.started, "It started; the log doesn't say how it ended.")
            }
        }
        if line.hasPrefix("[SKIP]"), let close = line.firstIndex(of: "]") {
            let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("prune:"), let space = rest.firstIndex(of: " ") else { return nil }
            let key = String(rest[rest.index(rest.startIndex, offsetBy: "prune:".count)..<space])
            guard key == "pnpm" || key == "npm" else { return nil }
            return row(key, Names.Prune.skipped, "It wasn't ticked in the review, so it didn't run.")
        }
        return nil
    }

    /// `store:<id>  <size>  <path>`, `info:<key>  <sentence>`, `guide:<key>  <sentence>`.
    private static func advisoryRow(from line: String) -> StorageRow? {
        if line.hasPrefix("store:") {
            let rest = String(line.dropFirst("store:".count))
            guard let idEnd = rest.firstIndex(where: \.isWhitespace) else { return nil }
            let id = String(rest[..<idEnd])
            let tail = String(rest[rest.index(after: idEnd)...]).trimmingCharacters(in: .whitespaces)
            guard let pathSplit = tail.range(of: "  "),
                  ByteSize.parse(String(tail[..<pathSplit.lowerBound]).trimmingCharacters(in: .whitespaces)) != nil
            else { return nil }
            let size = String(tail[..<pathSplit.lowerBound]).trimmingCharacters(in: .whitespaces)
            let path = String(tail[pathSplit.upperBound...]).trimmingCharacters(in: .whitespaces)
            let title: String
            switch id {
            case "pnpm": title = Names.Guardian.storePnpm
            case "npm": title = Names.Guardian.storeNpm
            case "sccache": title = Names.Guardian.storeSccache
            default: title = Names.Guardian.storeCargo
            }
            return StorageRow(id: "store:\(id)", category: GuardianCategory.stores.rawValue,
                              group: nil, title: title,
                              detail: StorageLog.short(path), bytes: nil, valueText: size,
                              iconPath: path,
                              keptReason: "Size only — the prune below is what frees the space.")
        }
        for prefix in ["info:", "guide:"] where line.hasPrefix(prefix) {
            guard let space = line.firstIndex(of: " ") else { return nil }
            let key = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<space])
            let sentence = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            if prefix == "info:" {
                return StorageRow(id: "info:\(key)", category: GuardianCategory.guidance.rawValue,
                                  group: Names.Guardian.duplicatedFolders, title: key,
                                  detail: sentence, bytes: nil,
                                  keptReason: "Advice only — nothing is done to the project.")
            }
            return StorageRow(id: "guide:\(key)", category: GuardianCategory.guidance.rawValue,
                              group: Names.Guardian.globalStores, title: guideTitle(key),
                              detail: sentence, bytes: nil,
                              keptReason: "Advice only — the app never edits a tool's configuration.")
        }
        return nil
    }

    // MARK: - words

    private static func bannerNumber(_ name: String, in banner: String) -> Int? {
        guard let range = banner.range(of: #"\#(name)=(\d+)"#, options: .regularExpression) else { return nil }
        return Int(banner[range].split(separator: "=")[1])
    }

    /// The repo a worktree belongs to, for the group row: the project folder before
    /// the agent-workspace marker, else the folder the worktree sits in.
    static func projectGroup(of path: String) -> String {
        for marker in ["/.composure/workspaces/", "/.claude/worktrees/"] {
            if let range = path.range(of: marker) {
                return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            }
        }
        return (path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? path
    }

    /// The engine's keep reasons, in the review's words.
    private static func keptWords(_ reason: String) -> String {
        switch reason {
        case let r where r.contains("uncommitted changes"): "It has uncommitted changes."
        case let r where r.contains("changed since the preview"): "It changed since the preview — preview again."
        case let r where r.contains("locked"): "It is locked."
        case let r where r.contains("protect list"): "It is on your protect list."
        case let r where r.contains("modified in the last"): "It was modified recently."
        case let r where r.contains("live session"): "A live coding session is sitting in it."
        case let r where r.contains("not merged into"): "Its branch is not merged yet."
        case let r where r.contains("folder is gone"): "Its folder is gone; git worktree prune clears the record."
        default: reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }

    /// The tally line's counts, as a sentence over the Worktrees tab.
    private static func tallySentence(_ line: String) -> String {
        func count(_ pattern: String) -> Int? {
            line.range(of: pattern, options: .regularExpression).flatMap { Int(line[$0].filter(\.isNumber)) }
        }
        var parts: [String] = []
        if let kept = count(#"kept \d+ recent"#), kept > 0 {
            parts.append("\(kept) kept (recent, live, locked, protected or unmerged)")
        }
        if let dirty = count(#"left \d+ with uncommitted changes"#), dirty > 0 {
            parts.append("\(dirty) with uncommitted changes left alone")
        }
        if let main = count(#"\d+ on main or named main"#), main > 0 { parts.append("\(main) on main") }
        if parts.isEmpty { return "Every worktree was left alone." }
        return "Worktrees: " + parts.joined(separator: " · ") + "."
    }

    /// The engine's detail words, in the review's own words.
    private static func plainDetail(_ detail: String) -> String {
        var text = detail
        if let range = text.range(of: #"idle \d+d\+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: text[range].dropLast())
        }
        if let range = text.range(of: #"(\d+) dep dirs \([^)]+\)"#, options: .regularExpression) {
            let hit = text[range]
            let count = hit.split(separator: " ").first.map(String.init) ?? ""
            let size = hit.range(of: #"\([^)]+\)"#, options: .regularExpression).map { String(hit[$0]) } ?? ""
            let noun = count == "1" ? "dependency folder" : "dependency folders"
            text.replaceSubrange(range, with: "\(count) \(noun) \(size)")
        }
        return text
    }

    /// The guidance rows' titles, by the engine's key.
    private static func guideTitle(_ key: String) -> String {
        switch key {
        case "pnpm-store-dir": "Project-local pnpm Store"
        case "sccache-basedirs": "sccache Not Shared Across Worktrees"
        case "cargo-target-dir": "Shared Cargo Build Folder"
        default:
            key.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
}
