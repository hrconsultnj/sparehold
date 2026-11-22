import Foundation
import AnalyzersKit

/// The Storage tab's topics. What runs by itself on a schedule is read from the installed schedule; what a person starts is a
/// preview first, and the two are never confused.
extension HowItWorksTopic {

    @MainActor func storageContent(_ f: HowItWorksFacts) -> TopicContent {
        switch self {
        case .safeToRemove:
            let daily = GuardControl.storageCleanLabel, deep = GuardControl.storageDeepLabel
            let scheduledDaily = f.storageCleanDoes(daily) ?? f.notScheduled(daily)
            let scheduledDeep = f.storageCleanDoes(deep) ?? f.notScheduled(deep)
            var onThisMac: [String] = []
            if let free = f.freeDisk, let total = f.totalDisk {
                onThisMac.append("Your startup disk has \(free) free of \(total).\(f.runway.map { " At your current pace the disk fills in \($0)." } ?? "")")
            }
            if f.logsRead {
                onThisMac.append(f.week.reclaimableBytes.map { "The latest preview found \(ByteSize.text($0, .headline)) you could take back." }
                                    ?? "Nothing is waiting from a preview.")
                onThisMac.append("In the last 7 days, \(f.week.cleanRuns) cleanups freed \(ByteSize.text(f.week.storageFreedBytes, .headline)).")
            }
            var summary = [f.freeDisk.flatMap { free in f.totalDisk.map { "\(free) free of \($0)." } }].compactMap { $0 }.joined()
            if f.logsRead { summary += (summary.isEmpty ? "" : " ") + "\(f.week.cleanRuns) cleanups this week." }
            return TopicContent(
                summary: summary.isEmpty ? "What can be removed, and what runs by itself." : summary,
                what: "Your tools keep folders they can make again — build caches, dependency folders, build output — so clearing them frees space without losing anything you made.",
                does: [
                    "\(Names.Screen.cachesAndBuilds) finds what your tools can make again: build caches, the dependency folders of projects you have not touched for \(f.days(f.nodeModulesDays))\(f.nodeModulesNeedClean ? ", and only when they have no unsaved changes" : ""), and package-manager caches.",
                    "When you start a cleanup yourself it is a preview first: you see what would be removed and untick anything you want kept, and only then does Apply start. Caches and build folders are deleted for good, because your tools make them again, so Undo cannot bring them back.",
                    "The cleanups that run by themselves do not wait for you. \(scheduledDaily)",
                    scheduledDeep,
                    "Change when they run in \(Names.Group.settings) › \(Names.Screen.schedule). The background jobs are switched off only all together, in \(Names.Screen.setup) › \(Names.Screen.turnOff).",
                ],
                onThisMac: onThisMac,
                never: [
                    "Build folders are removed only when nothing has written to them for days, and a project that something live runs from is left alone.",
                    "A cleanup you start yourself never removes anything you have not reviewed in a preview.",
                ],
                written: ["Each run writes a full report and appears in Activity (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.cachesAndBuilds)", detail: "Find What to Clean — the preview lists what your tools can make again, you untick anything you want kept",
                                target: "caches"),
                          .init(title: "Open \(Names.Screen.disk)", detail: "See where the space is, and preview every cleanup at once",
                                target: "disk"),
                          .init(title: Names.HowItWorks.change, detail: "Choose when the scheduled cleanups run", target: "schedule")],
                question: .init(ask: "I cleaned, but Finder still shows the disk nearly full. Where is my space?",
                                answer: "Freed space can sit inside Time Machine's local snapshots until they thin — macOS holds it for a while in case you want it back. Open \(Names.Screen.timeMachine) to thin them now; the space appears in Finder once they are gone."))

        case .downloadsTemp:
            return TopicContent(
                summary: "Downloads older than \(f.days(f.downloadsDays)), screenshots older than \(f.days(f.screenshotsDays)).",
                what: "Two cleanups tidy the places that fill up by themselves: your Downloads folder, and the temporary folders your Mac, your coding agents and your download tools leave behind.",
                does: [
                    "\(Names.Screen.downloads) looks for files you have not changed for \(f.days(f.downloadsDays)), and for screenshots older than \(f.days(f.screenshotsDays)). You review them in a preview; what you apply goes to the Trash, and Undo puts it back.",
                    "\(Names.Screen.tempAndAgents) clears temporary files that have been idle for \(f.hours(f.tempIdleHours)), scratch folders of coding agents idle for \(f.days(f.tempAgentScratchDays)), and tool downloads idle for \(f.days(f.tempToolDownloadDays)). It also shows a preview first, and what you apply goes to the Trash.",
                    "Neither of these has a schedule of its own: they run when you start them.",
                    "macOS also clears /tmp by itself every night: files nobody has touched for three days. It skips mounted disk images and anything still in use.",
                ],
                onThisMac: [],
                never: ["Anything that is open, in use, owned by someone else, or a mounted disk image you have not approved is never touched."],
                written: ["Each run writes a report and appears in Activity (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.downloads)", detail: "Preview old files and screenshots, and choose what goes to the Trash",
                                target: "downloads"),
                          .init(title: "Open \(Names.Screen.tempAndAgents)", detail: "Preview idle temporary files, agent scratch folders and tool downloads",
                                target: "temp")],
                question: .init(ask: "Are the files gone for good?",
                                answer: "No. What you apply goes to the Trash, and Undo lists it so you can put it back exactly where it was — see \(Names.HowItWorks.trashVsUndo)."))

