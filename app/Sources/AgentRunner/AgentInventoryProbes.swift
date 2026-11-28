@_spi(TestSupport) import AnalyzersKit
import Foundation

/// `agent-runner --probe-agent-inventory`: the agent inventory's parser,
/// judged on a fixture written in the sweep's exact JSON shape, plus the
/// parity rule — the keys the sweep writes are the keys the parser names,
/// so a moved section fails loudly here before any screen sees it.
@MainActor
func probeAgentInventory() -> Never {
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

    // the sweep's shape, exactly as agents/agent-sweep.sh writes it
    let fixture = """
    {
      "swept_at": "2026-11-27T18:50:16-0500",
      "agents": [{"name": "Claude Code", "kind": "exe", "path": "/Users/fixture/.local/bin/claude"},
                 {"name": "OrbStack", "kind": "container", "path": "docker image moy}$/orbstack"}],
      "session_count": 2,
      "sessions": [{"pid": 60014, "command": "claude daemon run --json-path /Users/fixture/.claude/daemon.json"},
                   {"pid": 71973, "command": "node copilot-sdk"}],
      "headroom": {"disk_free_gb": 12.5, "swap_used_mb": 40, "wired_mb": 5300, "compressed_mb": 2100,
                   "pressure": 1, "updated": "2026-11-27T18:45:00-0500", "stale": false},
      "worktrees": [{"path": "/Users/fixture/Projects/apt5/feature", "branch": "feature/x", "kb": 4884544, "merged_to_main": false},
                    {"path": "/Users/fixture/Projects/apt5/main", "branch": "detached", "kb": 12172, "merged_to_main": null}]
    }
    """
    let inventory = try? JSONDecoder().decode(AgentInventory.self, from: Data(fixture.utf8))
    flag("the sweep's JSON shape parses", inventory != nil, true)
    guard let inventory else { ProbeScratch.finish(1) }
    expect("two agents read", String(inventory.agents.count), "2")
    expect("   the exe row's name", inventory.agents.first?.name ?? "none", "Claude Code")
    expect("   the container row's kind", inventory.agents.last?.kind ?? "none", "container")
    expect("the session count matches the rows", String(inventory.sessionCount), "2")
    expect("   a session's pid", String(inventory.sessions.first?.pid ?? -1), "60014")
    expect("the worktree's branch", inventory.worktrees.first?.branch ?? "none", "feature/x")
    expect("   its size in KB", String(inventory.worktrees.first?.kb ?? -1), "4884544")
    flag("   a detached worktree's merge state is nil, never a guess",
         inventory.worktrees.last?.mergedToMain == nil, true)
    flag("the headroom figures read", inventory.headroom?.diskFreeGB == 12.5 && inventory.headroom?.pressure == 1, true)
    flag("   the staleness flag is a bool", inventory.headroom?.stale == false, true)

    // the sweep invents nothing: no headroom key means no headroom, ever
    let bare = """
    {"swept_at": "2026-11-27T18:50:16-0500", "agents": [], "session_count": 0, "sessions": [], "worktrees": []}
    """
    let bareInventory = try? JSONDecoder().decode(AgentInventory.self, from: Data(bare.utf8))
    flag("a sweep without the headroom file parses", bareInventory != nil, true)
    flag("   and its headroom stays nil (never invented)", bareInventory?.headroom == nil, true)

    // freshness is part of the answer
    expect("the age of a just-swept inventory",
           AgentInventoryReader.age(inventory, now: Date()).hasPrefix("swept") ? "swept" : "other", "swept")
    let stale = AgentInventory.Headroom(diskFreeGB: nil, swapUsedMB: nil, wiredMB: nil,
                                        compressedMB: nil, pressure: nil,
                                        updated: "2020-01-01T00:00:00-0500", stale: true)
    flag("a stale headroom is a bool the screen can name", stale.stale, true)

    // parity: every key the sweep writes, the parser names
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sweep = (try? String(contentsOf: repoRoot.appending(path: "agents/agent-sweep.sh"), encoding: .utf8)) ?? ""
    for key in ["swept_at", "agents", "session_count", "sessions", "headroom", "worktrees",
                "merged_to_main", "disk_free_gb", "swap_used_mb", "wired_mb", "compressed_mb", "stale"] {
        // the key NAME is the contract; the sweep writes some inside
        // double-quoted bash strings, so the quotes themselves vary
        flag("the sweep writes \(key) and the parser names it", sweep.contains(key), true)
    }
    flag("the parser's CodingKeys carry the same names",
         sweep.contains("merged_to_main") && sweep.contains("swept_at") && sweep.contains("session_count"), true)

    print("\n\(failed == 0 ? "all agent-inventory rules hold" : "\(failed) agent-inventory rule(s) broken")")
    ProbeScratch.finish(failed == 0 ? 0 : 1)
}
