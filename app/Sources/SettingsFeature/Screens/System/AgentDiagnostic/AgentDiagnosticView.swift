import AnalyzersKit
import SwiftUI
import UIComponents

/// Agent Diagnostic: what led up to a freeze, read from the records that
/// already exist. Six tabs, one run at a time; the run is a tracked job the
/// person starts (never scheduled, never automatic — the restart banner only
/// suggests). Every word on the screen comes from the kit's parsers; the
/// screen decides nothing about what the data means.
///
/// The tabs are the shared bar under the toolbar. Toolbar: Run (primary),
/// Copy Evidence, Show Source, Past Runs and Stop ride the secondary rank.
struct AgentDiagnosticView: View {

    /// Example rows for `SnapshotRunner`; nil in the app.
    var fixture: DiagnosticRun?
    /// `SnapshotRunner`: past-run entries shown without a run on disk.
    var fixturePastRuns = 0
    /// `SnapshotRunner`: the screen as it is with nothing on disk and no restart to suggest.
    var fixtureNoneOn = false

    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case timeline, jobs, setup, telemetry, findings, decisions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .timeline: Names.DiagnosticScope.timeline
            case .jobs: Names.DiagnosticScope.jobs
            case .setup: Names.DiagnosticScope.setup
            case .telemetry: Names.DiagnosticScope.telemetry
            case .findings: Names.DiagnosticScope.findings
            case .decisions: Names.DiagnosticScope.decisions
            }
        }
        var symbol: String {
            switch self {
            case .timeline: "clock.arrow.circlepath"
            case .jobs: "list.bullet.rectangle"
            case .setup: "switch.2"
            case .telemetry: "waveform.path.ecg"
            case .findings: "flag.2.crossed"
            case .decisions: "checklist"
            }
        }
        /// The row count the tab shows on its label, nil while nothing is read.
        func count(in run: DiagnosticRun?) -> Int? {
            guard let run else { return nil }
            switch self {
            case .timeline: return run.timeline.count
            case .jobs: return run.jobs.compactMap(\.finding).count
            case .setup: return run.setup.count
            case .telemetry: return run.telemetry.count
            case .findings: return run.jobs.compactMap(\.finding).count
            case .decisions: return run.jobs.compactMap(\.finding).count
            }
        }
    }

    @Environment(JobStore.self) private var store
    @Environment(Navigator.self) private var navigator
    @State private var model = AgentDiagnosticModel()
    @State private var scope: Scope = .timeline

    private var tabs: [ScopeTabItem<Scope>] {
        let run = fixture ?? model.parsed
        func count(_ number: Int?) -> Int? { model.loaded ? number : nil }
        return Scope.allCases.map { tab in
            ScopeTabItem(value: tab, title: tab.title, symbol: tab.symbol, count: count(tab.count(in: run)))
        }
    }

    var body: some View {
        DataScreen(title: Names.Screen.agentDiagnostic, subtitle: subtitle) { content }
            .helpTopic(.agentDiagnostic, screen: Names.Screen.agentDiagnostic)
            .scopeTabsToolbar(screen: "agentDiagnostic", items: tabs, selection: $scope)
            .toolbar { toolbar }
            .task {
                guard fixture == nil, !fixtureNoneOn else { return }
                model.adopt(from: store)
                await model.reload()
            }
    }

    @ViewBuilder private var content: some View {
        if let fixture {
            tabContent(fixture)
        } else if fixtureNoneOn {
            EmptyState("Nothing Has Run Yet", systemImage: "stethoscope",
                       description: Text("The diagnostic reads crash reports, the unified log, launchd jobs and the Memory Guard's record. It changes nothing."))
        } else if model.isRunning {
            LoadingState("Reading the hour around the event…", detail: "The unified log's query is bounded by the window, but it can take a minute or two.") {
                Button("Stop", action: model.stop)
            }
        } else if let run = model.parsed {
            tabContent(run)
        } else if let failure = model.failure {
            EmptyState {
                Label("Couldn't Run the Diagnostic", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Run Agent Diagnostic") { model.run(in: store) }
            }
        } else if model.loaded {
            empty
        } else {
            LoadingState("Reading past runs…")
        }
    }

    /// The empty state, with the restart banner when this Mac came back after the newest run.
    private var empty: some View {
        EmptyState {
            Label("Nothing Has Run Yet", systemImage: "stethoscope")
        } description: {
            Text("The diagnostic reads crash reports, the unified log, launchd jobs and the Memory Guard's record to rebuild the hour before an unexpected restart or freeze. It changes nothing.")
        } actions: {
            if model.suggestsRunAfterRestart {
                Label("Your Mac restarted unexpectedly — run the diagnostic to see what led up to it.",
                      systemImage: "arrow.counterclockwise")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Run Agent Diagnostic") { model.run(in: store) }
        }
    }

    private var subtitle: String {
        guard let run = fixture ?? model.parsed else { return "Reads the records; changes nothing." }
        let confirmed = run.timeline.count
        return "\(Names.Screen.agentDiagnostic) — \(confirmed) timeline row\(confirmed == 1 ? "" : "s") in the newest run."
    }

    @ViewBuilder private func tabContent(_ run: DiagnosticRun) -> some View {
        switch scope {
        case .timeline: TimelineTab(rows: run.timeline, reportNames: reportNames(run))
        case .jobs: JobsAuditTab(rows: run.jobs)
        case .setup: AgentSetupTab(rows: run.setup)
        case .telemetry: TelemetryTab(rows: run.telemetry)
        case .findings: FindingsTab(findings: allFindings(run))
        case .decisions: DecisionsTab(decisions: DecisionList.forFindings(allFindings(run)))
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.run(in: store)
            } label: {
                Label("Run Agent Diagnostic", systemImage: "play.fill")
            }
            .disabled(model.isRunning)
            .help("Rebuilds the hour around the newest crash report. Takes a minute or two.")

            Button {
                copyEvidence()
            } label: {
                Label("Copy Evidence", systemImage: "doc.on.doc")
            }
            .disabled((fixture ?? model.parsed) == nil)
            .help("The redacted markdown package: verdict, timeline, findings, decisions. Nothing leaves this Mac but what you paste.")

            Button {
                showSource()
            } label: {
                Label("Show Source", systemImage: "doc.text")
            }
            .disabled(fixture == nil && model.viewing == nil)
            .help("The run's own log, as the engine wrote it.")
        }
        .toolbarRank(.primary)

        ToolbarItemGroup {
            Menu {
                ForEach(model.runs) { run in
                    Button(run.stamp) { model.select(run.id) }
                }
            } label: {
                Label("Past Runs", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.runs.isEmpty && fixturePastRuns == 0 && fixture == nil)
            .help("Runs already on disk, newest first.")

            if model.isRunning {
                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!model.isRunning)
            }
        }
        .toolbarRank(.secondary)
    }

    // MARK: actions

    private func copyEvidence() {
        guard let run = fixture ?? model.parsed else { return }
        let redactor = EvidenceRedactor()
        let findings = allFindings(run)
        let text = EvidencePackage.build(
            redactor: redactor,
            verdict: evidenceVerdict(run),
            timelineHeadline: run.timeline.prefix(12).map(\.summary),
            memoryAtEvent: memoryFigures(run),
            auditFindings: findings.filter { $0.grade == .confirmed },
            setupDeltas: run.setup,
            coverageGaps: run.telemetry.map(\.gap),
            decisions: DecisionList.forFindings(findings))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showSource() {
        guard let viewing = model.viewing ?? model.runs.first else { return }
        navigator.push(.overview(.raw(.file(viewing.directory.appending(path: "run.log"), fromTop: true))))
    }

    // MARK: pieces the tabs and the evidence share

    private func allFindings(_ run: DiagnosticRun) -> [Finding] {
        run.jobs.compactMap(\.finding)
        + crashFindings(run)
    }

    /// The findings the reports table carries on its own: a save-time divergence is one.
    private func crashFindings(_ run: DiagnosticRun) -> [Finding] {
        run.timeline.filter { $0.summary.contains("saved ") && $0.summary.contains("after it happened") }
            .compactMap { row in
                Finding(id: row.id, grade: .confirmed,
                        title: "A report was saved long after its event",
                        detail: row.summary,
                        citation: "\(row.source) at \(row.iso)")
            }
    }

    private func reportNames(_ run: DiagnosticRun) -> [String] {
        run.timeline.filter { $0.kind == .report }.map(\.source)
    }

    private func evidenceVerdict(_ run: DiagnosticRun) -> String {
        let reports = run.timeline.filter { $0.kind == .report }.count
        let findings = allFindings(run)
        let confirmed = findings.filter { $0.grade == .confirmed }.count
        return "The newest run read \(reports) report row(s), \(run.jobs.count) launchd job row(s) and \(run.setup.count) setup row(s): \(confirmed) confirmed finding(s), \(findings.count - confirmed) plausible or unknown."
    }

    private func memoryFigures(_ run: DiagnosticRun) -> [String] {
        run.timeline.filter { $0.kind == .recorder }.prefix(3).map(\.summary)
    }
}

/// The screen suggests a run when this Mac's newest boot is newer than its newest diagnostic run —
/// a suggestion with a button, never an automatic run (DEC-6).
extension AgentDiagnosticModel {
    var suggestsRunAfterRestart: Bool {
        guard let boot = lastBoot, let newest else { return false }
        return boot > newest.written
    }
}
