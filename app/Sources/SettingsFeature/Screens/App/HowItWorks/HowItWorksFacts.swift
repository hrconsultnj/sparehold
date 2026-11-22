import Foundation
import Observation
import AnalyzersKit

/// This Mac's own numbers, as the topics quote them. Every figure comes from the kernel that already owns it (the memory
/// breakdown, the config reader, the schedules, the guard log through Trends, the disk runway, the kind catalog): this
/// file reads them once and never classifies or counts a second way.
struct HowItWorksFacts: Sendable {
    struct Week: Sendable {
        var stopped = 0, spikes = 0, pressure = 0, cpuHogs = 0
        var memoryFreedMB = 0
        var storageFreedBytes: Int64 = 0
        var cleanRuns = 0
        var reclaimableBytes: Int64?
    }

    /// One background job as it is INSTALLED on this Mac: when it runs, and whether the installed command applies what it
    /// finds by itself (`--apply`) or only previews. Read from the plist through `ScheduleKit`, never assumed.
    struct ScheduleLine: Identifiable, Sendable {
        let label: String
        let name: String
        let installed: Bool
        let when: String?
        /// What the installed plist passes to the script; empty when the command could not be read.
        let arguments: [String]
        /// nil when the installed command could not be read.
        var appliesByItself: Bool? { arguments.isEmpty ? nil : arguments.contains("--apply") }
        var id: String { label }
    }

    var memory: MemoryBreakdown?
    var disk: DiskUsage?
    var runway: String?
    var week = Week()
    /// The week's figures and the disk runway read whole logs and arrive after the rest: until `logsRead`, the topics leave
    /// out any sentence that quotes them rather than say "0".
    var logsRead = false

    // the settings the topics quote
    var hardCapMB = 6144
    var hardCapStops = true
    var pressureStops = true
    var spikeMB = 400
    var spikeMinMB = 1024
    var cpuHogPercent = 150
    var cpuHogChecks = 3
    var guardIntervalSeconds = 15
    var devSweepSeconds = 120
    var worktreeIdleDays = 0
    var toolCaches: [String] = []
    /// A bash newer than the 3.2 macOS ships, where `memory-auto-clean.sh` can run the parts that need one (it looks in these two places).
    var newerBashInstalled = false
    var tempIdleHours = 24
    var tempAgentScratchDays = 3
    var tempToolDownloadDays = 14
    var protectedExtra = 0
    var alsoQuit = 0
    var downloadsDays = 30
    var screenshotsDays = 14
    var nodeModulesDays = 14
    var nodeModulesNeedClean = true
    var recordingsDays = 90
    var turboCacheMaxGB = 2

    /// The kinds of program the guard may stop by itself: the kind catalog's developer-tooling kinds, by name.
    var devToolKinds: [String] = []
    var schedules: [ScheduleLine] = []
    var channel = UpdateChannel.releases
    var guardLogBytes: Int64?
    var timeMachinePermission = false
    var version = ""

    // the Ask agent's switches, as this Mac has them set (the settings file's AGENT_CAPABILITIES, through ConfigStore)
    var agentCapabilitiesOn = AgentCapability.defaultEnabledIDs.count
    var agentPreludeSet = false

    /// The Trash ledger as Undo reads it (whole logs, so it arrives with `logsRead`): the things this Mac's cleanups
    /// moved to the Trash, and how many can still be put back. nil until read.
    var trashedCount: Int?
    var restorableCount: Int?

    // MARK: - sentences the topics share
    // A value that was not read is nil, and the sentence that would quote it is left out (never a stand-in word).

    var totalMemory: String? { memory.map { ByteSize.text($0.totalBytes, .headline) } }
    var usedMemory: String? { memory.map { ByteSize.text($0.usedBytes, .headline) } }
    var compressed: String? { memory.map { ByteSize.text($0.compressedBytes, .headline) } }
    var compressedOriginal: String? { memory.map { ByteSize.text($0.compressedOriginalBytes, .headline) } }
    var limit: String { megabytes(hardCapMB) }
    /// "about 20 percent of your 32 GB", when this Mac's memory was read.
    var limitShare: String? {
        guard let memory, memory.totalBytes > 0, let total = totalMemory else { return nil }
        let share = Double(hardCapMB) * 1_048_576 / Double(memory.totalBytes)
        return "about \(Int((share * 100).rounded())) percent of your \(total)"
    }
    var freeDisk: String? { disk.map { ByteSize.text($0.freeBytes, .headline) } }
    var totalDisk: String? { disk.map { ByteSize.text($0.totalBytes, .headline) } }
    /// "6.5 GB, about 20 percent of your 32 GB", or just "6.5 GB".
    var limitPhrase: String { limitShare.map { "\(limit), \($0)" } ?? limit }
    /// "1 day", "14 days".
    func days(_ n: Int) -> String { "\(n) \(n == 1 ? "day" : "days")" }
    /// A size kept in megabytes, written the way every size in the app is (`ByteSize`).
    func megabytes(_ mb: Int) -> String { ByteSize.text(Int64(mb) * 1_048_576, .headline) }

    func schedule(_ label: String) -> ScheduleLine? { schedules.first { $0.label == label } }

    /// "1 hour", "24 hours".
    func hours(_ n: Int) -> String { "\(n) \(n == 1 ? "hour" : "hours")" }
    /// "every 15 seconds", "every second".
    var guardEvery: String { guardIntervalSeconds == 1 ? "every second" : "every \(guardIntervalSeconds) seconds" }

    /// A job that is installed but has no schedule runs only when something starts it.
    func notScheduled(_ label: String) -> String {
        "\(schedule(label)?.name ?? label) is not scheduled on this Mac."
    }