        case .timeMachine:
            let deep = GuardControl.storageDeepLabel
            var byItself = ""
            if let line = f.schedule(deep), line.installed, line.thinsSnapshots, let when = line.when {
                byItself = f.timeMachinePermission
                    ? "Because you have given the permission, \(line.name) deletes local snapshots by itself \(when.lowercased()), without asking."
                    : "\(line.name) runs \(when.lowercased()) and would delete local snapshots, but it skips them until you give the permission."
            }
            let permission = f.timeMachinePermission
                ? "You have given that permission on this Mac."
                : "You have not given that permission on this Mac yet, so Sparehold will ask the first time you delete snapshots yourself."
            return TopicContent(
                summary: f.timeMachinePermission ? "Permission given on this Mac." : "Needs a one-time permission.",
                what: "While Time Machine backs up, macOS keeps hourly copies of your files on this Mac itself — local snapshots, invisible in Finder — so a file you deleted this morning can still be brought back. They use disk space.",
                does: [
                    "The \(Names.Screen.timeMachine) screen lists the local snapshots on this Mac so you can delete the ones you do not need.",
                    "Deleting snapshots needs a one-time permission, with your administrator password, for exactly one command. After that, any program running on your account can delete local snapshots without asking, and nothing else is allowed. \(permission)",
                ] + (byItself.isEmpty ? [] : [byItself]),
                onThisMac: [],
                never: ["Sparehold never touches your backups on the backup disk. It only deletes local snapshots on this Mac, and when you delete them yourself, only after you confirm."],
                written: ["The permission is one small file. You can remove it from the \(Names.Screen.timeMachine) screen or from Setup."],
                actions: [.init(title: "Open \(Names.Screen.timeMachine)", detail: "Thin local snapshots now — see the list, confirm, and the space goes back to Finder",
                                target: "timemachine")],
                question: .init(ask: "I cleaned, but Finder shows no change — where is the freed space?",
                                answer: "The snapshots are holding it. Time Machine's local snapshots keep the space until they thin, which is why Finder can stay full after a cleanup. Open \(Names.Screen.timeMachine) to thin now."))

        case .unusedApps:
            return TopicContent(
                summary: "Apps you have not opened in a long time, shown for you to decide.",
                what: "An app you have not opened in months still holds its place on disk. This screen lists the apps macOS has no record of you using, and you choose what to move.",
                does: [
                    "\(Names.Screen.unusedApps) lists apps you have never opened or have not opened in a long time, using what macOS recorded about their use. Apps with no record of use are listed separately, since not knowing is not the same as not using.",
                    "You choose what to move. It goes to the Trash, and Undo puts it back.",
                ],
                onThisMac: [],
                never: ["Apps that are running now are left alone, and nothing is moved without your review. It has no schedule of its own."],
                written: ["Each run appears in Activity (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.unusedApps)", detail: "See which apps you have not opened lately, and preview what moving one would clear",
                                target: "unused")],
                question: .init(ask: "If I move an app out and want it back, do I lose anything?",
                                answer: "No. Moving to the Trash does not touch the app's settings, and Undo puts it back where it was with its preferences intact."))

        case .oldRecordings:
            return TopicContent(
                summary: "Recordings older than \(f.days(f.recordingsDays)), in the folders you choose.",
                what: "Recordings pile up where your tools save them — Zoom, screen recordings, voice memos. This screen looks in the folders you choose for the ones older than your age limit.",
                does: [
                    "\(Names.Screen.oldRecordings) looks through the folders where you keep recordings (Zoom, screen recordings, voice memos and the like; you choose them with Sources on its screen) for ones older than \(f.days(f.recordingsDays)).",
                    "You review a preview, and what you apply goes to the Trash, and Undo puts it back.",
                ],
                onThisMac: [],
                never: ["Nothing is removed without a preview you reviewed, and it has no schedule of its own."],
                written: ["Each run appears in Activity (see \(Names.HowItWorks.whereWritten))."],
                actions: [.init(title: "Open \(Names.Screen.oldRecordings)", detail: "Choose the folders to look in, preview the old recordings, and untick anything you want kept",
                                target: "recordings")],
                question: .init(ask: "What if a recording I need is older than the limit?",
                                answer: "It is only ever a preview: the old recordings are listed, you untick anything you want kept, and what you do not apply never moves."))
        default:
            return TopicContent(summary: "")
        }
    }
}
