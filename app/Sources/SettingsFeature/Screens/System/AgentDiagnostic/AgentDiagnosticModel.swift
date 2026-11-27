import AnalyzersKit
import Foundation
import Observation

/// The diagnostic runs on disk and the job that makes one. A run is a
/// timestamped folder under `reports/agent-diagnostic/<date>/`; the screen
/// reads its TSVs through the kit's parsers and never parses anything itself.
@MainActor @Observable
final class AgentDiagnosticModel {

    /// One run folder, newest first: its directory and when it was written.
    struct RunSummary: Identifiable, Hashable, Sendable {
        let directory: URL
        let written: Date
        var id: String { directory.lastPathComponent }
        /// The date folder's day, as the run's stamp names it ("2026-11-22 18:45").
        var stamp: String {
            let time = directory.lastPathComponent.dropFirst("agent-diagnostic-".count)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let parsed = formatter.date(from: directory.deletingLastPathComponent().lastPathComponent + " " + time.replacingOccurrences(of: "-", with: ":"))
            return parsed.map { formatter.string(from: $0) } ?? directory.lastPathComponent
        }
    }

    private(set) var runs: [RunSummary] = []
    private(set) var loaded = false
    /// The job this screen shows, found again by kind when the window reopens mid-run.
    private(set) var job: Job?
    /// Which run the screen shows; nil shows the newest.
    var viewingID: String?

    var isRunning: Bool { job?.isActive ?? false }
    var failure: String? { job?.failureMessage }

    var newest: RunSummary? { runs.first }

    /// The run the screen shows: the picked one, or the newest.
    var viewing: RunSummary? {
        viewingID.flatMap { id in runs.first { $0.id == id } } ?? newest
    }

    /// The picked run parsed: nil when nothing is on disk yet or the pick failed to read.
    private(set) var parsed: DiagnosticRun?
    private(set) var parsedID: String?

    /// The most recent boot, read from `last reboot`; the restart banner compares it with the newest run.
    private(set) var lastBoot: Date?

    func adopt(from store: JobStore) {
        job = store.latest(.agentDiagnostic, intents: [.run])
    }

    /// Starts the tracked, cancellable run. Nothing here runs on appear —
    /// the person presses Run (DEC-6).
    func run(in store: JobStore) {
        job = store.enqueue(JobRequest(kind: .agentDiagnostic, intent: .run), trigger: .user)
    }

    func stop() { job?.cancel() }

    func select(_ id: String?) { viewingID = id }

    func reload() async {
        let root = AnalyzersPaths.agentDiagnosticReports
        let boot = await Task.detached(priority: .userInitiated) { () -> Date? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/last")
            process.arguments = ["reboot"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            // "reboot  ~  Fri Nov 21 09:03  — the second field pair is the boot
            let line = text.split(separator: "\n").first.map(String.init) ?? ""
            let stamp = line.replacingOccurrences(of: "reboot", with: "").trimmingCharacters(in: .whitespaces)
            guard stamp.hasPrefix("~") else { return nil }
            let rest = stamp.dropFirst().trimmingCharacters(in: .whitespaces)
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d HH:mm yyyy"
            return formatter.date(from: rest)
        }.value
        var found: [RunSummary] = []
        let manager = FileManager.default
        if let days = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            for day in days.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                guard let children = try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: nil) else { continue }
                for child in children where child.lastPathComponent.hasPrefix("agent-diagnostic-") {
                    let written = (try? child.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    found.append(RunSummary(directory: child, written: written))
                }
            }
        }
        found.sort { $0.written > $1.written }
        runs = found
        lastBoot = boot
        loaded = true
        await parseSelected()
    }

    /// Parses the picked run's TSVs, off the main thread. Re-parses when the pick changes or the run rewrites.
    func parseSelected() async {
        guard let viewing else { parsed = nil; parsedID = nil; return }
        guard viewing.id != parsedID else { return }
        let directory = viewing.directory
        let read = await Task.detached(priority: .userInitiated) {
            DiagnosticRunParser.load(directory: directory)
        }.value
        parsed = read
        parsedID = viewing.id
    }
}
