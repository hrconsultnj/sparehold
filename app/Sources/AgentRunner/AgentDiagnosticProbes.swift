@_spi(TestSupport) import AnalyzersKit
import Foundation

/// `agent-runner --probe-agent-diagnostic`: the Agent Diagnostic's parsers, judged on the fixtures in
/// `app/Fixtures/agent-diagnostic/` only — never the person's real crash reports, agent settings, launchd
/// jobs or logs. The rules it holds (the issue's acceptance criteria, inverted into tests): the fixture
/// `.ips`'s header time is 67 minutes before its file-name time and the parser says so; the memory figures
/// are GB numbers; a confirmed finding cannot exist without a citation; the unknown findings are listed,
/// not dropped; the jobs fixture's findings name the line the fixture script really holds; the planted
/// secret, account name and hostname survive nowhere — not in the parsed model, the redactor's output or
/// the evidence package; the ring fixture parses and its fast-rate stretch is identified; and every TSV
/// header the engine writes is the header the parsers expect (the parity rule).
@MainActor
func probeAgentDiagnostic() -> Never {
    var failed = 0
    func flag(_ label: String, _ got: Bool, _ expected: Bool) {
        let ok = got == expected
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(label)\(ok ? "" : "   (expected \(expected), got \(got))")")
    }
    func expect(_ label: String, _ got: String, _ expected: String) {
        let ok = got == expected
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(label): \(got)\(ok ? "" : "   (expected \(expected))")")
    }

    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = repoRoot.appending(path: "app/Fixtures/agent-diagnostic")

    print("— the crash report: the header time, not the file-name time —")
    // parsed under the incident-shaped name the fixture's header comment says it was saved as —
    // the fixture file's own name carries no timestamp, and fileTime must exist to diverge from
    let report = (try? Data(contentsOf: fixtures.appending(path: "crash-report-fixture.ips")))
        .flatMap { CrashReportParser.parse(data: $0, fileName: "Kernel-2026-11-21-101045.ips") }
    flag("the fixture report parses", report != nil, true)
    guard let report else { ProbeScratch.finish(1) }
    expect("the process is read from the body", report.procName ?? "none", "claunch")
    flag("the event time parses", report.eventTime != nil, true)
    if let event = report.eventTime, let saved = report.fileTime {
        let minutes = saved.timeIntervalSince(event) / 60
        expect("the save divergence is 67 minutes (the incident, inverted into a test)",
               String(format: "%.0f", minutes.rounded()), "67")
    } else {
        flag("the save divergence is 67 minutes", false, true)
    }
    if let panic = report.panicString {
        flag("the panic string survives", panic.contains("userspace watchdog timeout"), true)
    } else {
        flag("the panic string survives", false, true)
    }
    expect("wired memory is GB, not pages", String(format: "%.1f", report.wiredGB ?? -1), "6.0")
    expect("compressed memory is GB", String(format: "%.1f", report.compressedGB ?? -1), "7.0")
    expect("free pages become GB", String(format: "%.1f", report.pagesFreeGB ?? -1), "1.0")
    flag("the compressor's segment limit is read", report.compressorSegmentLimitReached == true, true)
    expect("the swap files are counted", String(report.swapFiles ?? -1), "3")
    expect("the swap usage is GB", String(format: "%.1f", report.swapUsedGB ?? -1), "12.0")
    flag("a divergence this large is its own confirmed finding, cited",
         report.divergenceFinding?.grade == .confirmed && (report.divergenceFinding?.citation?.isEmpty == false), true)
    let jetsam = CrashReportParser.parse(url: fixtures.appending(path: "jetsam-fixture.ips"))
    flag("the jetsam baseline parses", jetsam != nil, true)
    expect("   its process", jetsam?.procName ?? "none", "node")
    let hang = CrashReportParser.parse(url: fixtures.appending(path: "hang-fixture.ips"))
    flag("the hang report parses (its kind is kept, never dropped)", hang != nil, true)

    print("\n— grading: confirmed needs a citation; unknown is listed —")
    flag("a confirmed finding without a citation refuses to construct",
         Finding(id: "x", grade: .confirmed, title: "t", detail: "d") == nil, true)
    flag("   one with a citation builds",
         Finding(id: "x", grade: .confirmed, title: "t", detail: "d", citation: "fixture") != nil, true)
    flag("   a plausible finding needs none",
         Finding(id: "x", grade: .plausible, title: "t", detail: "d") != nil, true)
    let diverged = report.divergenceFinding
    flag("every confirmed finding the fixtures yield carries a citation",
         [diverged].compactMap { $0 }.allSatisfy { !($0.citation ?? "").isEmpty }, true)

    print("\n— the jobs audit: findings carry the line the script really holds —")
    // The fixture scripts pin the lines the audit must name (each file says so in its header comment);
    // the fixture TSV carries those line numbers, and the probe checks the parser hands them back AND
    // that the numbered line in the script file is the text the row quotes.
    func fixtureLine(_ script: String, _ number: Int) -> String {
        let text = (try? String(contentsOf: fixtures.appending(path: "jobs-fixture/scripts/\(script)"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(number - 1).first.map(String.init) ?? ""
    }
    let jobsTSV = """
    \(RunTSV.header("jobs", columns: "label plist script trigger loaded last_run purpose check_id line_no line_text grade"))
    com.fixture.sync	LaunchAgents/com.fixture.sync.plist	scripts/sync-repos.sh	every 86400s	not loaded	-	fixture sync	clean	-	-	clean
    com.fixture.sync	LaunchAgents/com.fixture.sync.plist	scripts/sync-repos.sh	every 86400s	not loaded	-	fixture sync	no-timeout	6	git fetch --all --prune	plausible
    com.fixture.sync	LaunchAgents/com.fixture.sync.plist	scripts/sync-repos.sh	every 86400s	not loaded	-	fixture sync	unbounded-log	7	echo "$(date '+%Y-%m-%d %H:%M:%S') sync done" >> "$HOME/Library/Logs/sync-repos.log"	plausible
    com.fixture.prwatch	LaunchAgents/com.fixture.prwatch.plist	scripts/pr-merge.sh	every 900s	loaded	-	fixture pr watch	dangerous-action	5	gh pr merge --auto --squash --repo fixture-org/fixture-repo	confirmed
    com.fixture.prwatch	LaunchAgents/com.fixture.prwatch.plist	scripts/pr-merge.sh	every 900s	loaded	-	fixture pr watch	missing-path	6	/usr/local/bin/fixture-report-uploader --since 24h	confirmed
    com.fixture.typewriter	LaunchAgents/com.fixture.typewriter.plist	scripts/type-report.sh	at load	loaded	-	fixture typewriter	dangerous-action	4	osascript -e 'tell application "System Events" to keystroke "r" using command down'	confirmed
    com.fixture.typewriter	LaunchAgents/com.fixture.typewriter.plist	scripts/type-report.sh	at load	loaded	-	fixture typewriter	clean	-	-	clean
    """
    flag("the fixture jobs.tsv opens with the header the parser expects",
         RunTSV.headerMatches(jobsTSV, header: RunTSV.header("jobs", columns: "label plist script trigger loaded last_run purpose check_id line_no line_text grade")), true)
    let jobs = JobsAuditParser.parse(tsv: jobsTSV)
    expect("every row parses", String(jobs.count), "7")
    let findings = jobs.compactMap(\.finding)
    expect("five findings over three jobs", String(findings.count), "5")
    let missingRow = jobs.first { $0.checkID == "missing-path" }
    expect("the missing path names its line", String(missingRow?.lineNumber ?? -1), "6")
    flag("   and quotes the script's actual line 6",
         missingRow?.lineText == fixtureLine("pr-merge.sh", 6).trimmingCharacters(in: .whitespaces), true)
    let unbounded = findings.first { $0.id.contains("unbounded-log") }
    flag("the unbounded log quotes the script's actual line 7",
         unbounded?.detail.contains("sync-repos.log") == true &&
         unbounded?.detail == fixtureLine("sync-repos.sh", 7).trimmingCharacters(in: .whitespaces), true)
    let dangerous = findings.filter { $0.grade == .confirmed }
    flag("all three confirmed findings carry citations", dangerous.allSatisfy { !($0.citation ?? "").isEmpty }, true)
    flag("the clean job is listed too, not dropped", jobs.contains { $0.label == "com.fixture.typewriter" && !$0.isFinding }, true)
    flag("a job's listing row carries no check", jobs.filter { !$0.isFinding }.allSatisfy { $0.checkID == nil && $0.lineNumber == nil }, true)

    print("\n— the setup report: secret values are dropped at parse time —")
    let secretValue = "sk-fixture-secret-value"
    let secretRow = "claude-code\tsecret\tANTHROPIC_API_KEY\t\(secretValue)\tconfirmed\tfixture: env.ANTHROPIC_API_KEY"
    let setup = AgentSetupParser.parse(tsv: "\(RunTSV.header("setup", columns: AgentSetupParser.columns))\n\(secretRow)")
    expect("a secret-named key shows the value unread, whatever the engine wrote",
           setup.first?.value ?? "read!", AgentSetupParser.valueNotRead)
    flag("   the planted value string never reaches the parsed model",
         !setup.map(\.value).joined().contains(secretValue), true)
    flag("the concurrency knob is NOT name-matched (its value must read)",
         AgentSetupParser.isSensitive(key: "CLAUDE_CODE_PARALLEL_TASK_COUNT") == false, true)
    flag("   and the token in the settings fixture is name-matched",
         AgentSetupParser.isSensitive(key: "CLAUDE_FIXTURE_HEADER_TOKEN"), true)
    let overLimit = AgentSetupParser.concurrencyFinding(tool: "claude-code", key: "CLAUDE_CODE_PARALLEL_TASK_COUNT",
                                                        actual: 100, settingsPath: "fixture-settings.json")
    expect("concurrency 100 against the documented 20 is a confirmed finding",
           overLimit?.grade.rawValue ?? "?", FindingGrade.confirmed.rawValue)
    flag("   and it cites the documented constant's source",
         overLimit?.citation?.contains(AgentSetupParser.documentedConcurrencyCitation) == true, true)
    let noConfig = AgentSetupParser.missingConfigRow(tool: "codex", documentedPath: "~/.codex/config.toml")
    expect("a tool whose config is missing is an unknown row, never a finding of absence",
           noConfig.grade.rawValue, FindingGrade.unknown.rawValue)
    flag("a PreToolUse hook can block; a Stop hook cannot (the kit's static table)",
         AgentSetupParser.hookCanBlock(event: "PreToolUse") && !AgentSetupParser.hookCanBlock(event: "Stop"), true)

    print("\n— the ring: samples parse and the fast stretch is identified —")
    let ringText = (try? String(contentsOf: fixtures.appending(path: "ring-fixture.tsv"), encoding: .utf8)) ?? ""
    let samples = FlightRecorderSamples.parse(text: ringText)
    expect("every ring row parses", String(samples.count), "12")
    expect("the first sample's disk figure", String(format: "%.1f", samples.first?.diskFreeGB ?? -1), "12.5")
    expect("   its top process by memory", samples.first?.top5.first?.name ?? "none", "Xcode")
    let stretches = FlightRecorderSamples.fastStretches(in: samples)
    flag("the fast-rate stretch is identified", stretches.count >= 1 && (stretches.first?.count ?? 0) >= 5, true)
    flag("   and it is the pressure-rise tail (disk under 2 GB)",
         (stretches.last?.last?.diskFreeGB ?? 99) < 2.0, true)

    print("\n— the timeline: the window anchors on the event, rows join one axis —")
    let window = TimelineBuilder.window(around: Date(timeIntervalSince1970: 1_795_252_400))
    expect("the window is the event hour minus sixty, plus ten",
           String(Int(window.upperBound.timeIntervalSince(window.lowerBound) / 60)), "70")
    let timelineTSV = """
    \(RunTSV.header("timeline", columns: "kind iso epoch summary source"))
    report	2026-11-21T10:03:45+01:00	1795251825	report (bug_type 210): Kernel-2026-11-21-101045.ips	DiagnosticReports
    purge	2026-11-21T09:40:00+01:00	1795250400	CacheDelete freed 4.1 GB	unified log
    guard	2026-11-21T09:55:00+01:00	1795251300	PRESSURE critical for 3 samples	guard.log
    recorder	2026-11-21T10:13:00+01:00	1795252380	disk free 3.1 GB	flight-recorder.tsv
    """
    let rows = TimelineBuilder.parse(tsv: timelineTSV)
    expect("every row parses with its kind", String(rows.count), "4")
    expect("   the guard row's kind", rows.first { $0.kind == .guard }.map { String(describing: $0.kind) } ?? "none", "guard")
    flag("a row whose kind is not one of the nine does not parse into a kind",
         TimelineBuilder.parse(tsv: "\(RunTSV.header("timeline", columns: "kind iso epoch summary source"))\nmystery\t2026-11-21T10:00:00+01:00\t1795251600\tx\ty").contains { $0.kind.rawValue == "mystery" } == false, true)

    print("\n— telemetry and the run dir —")
    let telemetry = TelemetryCoverage.parse(tsv: "\(RunTSV.header("telemetry", columns: "layer records retention links gap"))\nhost\tguard.log lines\t~5 MB rotation\tpid\twired over time is missing")
    expect("the coverage row parses", telemetry.first?.layer ?? "none", "host")
    let runDir = fixtures.appending(path: "run-fixture")
    let run = DiagnosticRunParser.load(directory: runDir)
    flag("a run directory loads (fixture TSVs where present)", run != nil, true)
    expect("   the run names its own TSVs in run.log's last line",
           run?.namedFiles.joined(separator: " ") ?? "none", "reports.tsv timeline.tsv jobs.tsv setup.tsv telemetry.tsv")
    expect("   the run's timeline rows", String(run?.timeline.count ?? -1), "5")
    expect("   the run's findings (three over the clean job)", String(run?.jobs.compactMap(\.finding).count ?? -1), "3")
    expect("   the run's setup rows, secret value unread",
           run?.setup.first { $0.topic == "secret" }?.value ?? "read!", AgentSetupParser.valueNotRead)
    expect("   the run's telemetry layers", String(run?.telemetry.count ?? -1), "4")

    print("\n— redaction and the evidence package: nothing planted survives —")
    let fixtureHome = URL(fileURLWithPath: "/Users/fixture-alice")
    let redactor = EvidenceRedactor(home: fixtureHome, user: "fixture-alice", host: "fixture-mac.local")
    let planted = "claunch log at /Users/fixture-alice/Library/Logs/claunch.log on fixture-mac.local, token sk-fixture-secret-value, ghp_fixtureplaceholdervalue000000000"
    let redacted = redactor.redact(planted)
    flag("the planted account name is gone", !redacted.contains("fixture-alice"), true)
    flag("the planted hostname is gone", !redacted.contains("fixture-mac.local"), true)
    flag("the sk- token is gone", !redacted.contains("sk-fixture-secret-value"), true)
    flag("the ghp_ token is gone", !redacted.contains("ghp_fixtureplaceholdervalue000000000"), true)
    flag("   the home path became ~", redacted.contains("~/Library/Logs/claunch.log"), true)
    let evidence = EvidencePackage.build(
        redactor: redactor,
        verdict: "Wired memory climbed while free disk fell to under 1 GB; report saved 67 minutes late.",
        timelineHeadline: ["\(planted) at 10:03"],
        memoryAtEvent: ["wired 6.0 GB", "compressed 7.0 GB"],
        auditFindings: dangerous,
        setupDeltas: setup,
        coverageGaps: ["wired memory over time is missing"],
        decisions: [])
    flag("the evidence package holds no planted name, host or token",
         !evidence.contains("fixture-alice") && !evidence.contains("fixture-mac.local") &&
         !evidence.contains("sk-fixture-secret-value") && !evidence.contains("ghp_fixtureplaceholdervalue000000000"), true)
    flag("   the package is markdown with the verdict on top", evidence.hasPrefix("# Agent Diagnostic"), true)
    flag("   the findings carry their line citations", evidence.contains("com.fixture.prwatch"), true)

    print("\n— header parity: the engine's five TSVs open with the headers the parsers expect —")
    let expectedHeaders = [
        RunTSV.header("reports", columns: "path bug_type event_iso event_epoch file_iso divergence_min proc panic_first_line"),
        RunTSV.header("timeline", columns: "kind iso epoch summary source"),
        RunTSV.header("jobs", columns: "label plist script trigger loaded last_run purpose check_id line_no line_text grade"),
        RunTSV.header("setup", columns: AgentSetupParser.columns),
        RunTSV.header("telemetry", columns: "layer records retention links gap"),
    ]
    let engine = (try? String(contentsOf: repoRoot.appending(path: "agent-diagnostic/agent-diagnostic.sh"), encoding: .utf8)) ?? ""
    for header in expectedHeaders {
        flag("the engine writes: \(String(header.dropFirst(2)).prefix(46))…", engine.contains(header), true)
    }
    flag("the ring header the recorder writes is the one the samples parse",
         engine.contains("# sparehold flight recorder v1: iso epoch disk_free_gb swap_used_mb swap_files wired_mb compressed_mb pressure procs top5") ||
         (try? String(contentsOf: repoRoot.appending(path: "memory/memory-guard.sh"), encoding: .utf8))?.contains("# sparehold flight recorder v1: iso epoch disk_free_gb swap_used_mb swap_files wired_mb compressed_mb pressure procs top5") == true, true)

    print("\n\(failed == 0 ? "all agent-diagnostic rules hold" : "\(failed) agent-diagnostic rule(s) broken")")
    ProbeScratch.finish(failed == 0 ? 0 : 1)
}
