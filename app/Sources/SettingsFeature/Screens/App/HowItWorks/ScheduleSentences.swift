import Foundation
import AnalyzersKit

/// What an installed background job does by itself, written for the person from the arguments its plist actually passes (a
/// flag in the plist is the only source of a claim here: `--apply` applies, `--dev`, `--docker-running-only`, `--prune-snapshots`
/// and the rest each add one sentence) and from the settings and the bash the script itself looks at. A job with no schedule
/// does not run by itself, and a job whose command could not be read says only when it runs.
extension HowItWorksFacts.ScheduleLine {
    func has(_ flag: String) -> Bool { arguments.contains(flag) }

    func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// The storage clean's mode: `daily` unless the plist says `--mode deep`.
    var isDeep: Bool { value(after: "--mode") == "deep" }

    /// The script thins Time Machine's local snapshots only in deep mode, applying, with `--prune-snapshots`.
    var thinsSnapshots: Bool { isDeep && has("--apply") && has("--prune-snapshots") }
}

extension HowItWorksFacts {
    private static let withoutPreview = " It applies what it finds by itself, without a preview, so nothing waits for your review."

    /// Tool cache ids `storage-auto-clean.sh` clears in either mode (its 3b header); the rest only in deep mode.
    private static let dailyToolCaches: Set<String> = ["brew", "pip", "uv", "cargo", "gradle", "deriveddata", "bun", "cipd"]

    /// What the memory clean does, as clauses ("closes …") and a closing note, from its plist's arguments (`memory-auto-clean.sh`).
    /// Its idle-tool sections (2 and 7 to 11 of its header) need a bash newer than macOS's 3.2, as the script itself decides, so
    /// they are claimed only where one is installed. nil: the job is not installed, or its command could not be read.
    private func memoryCleanClauses(_ line: HowItWorksFacts.ScheduleLine) -> (does: [String], note: String)? {
        guard line.installed, line.has("--apply") else { return nil }
        var does = ["closes coding-agent servers whose session has ended"]
        if !line.has("--dev") {
            does.append("closes development servers left running for more than \(line.value(after: "--dev-age-hours") ?? "24") hours")
            does.append("closes headless test browsers left running for more than 2 hours")
        }
        var note = ""
        if newerBashInstalled {
            does.append("closes developer-tool processes whose parent is gone once they have sat idle")
            does.append("closes development servers nobody is using")
            does.append("shuts down emulators and simulators nobody is using")
            does.append("stops Gradle and Kotlin build daemons while no build is running")
        } else {
            note = " The parts that judge what is idle (tools left behind, unused servers, emulators and simulators, build daemons) need a newer bash than the one macOS ships, and none is installed on this Mac, so they are skipped."
        }
        return (does, note + " It never touches your apps, your protected programs or anything that belongs to a coding session that is running now.")
    }

    /// The memory clean's own sentence, with when it runs.
    func memoryCleanDoes(_ label: String) -> String? {
        guard let line = schedule(label), line.installed else { return nil }
        guard let when = line.when else { return "\(line.name) is installed without a schedule, so it does not run by itself." }
        guard !line.arguments.isEmpty else { return "\(line.name) runs \(when.lowercased())." }
        guard let (does, note) = memoryCleanClauses(line) else {
            return "\(line.name) runs \(when.lowercased()), but only previews: it closes nothing."
        }
        return "\(line.name) runs \(when.lowercased()) and \(Names.Setup.list(does)).\(note)" + Self.withoutPreview
    }

