import Foundation
import AnalyzersKit

/// The System tab's topics.
extension HowItWorksTopic {

    func systemContent(_ f: HowItWorksFacts) -> TopicContent {
        switch self {
        case .loginItems:
            return TopicContent(
                summary: "Everything on this Mac that starts by itself, and what is new.",
                what: "Some things start by themselves when you log in or when the Mac boots. This screen lists all of them, says which app each belongs to, and flags the leftovers of apps you already removed.",
                does: [
                    "The audit lists what starts by itself on this Mac: login items, launch agents, launch daemons and helper tools, and the leftovers of apps you removed. Each one says which app it belongs to and how it is doing.",
                    "Sparehold also checks at launch and every 6 hours for something new that installed itself to run at login or boot, and tells you once.",
                ],
                onThisMac: [],
                never: ["The audit only reads. Nothing is blocked, and nothing is removed unless you choose it and confirm."],
                written: ["Changes to what starts by itself are written down as they are noticed (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.loginItems)", detail: "See everything that starts by itself, with the leftovers to review",
                                target: "loginitems")],
                question: .init(ask: "If I remove a login item, does the app stop working?",
                                answer: "No. Removing a login item only stops it starting by itself; the app opens as always when you open it yourself."))

        case .network:
            return TopicContent(
                summary: "Which programs sent and received data, as snapshots you take.",
                what: "macOS keeps a running total of the data each program has sent and received since it started. This screen reads those totals as a snapshot, so you can see who has been using the network and compare with the past.",
                does: [
                    "A snapshot reads how much data each program on this Mac has sent and received since it started, so you can see which ones have been using the network. Past snapshots are kept so you can compare.",
                ],
                onThisMac: [],
                never: ["Nothing is captured, blocked or changed. Only the totals the system already keeps are read, and only when you take a snapshot."],
                written: ["Snapshots are kept in your records folder (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.network)", detail: "Take a snapshot to see which programs sent and received data",
                                target: "network")],
                question: .init(ask: "Is anything captured or blocked?",
                                answer: "No. Only the totals the system already keeps are read, and only when you take a snapshot; nothing is watched while you are not looking."))

        case .agentDiagnostic:
            return TopicContent(
                summary: "What led up to a freeze, rebuilt from the records that already exist.",
                what: "When the Mac freezes or restarts unexpectedly, the crash report alone explains little — the evidence is scattered across crash reports, the system log, launchd jobs and the Memory Guard's own record. The Agent Diagnostic reads them all together, for the hour around the event, and grades what it finds: confirmed (with the line or log it came from), plausible, or unknown.",
                does: [
                    "Run reads the newest crash report's own header time — never the file name's, which can be saved long after the event — and rebuilds the hour around it: when the disk was freed, when the Memory Guard noticed pressure, which jobs fired or were created, which agent sessions were active.",
                    "The Jobs Audit lists every launchd job with the line that trips each check: a call with no timeout, a log that grows forever, a path that is not there, an unattended merge or keystroke injection.",
                    "Agent Setup reads what Claude Code and Codex are set to — with one rule: a key that looks like a secret shows its name and never its value, dropped before anything is shown.",
                    "Copy Evidence puts the redacted markdown on your clipboard: nothing personal, nothing secret, ready to paste into a bug report.",
                ],
                onThisMac: [],
                never: ["The diagnostic only reads. It never edits, stops, deletes or signals anything, and it never runs what it inspects. The decision list recommends — there is no Apply button anywhere on it."],
                written: ["Each run writes its own folder under reports/agent-diagnostic/, plus the Memory Guard's headroom file — the present state an agent can check before spawning more work."],
                actions: [.init(title: "Open \(Names.Screen.agentDiagnostic)", detail: "The timeline, the jobs audit and the findings of the newest run",
                                target: "agentDiagnostic")],
                question: .init(ask: "The file name says one time and the report says another — which is right?",
                                answer: "The report's header is when it happened; the file name is when it was saved. They can disagree by many minutes, so the timeline anchors on the header and shows the divergence as its own finding."))

        case .askAgent:
            let prelude = f.agentPreludeSet
                ? "You have written your own extra instructions, which it reads before every answer."
                : "You have not written extra instructions; you can, on the same Capabilities screen."
            return TopicContent(
                summary: "\(f.agentCapabilitiesLine) Runs on this Mac, nothing leaves it.",
                what: "\(Names.Screen.ask) is Sparehold's built-in agent: you ask about this Mac in your own words, it reads this Mac's own reports and answers in plain words — everything runs on this Mac, and nothing leaves it.",
                does: [
                    "What it may do is a fixed list of capabilities, each with its own switch in \(Names.Group.settings) › \(Names.Screen.agents) › \(Names.Screen.capabilities). A capability that is switched off is not a hint: the agent cannot do it.",
                    "Its reading is read-only: reports, scans and answers never change anything on its own.",
                    "Even its cleaning is the same preview you get by hand: it can only propose a list, and a clean it starts applies exactly the rows you ticked, through the same preview and Undo as a manual clean.",
                ],
                onThisMac: [f.agentCapabilitiesLine, prelude],
                never: ["It never deletes anything without showing the list first, never touches protected places, never kills on CPU, and never removes the protection around live AI sessions."],
                written: ["Every conversation is kept in the records folder, ask/history under it (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.ask)", detail: "Ask about this Mac in your own words, or start from a question it has ready",
                                target: "ask"),
                          .init(title: "Choose What It May Do", detail: "Switch each capability on or off in \(Names.Screen.settings) › \(Names.Screen.agents) › \(Names.Screen.capabilities)",
                                target: "agentsCapabilities")],
                question: .init(ask: "Can it delete things on its own?",
                                answer: "No. Even a clean it starts is the same preview you get by hand: nothing is applied until you tick it, and everything that is applied lands in Undo."))

        default:
            return TopicContent(summary: "")
        }
    }
}
