import AnalyzersKit
import SwiftUI
import UIComponents

/// A finished run's results, in the same tabs and groups as the task's own screen (the run
/// screen's results slot): read from the run's own block of the log, whole, with what
/// happened to each row where the run acted.
///
/// When the run was a PREVIEW this app started, and its job still stands in the store
/// (not discarded), the results are a live review: every row ticked, ticks that can only
/// shrink, and one `Clean Selected Now` that goes through `JobStore.apply(from:approved:)`
/// — so an older preview is applied from here too, the kernel skipping every path that no
/// longer exists. The kinds whose script takes no reviewed list (Spotlight's fences, Time
/// Machine's snapshots) stay read-only here: their ticks could not shrink what an apply
/// does, and their screens hold the one honest action.
struct StorageResultsView<Category: StorageCategory>: View {
    let row: ActivityRow
    let kind: JobKind
    /// Builds the rows from the run's block; `results` is true for a run that acted.
    let parse: @Sendable (WholeRun.Block, _ results: Bool) -> StorageRows
    let screenKey: String

    @State private var loaded: Loaded?
    @State private var finished = false
    @State private var category: StorageTab
    /// The apply this screen sent from its review, shown as it runs and when it ends.
    @State private var applied: Job?
    @Environment(JobStore.self) private var store

    private struct Loaded {
        let rows: StorageRows
        let session: ReviewSession
        let acted: Bool
    }

    init(row: ActivityRow, kind: JobKind, screenKey: String,
         parse: @escaping @Sendable (WholeRun.Block, Bool) -> StorageRows) {
        self.row = row
        self.kind = kind
        self.screenKey = screenKey
        self.parse = parse
        let first = Category.allCases.first
        _category = State(initialValue: StorageTab(id: first?.rawValue ?? "", title: first?.title ?? "", symbol: first?.symbol ?? "folder"))
    }

    private var filled: [StorageTab] { loaded?.rows.tabs(Category.self) ?? [] }
    private var current: StorageTab { filled.first { $0 == category } ?? filled.first ?? category }

    /// The preview behind this run: the job this app started, finished, and not
    /// discarded — the one a review here may apply through. Re-read from the store
    /// on every body, so a Discard on the task's own screen turns this review
    /// read-only at once.
    private var previewJob: Job? {
        guard let id = row.jobID, let job = store.jobs.first(where: { $0.id == id }),
              job.kind == kind, job.intent == .preview,
              !store.dismissed.contains(job.id),
              case .succeeded = job.state else { return nil }
        return job
    }

    /// Whether the review under this run can apply: it was a preview (not a run that
    /// acted), this app started it, and its script takes the reviewed list — the one
    /// case where a tick really shrinks what an apply touches.
    private var live: Job? {
        guard let loaded, !loaded.acted, kind.takesReviewedList, let job = previewJob else { return nil }
        return job
    }

    /// The words Apply asks with here: the preview's own setting (a Deep preview removes
    /// with Deep's words; a permanent Temp preview deletes), from `CleanWords` and nowhere else.
    private var confirmation: ReviewConfirmation {
        let options = previewJob?.request.options ?? JobOptions()
        let words = CleanWords.words(kind: kind, setting: options) ?? CleanWords.pathsToTrash()
        return ReviewConfirmation(words: words)
    }

    /// What this cleanup means for the Trash and Undo, one plain line under the bar.
    private var footnote: String? {
        switch kind {
        case .janitor, .unusedApps, .recordings: Names.Review.trashFootnote
        case .tempClean: (previewJob?.request.options.permanent ?? false) ? Names.Review.permanentFootnote : Names.Review.trashFootnote
        case .storageClean, .tmReclaim: Names.Review.permanentFootnote
        default: nil
        }
    }

    var body: some View {
        content
            .modifier(StorageResultTabs(screen: screenKey, items: tabItems, selection: Binding(get: { current }, set: { category = $0 })))
            .safeAreaBar(edge: .top, spacing: 0) { if applied != nil { ApplyOutcomeStrip(job: applied) } }
            .task(id: row.id) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let loaded {
            if loaded.rows.rows.isEmpty {
                EmptyState("Nothing Was Found", systemImage: "checkmark.circle",
                           description: Text("This run found nothing to list."))
            } else if let preview = live {
                ReviewTable(session: loaded.session, preview: preview,
                            confirmation: confirmation, footnote: footnote,
                            onApplied: { applied = $0 },
                            only: Set(loaded.rows.rows(inTab: current.rawValue).map(\.id)), screen: "run.\(screenKey)")
            } else {
                ReviewTable(session: loaded.session, readOnly: true,
                            note: loaded.acted ? nil : "This was a preview: nothing was changed.",
                            footnote: footnote,
                            only: Set(loaded.rows.rows(inTab: current.rawValue).map(\.id)), screen: "run.\(screenKey)")
            }
        } else if finished {
            EmptyState("Details Weren't Kept", systemImage: "text.alignleft",
                       description: Text("Show Raw Output has the text this run left."))
        } else {
            LoadingState()
        }
    }

    private var tabItems: [ScopeTabItem<StorageTab>] {
        guard let rows = loaded?.rows else { return [] }
        return filled.map { ScopeTabItem(value: $0, title: $0.title, symbol: $0.symbol, count: rows.count(inTab: $0.rawValue)) }
    }

    private func load() async {
        guard let banner = row.header.map({ $0.components(separatedBy: " · ").first ?? $0 }) else {
            finished = true
            return
        }
        let began = row.started
        let parse = parse
        let kind = kind
        let found = await Task.detached(priority: .userInitiated) { () -> (StorageRows, Bool)? in
            guard let block = StorageLog.block(banner: banner, of: kind, notBefore: began) else { return nil }
            let acted = block.banner.contains("APPLY")
            return (parse(block, acted), acted)
        }.value
        finished = true
        guard let (rows, acted) = found else { return }
        // the session carries the preview's id when this run has one, so its ticks
        // survive leaving this screen and its review can apply through that job
        let session: ReviewSession
        if let id = row.jobID {
            session = ReviewSession(previewID: id, rows: rows.rows.map(\.reviewRow))
        } else {
            session = ReviewSession(readOnly: rows.rows.map(\.reviewRow))
        }
        loaded = Loaded(rows: rows, session: session, acted: acted)
    }
}

private struct StorageResultTabs: ViewModifier {
    let screen: String
    let items: [ScopeTabItem<StorageTab>]
    @Binding var selection: StorageTab

    @ViewBuilder func body(content: Content) -> some View {
        if (2...6).contains(items.count) {
            content.scopeTabsToolbar(screen: "run.\(screen)", items: items, selection: $selection)
        } else {
            content
        }
    }
}