    /// What a storage clean does, as clauses ("removes …") and a closing note, from its plist's arguments and the settings
    /// (`storage-auto-clean.sh`), daily or deep by the plist's `--mode`. nil: not installed, or it only previews.
    /// `after` is the daily clean's name when the deep clean's clauses are only what the installed daily clean lacks (the
    /// deep clean does everything the daily one does): the daily clean must be installed and applying, with the same
    /// build-folder age and roots, a schedule, and a Docker clause no wider than the deep clean's (an equal one is left out).
    @MainActor private func storageCleanClauses(_ line: HowItWorksFacts.ScheduleLine) -> (does: [String], note: String, after: String?)? {
        guard line.installed, line.has("--apply") else { return nil }
        let deep = line.isDeep
        let daily = deep ? schedule(GuardControl.storageCleanLabel).flatMap { $0.installed && $0.when != nil && $0.has("--apply") && !$0.isDeep ? $0 : nil } : nil
        let extending = daily.flatMap { d in
            d.value(after: "--cache-age-days") == line.value(after: "--cache-age-days")
                && d.value(after: "--roots") == line.value(after: "--roots")
                && Self.dockerRank(line) >= Self.dockerRank(d) ? d : nil
        }
        var does: [String] = []
        if extending == nil {
            does += ["removes build folders (.next, .turbo, dist, build and the like) that nothing has written to for \(days(Int(line.value(after: "--cache-age-days") ?? "") ?? 3))",
                     "trims the Turborepo caches to \(turboCacheMaxGB) GB in total, oldest entries first"]
        }
        let dailyCaches = toolCaches.filter { Self.dailyToolCaches.contains($0) }.count
        let caches = deep ? toolCaches.count : dailyCaches
        if extending != nil {
            let extra = caches - dailyCaches
            if extra > 0 { does.append("clears the \(extra) deep-only tool \(extra == 1 ? "cache" : "caches") you opted into") }
        } else if caches > 0 {
            does.append("clears the \(caches) \(caches == 1 ? "tool cache" : "tool caches") you opted into")
        }
        if deep {
            does.append("removes the dependency folders (node_modules) of projects whose files have not changed for \(days(nodeModulesDays))\(nodeModulesNeedClean ? " and whose changes are all saved in git" : "")")
            if worktreeIdleDays > 0 { does.append("clears the build output of git worktrees idle for \(days(worktreeIdleDays)) (never the worktree itself, never one with uncommitted changes)") }
            does.append("empties npm's cache and prunes the packages pnpm no longer references")
        }
        // the deep clean's Docker clause replaces the daily one; the daily clean's stays whole when nothing extends it
        if let extending, Self.dockerRank(line) == Self.dockerRank(extending) {
            // the daily clean already does exactly this
        } else if line.has("--docker-images") {
            does.append("prunes Docker's stopped containers, unused networks and every image nothing uses, starting Docker first if it is not running and quitting it again if it started it")
        } else if line.has("--docker") {
            does.append("prunes stopped containers, unused networks and dangling images in Docker, starting it first if needed")
        } else if line.has("--docker-running-only") {
            does.append("when Docker is already running, prunes its stopped containers, unused networks and dangling images (it never starts Docker)")
        }
        if line.thinsSnapshots {
            does.append(timeMachinePermission
                ? "thins Time Machine's local snapshots on this Mac (never the backups on the backup disk)"
                : "would thin Time Machine's local snapshots, but skips them until you give the permission (see \(Names.HowItWorks.timeMachine))")
        }
        return (does, deep ? " Projects that something live runs from, a running process or a loaded background agent, are left alone." : "", extending?.name)
    }

    /// How far a job's Docker clause reaches: none, only when running, starting Docker, or every unused image too.
    private static func dockerRank(_ line: HowItWorksFacts.ScheduleLine) -> Int {
        line.has("--docker-images") ? 3 : line.has("--docker") ? 2 : line.has("--docker-running-only") ? 1 : 0
    }

    /// A storage clean's own sentence, with when it runs.
    @MainActor func storageCleanDoes(_ label: String) -> String? {
        guard let line = schedule(label), line.installed else { return nil }
        guard let when = line.when else { return "\(line.name) is installed without a schedule, so it does not run by itself." }
        guard !line.arguments.isEmpty else { return "\(line.name) runs \(when.lowercased())." }
        guard let (does, note, after) = storageCleanClauses(line) else {
            return "\(line.name) runs \(when.lowercased()), but only previews: it removes nothing."
        }
        let what = after.map { "does everything \($0) does, plus it \(Names.Setup.list(does))" } ?? Names.Setup.list(does)
        return "\(line.name) runs \(when.lowercased()) and \(what).\(note)" + Self.withoutPreview
    }

    /// The same description for the Schedule pane's caption, without the time (the pane shows that in its own control): one
    /// description of each job, read from the same plist. A job that is not installed says so, and claims nothing it would
    /// do; one whose command could not be read says only that.
    @MainActor func jobCaption(_ label: String) -> String {
        guard let line = schedule(label), line.installed else { return Names.Setup.jobNotInstalled }
        guard !line.arguments.isEmpty else { return Names.Setup.jobUnreadable }
        let isMemory = label == GuardControl.memoryCleanLabel
        let storage = isMemory ? nil : storageCleanClauses(line)
        guard let (does, note, after) = isMemory ? memoryCleanClauses(line).map({ ($0.does, $0.note, nil) }) : storage else {
            return "Only previews: it changes nothing."
        }
        let list = Names.Setup.list(does)
        let lead = after.map { "Everything \($0) does, plus it \(list)" } ?? list.prefix(1).uppercased() + list.dropFirst()
        return lead + "." + note + " It applies by itself, without a preview."
    }
}
