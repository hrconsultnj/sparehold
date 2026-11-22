import Foundation
import AnalyzersKit

/// The Your Data tab's topics: what is kept, where, and what leaves this Mac and when.
extension HowItWorksTopic {

    @MainActor func yourDataContent(_ f: HowItWorksFacts) -> TopicContent {
        let records = AnalyzersPaths.displayPath(AnalyzersPaths.userRoot)
        switch self {
        case .whereWritten:
            var onThisMac = ["Everything is kept in \(records), nothing inside the app."]
            if let bytes = f.guardLogBytes {
                onThisMac.append("The guard log is \(ByteSize.text(bytes, .headline)) on this Mac.")
            }
            return TopicContent(
                summary: "Everything is kept in \(records), nothing inside the app.",
                what: "Everything Sparehold does is written down in one folder on your Mac — the guard's log, each cleanup's full report, its settings file. Nothing lives inside the app.",
                does: [
                    "Every action Memory Guard takes is written in the guard log.",
                    "Every cleanup writes a full report under \(records)/reports/, a folder for each day. Clicking any notification opens the app or the exact log behind it.",
                    "The Clear button in the menu-bar panel only resets what the panel shows. The logs are never trimmed by the app.",
                ],
                onThisMac: onThisMac,
                never: ["Nothing is written inside the app itself, so removing or updating the app never loses your records."],
                written: ["Your records folder is \(records). Your settings file is \(records)/config.local.sh."],
                actions: [.init(title: "Open \(Names.Screen.reports)", detail: "Read the reports, each one a structured screen, with TextEdit as the escape hatch",
                                target: "reports")],
                question: .init(ask: "If I delete the app, do I lose my reports?",
                                answer: "No. The records live in \(records), not in the app, so removing or updating the app never touches them."))

        case .editByHand:
            let jobs = f.schedules.filter(\.installed).compactMap { line in line.when.map { "\(line.name) \($0.lowercased())" } }
            let ran = jobs.isEmpty ? "" : " On this Mac the jobs run like this: \(jobs.joined(separator: "; "))."
            return TopicContent(
                summary: "Plain shell scripts and one settings file you can open in any editor.",
                what: "The watching and cleaning is done by plain shell scripts that macOS's own scheduler (launchd) runs. This app is the control surface over them, and the settings are one text file you can open in any editor.",
                does: [
                    "The settings you change in this app are written into one marked block of \(records)/config.local.sh. Anything you write by hand outside that block is kept exactly as you wrote it.",
                ],
                onThisMac: [ran.isEmpty ? "Your settings file is \(records)/config.local.sh." : ran],
                never: ["The app never rewrites the parts of your settings file that it did not write."],
                written: ["Your settings file is \(records)/config.local.sh."],
                actions: [.init(title: "Open \(Names.Screen.schedule) Settings", detail: "See the schedules the scripts are installed with",
                                target: "schedule")],
                question: .init(ask: "Will the app undo my hand edits?",
                                answer: "No. It writes only the marked block of \(records)/config.local.sh; anything outside the markers is kept exactly as you wrote it."))

        case .healthReport:
            var about = "memory"
            if let total = f.totalMemory { about += " (\(total) installed)" }
            about += ", storage"
            if let free = f.freeDisk, let total = f.totalDisk { about += " (\(free) free of \(total))" }
            about += " and what Sparehold did"
            return TopicContent(
                summary: "A one-page summary of the last 30 days, made on this Mac.",
                what: "The Mac Health Report is a one-page summary of this Mac's last 30 days — for IT, family or a buyer — made on this Mac, from this Mac's own records.",
                does: ["It is generated locally, from this Mac's own records: \(about)."],
                onThisMac: [],
                never: ["It is not sent anywhere. You choose where to save it."],
                written: ["The report is saved where you choose; nothing is kept by the app."],
                actions: [],
                question: .init(ask: "Where does the report go?",
                                answer: "Nowhere by itself. It is generated on this Mac and saved only where you choose to save it."))

        case .privacy:
            let following: String
            switch f.channel {
            case .beta: following = "You follow Beta, so this happens on this Mac."
            case .releases: following = "You follow Releases, so this does not happen on this Mac unless you switch to Beta."
            case .thisCopy: following = "You follow Development, so this does not happen unless you switch to Beta."
            }
            return TopicContent(
                summary: "Everything is read and written on this Mac; three kinds of request go out.",
                what: "Everything is read and written on this Mac. The only requests that go out are the release checks, and what each one sends is said plainly.",
                does: [
                    "Memory, storage, login items and network figures are read from this Mac and stay on it.",
                    "The release check: at launch and every 6 hours the app asks GitHub which release is newest. It sends nothing about your Mac.\(f.version.isEmpty || f.version == "0" ? "" : " You are on version \(f.version).")",
                    "Beta: it also asks GitHub how far your copy is behind the development branch, which sends the identifier of the commit your copy was built from, and it reads the development branch's change notes, every 6 hours.",
                    "Install: choosing Install on a copy built from a clone runs git pull in that clone, which contacts that clone's own remote.",
                ],
                onThisMac: [following],
                never: ["No usage data, logs or reports are uploaded, and there is no account."],
                written: ["Your records are in \(records) (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.updates)", detail: "Choose the update channel, and check for updates yourself",
                                target: "update")],
                question: .init(ask: "What exactly leaves this Mac?",
                                answer: "The release check asks GitHub which release is newest and sends nothing about your Mac. On Beta it also sends the commit identifier your copy was built from. Nothing else leaves: no usage data, no logs, no reports."))

        case .trashVsUndo:
            var onThisMac: [String] = []
            if let undo = f.undoLine { onThisMac.append(capitalizedFirst(undo)) }
            if f.logsRead, f.week.cleanRuns > 0 {
                onThisMac.append("This week \(f.week.cleanRuns) cleanups ran; each one that moved files listed them in Undo.")
            }
            return TopicContent(
                summary: "Every cleanup moves to the Trash first, and Undo puts it back.",
                what: "The Trash is macOS's holding area for deleted things. Undo is Sparehold's own list of what its cleanups put there — with one Restore button that moves each thing back exactly where it came from.",
                does: [
                    "Every cleanup that removes files you could not make again sends them to the Trash, never straight to nothing: a mistake is one click away from being undone.",
                    "Undo knows where each item came from, so Restore puts it back exactly where it was. At the moment of restoring it checks again that the item in the Trash is still the one the cleanup put there; anything it refuses is said in an alert.",
                    "The one exception is \(Names.Screen.cachesAndBuilds): caches and build folders are deleted for good, because your tools make them again, so there is nothing to undo.",
                    "Undo also covers what the Trash cannot: the dev servers Memory Guard stopped are listed with the command to start each one again — copy it back to your terminal.",
                ],
                onThisMac: onThisMac,
                never: ["Emptying the Trash in Finder is the one step Sparehold does not hold back: after it, the items are gone, and Undo only says so."],
                written: ["What was moved is written in each cleaner's log (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.undo)", detail: "Put back what a cleanup moved — what can still be restored is listed first",
                                target: "undo")],
                question: .init(ask: "What does Undo cover that the Trash does not?",
                                answer: "The Trash holds a file; Undo remembers the cleanup that moved it, where it came from, and how to put it back. It also lists the servers Memory Guard stopped, which never go to the Trash at all — for those, Undo holds the command that starts them again."))

        default:
            return TopicContent(summary: "")
        }
    }

    /// A ledger sentence starts with a figure or "Nothing"; a lowercase start is capitalised so the paragraph reads as one.
    private func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// What a topic says on this Mac.
@MainActor extension HowItWorksTopic {
    func content(_ f: HowItWorksFacts) -> TopicContent {
        switch tab {
        case .memory: memoryContent(f)
        case .storage: storageContent(f)
        case .system: systemContent(f)
        case .yourData: yourDataContent(f)
        }
    }
}
