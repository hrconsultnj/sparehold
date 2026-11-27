import AnalyzersKit
import Foundation

/// The Agent Diagnostic's render fixtures: the same fixture TSVs the probe
/// judges (`app/Fixtures/agent-diagnostic/run-fixture/`), parsed through the
/// real parser — a render shows what a run would actually look like. The app
/// never calls these; only `SnapshotRunner` does.
@MainActor
enum AgentDiagnosticFixtures {

    static func run() -> DiagnosticRun? {
        DiagnosticRunParser.load(directory: directory)
    }

    /// `app/Fixtures/agent-diagnostic/run-fixture/`, found from this source file.
    private static var directory: URL {
        var url = URL(fileURLWithPath: #filePath)          // …/app/Sources/SettingsFeature/Screens/System/AgentDiagnostic/AgentDiagnosticFixtures.swift
        for _ in 0..<6 { url.deleteLastPathComponent() }    // the repo root
        return url.appending(path: "app/Fixtures/agent-diagnostic/run-fixture")
    }
}
