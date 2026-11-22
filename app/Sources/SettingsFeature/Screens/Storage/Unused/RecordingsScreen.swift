import AnalyzersKit
import SwiftUI

/// Old Recordings: every recording, of every age, from the places your recording apps save to. Each source that
/// has something is a tab (Zoom, Screen Recordings, a folder of yours), the recordings in it are grouped by age
/// band, and a band's Select ticks exactly that range — "older than 7 days" is bands selected and the review's
/// one Apply. Where to look is set in one window, Sources…, which the toolbar, the empty screen and (with Setup's
/// rebuild) Setup all open; the age in it is the SCHEDULED clean's own limit, never this screen's.
struct RecordingsScreen: View {
    @State private var model = StorageReviewModel()
    @State private var showSources = false
    @Environment(ConfigStore.self) private var config
    @Environment(JobStore.self) private var store
    @Environment(Navigator.self) private var navigator
    /// Example rows for `SnapshotRunner`; nil in the app.
    var fixture: StorageRows?
    /// `SnapshotRunner`: the screen as it is with no source switched on.
    var fixtureNoneOn = false

    /// The scheduled clean's age limit: said in the words so a person knows
    /// what the setting still decides, but never used to look or to act.
    private var days: Int { config.storage.recordingsDays }

    /// What the screen looks through, in words: the apps by name, the person's own folders as a count.
    private var looksThrough: [String] {
        let entries = config.storage.recordingSources
        guard !entries.isEmpty else {
            return config.storage.recordingSourcesConfigured || config.storage.recordingsDir.isEmpty ? [] : ["1 folder of yours"]
        }
        let on = entries.filter(\.enabled)
        let apps = on.filter { !$0.isCustom }.compactMap { RecordingSourceCatalog.definition($0.id)?.title }
        let own = on.filter(\.isCustom).count
        return apps + (own > 0 ? ["\(own) \(own == 1 ? "folder" : "folders") of yours"] : [])
    }

    private var noneOn: Bool { fixtureNoneOn || (fixture == nil && !config.storage.hasRecordingSources) }

    private var emptyText: String {
        if noneOn { return "Choose where your recording apps save, and Sparehold looks at every recording in them, of every age." }
        let names = fixture != nil && looksThrough.isEmpty ? ["Zoom", "Screen Recordings", "1 folder of yours"] : looksThrough
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : names.first ?? ""
        return "Looks through \(list) at every recording, of every age. Select a band below — or single rows — and apply to move just that range; the scheduled clean still only offers recordings older than \(days) days. Nothing is removed until you review it."
    }

    /// What the newest preview found in each source, for the Sources window.
    private var found: [String: RecordingFound] {
        guard let rows = model.rows else { return [:] }
        var result: [String: RecordingFound] = [:]
        for row in rows.rows where row.isChoosable {
            var entry = result[row.category] ?? RecordingFound(count: 0, bytes: 0)
            entry.count += 1
            entry.bytes += row.bytes ?? 0
            result[row.category] = entry
        }
        return result
    }

    var body: some View {
        StorageReviewScreen<StorageTab>(
            model: model, title: Names.Screen.oldRecordings, kind: .recordings, screenKey: "recordings",
            // the screen's own look is the WHOLE folder: 0 days is no age
            // limit. The saved days stay the scheduled clean's default (they
            // are said in the words, and never used here).
            options: JobOptions(recordingsDays: 0),
            parse: { UnusedReview.recordings(lines: $0.lines) },
            applyTitle: "Move to Trash",
            confirmation: ReviewConfirmation(
                verb: "Move", destination: "to the Trash",
                message: "The ticked recordings go to the Trash. You can put them back from Undo, and the space returns when the Trash is emptied.",
                permanent: nil, namesRows: "Recordings to move"),
            emptyText: emptyText,
            emptyTitle: noneOn ? Names.Recordings.noFoldersChosen : "No Preview Yet",
            destination: Names.Review.goesToTrash,
            emptyActions: [ReviewAction(id: "choose", title: Names.Recordings.chooseFolders, systemImage: "folder.badge.gearshape",
                                        help: "Choose where your recording apps save", action: { showSources = true })],
            toolbarActions: [ReviewAction(id: "sources", title: Names.Recordings.sourcesButton, systemImage: "folder.badge.gearshape",
                                          help: "Choose which folders Old Recordings looks in, and how old a scheduled clean's recordings have to be",
                                          action: { showSources = true })],
            previewDisabledReason: noneOn ? "Choose which folders to look in first" : nil,
            emptySymbol: noneOn ? "folder.badge.questionmark" : "eye",
            bandSummary: { rows, session in
                AnyView(AgeBandSummary(rows: rows, session: session, noun: "recording",
                                       note: "Select ticks a band; Apply moves only what the review then shows. The \(days)-day setting above decides the scheduled clean, not this screen."))
            })
            .onAppear { if let fixture { model.showFixture(fixture) } }
            .recordingSourcesSheet(isPresented: $showSources, found: found, previewed: model.rows != nil) {
                // the sources changed, so the review on screen is of the old ones: throw it away and say to preview again
                if model.phase == .ready { model.discard(store) }
            }
            .onChange(of: navigator.pendingIntent) { applyPendingLink() }
            .task { applyPendingLink() }
    }

    /// `recordings:sources` opens the window: navigation only, it starts nothing.
    private func applyPendingLink() {
        guard let payload = navigator.takeIntent(for: StorageGroup.recordings) else { return }
        if payload == "sources" { showSources = true }
    }
}