    /// The agent's capability switches, as a count against the fixed catalog.
    var agentCapabilitiesTotal: Int { AgentCapability.all.count }

    /// "4 of the 5 capabilities are switched on on this Mac."
    var agentCapabilitiesLine: String {
        let on = agentCapabilitiesOn
        return "\(on) of the \(agentCapabilitiesTotal) capabilities \(on == 1 ? "is" : "are") switched on on this Mac."
    }

    /// "3 of the 4 things the cleanups moved to the Trash can still be put back", said only when the ledger was read.
    var undoLine: String? {
        guard let trashedCount, let restorableCount else { return nil }
        guard trashedCount > 0 else { return "Nothing the cleanups moved to the Trash is sitting there right now." }
        return "\(restorableCount) of the \(trashedCount) \(trashedCount == 1 ? "thing" : "things") the cleanups moved to the Trash can still be put back."
    }
}

extension HowItWorksFacts {
    /// The quick part of the facts: the settings the sentences quote and the installed schedules, read from the config and the
    /// plists only (no log, no process, no `sudo`). The topics start from it and add the rest; the Schedule pane's captions
    /// use it alone.
    @MainActor static func read() -> HowItWorksFacts {
        var f = HowItWorksFacts()
        let config = ConfigStore()
        f.hardCapMB = config.memory.hardCapMB
        f.hardCapStops = config.memory.hardCapKill
        f.pressureStops = config.memory.pressureKill
        f.spikeMB = config.memory.spikeMB
        f.spikeMinMB = config.memory.spikeMinMB
        f.cpuHogPercent = config.memory.cpuHogPct
        f.cpuHogChecks = config.memory.cpuHogTicks
        f.guardIntervalSeconds = config.memory.guardIntervalSeconds
        f.devSweepSeconds = config.memory.devSweepSeconds
        f.worktreeIdleDays = config.storage.worktreeIdleDays
        f.toolCaches = config.storage.toolCaches
        f.newerBashInstalled = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        f.tempIdleHours = config.storage.tempIdleHours
        f.tempAgentScratchDays = config.storage.tempAgentScratchDays
        f.tempToolDownloadDays = config.storage.tempToolDownloadDays
        f.protectedExtra = config.memory.protectExtra.count
        f.alsoQuit = config.memory.reclaimApps.count
        f.downloadsDays = config.storage.janitorDownloadsDays
        f.screenshotsDays = config.storage.janitorScreenshotsDays
        f.nodeModulesDays = config.storage.nmAgeDays
        f.nodeModulesNeedClean = config.storage.nmRequireClean
        f.recordingsDays = config.storage.recordingsDays
        f.turboCacheMaxGB = config.storage.turboCacheMaxGB
        f.agentCapabilitiesOn = config.agent.capabilities.count
        f.agentPreludeSet = !config.agent.prelude.isEmpty
        f.schedules = ScheduleKit.jobs.map { job in
            let installed = ScheduleKit.isInstalled(job.label)
            return HowItWorksFacts.ScheduleLine(
                label: job.label, name: Names.Setup.jobTitle(job.label), installed: installed,
                // a plist with no schedule key never runs by itself: it has no time to quote
                when: installed && ScheduleKit.schedule(for: job.label) != nil ? ScheduleKit.describe(job.label) : nil,
                arguments: ScheduleKit.programArguments(for: job.label) ?? [])
        }
        return f
    }
}

/// Loads the facts once and keeps them for a minute, so opening a topic from the list does not read the logs again.
@MainActor @Observable
final class HowItWorksModel {
    static let shared = HowItWorksModel()

    private(set) var facts: HowItWorksFacts?
    private var loadedAt = Date.distantPast

    func load() async {
        if facts?.logsRead == true, Date().timeIntervalSince(loadedAt) < 60 { return }
        var f = HowItWorksFacts.read()
        f.devToolKinds = KindCatalog.current.kinds.filter(\.devTooling).map(\.name)
        f.channel = UpdateChannel.saved
        f.timeMachinePermission = await TimeMachinePermission.isAllowed()
        f.version = BuildInfo.current.shortVersion
        f.disk = LiveStats.diskUsage()
        if let size = try? FileManager.default.attributesOfItem(atPath: AnalyzersPaths.guardLog.path)[.size] as? Int64 {
            f.guardLogBytes = size
        }
        await awaitLoad({ MemoryBreakdown.current() }, ttl: 10, key: "howItWorks.memory") { f.memory = $0 }
        guard !Task.isCancelled else { return }
        // the screen opens now, with everything that was quick to read
        facts = f
        loadedAt = Date()
        await awaitLoad({ DiskRunway.current()?.text }, ttl: 60, key: "howItWorks.runway") { f.runway = $0 }
        await awaitLoad({ TrendsModel.snapshot(period: .week) }, ttl: 60, key: "howItWorks.week") { snapshot in
            f.week = .init(stopped: snapshot.kills, spikes: snapshot.spikes, pressure: snapshot.pressure,
                           cpuHogs: snapshot.cpuHogs, memoryFreedMB: snapshot.memoryFreedMB,
                           storageFreedBytes: snapshot.storageFreedBytes, cleanRuns: snapshot.cleanRuns,
                           reclaimableBytes: snapshot.latestReclaimableBytes)
        }
        // the same read the Undo screen makes, counted once: what the Trash ledger holds right now
        await awaitLoad({ UndoModel.take() }, ttl: 60, key: "howItWorks.undo") { model in
            let trashed = model.entries.filter { $0.scope == .trashed }
            f.trashedCount = trashed.count
            f.restorableCount = trashed.filter(\.isRestorable).count
        }
        guard !Task.isCancelled else { return }
        f.logsRead = true
        facts = f
        loadedAt = Date()
    }
}
