import SwiftUI
import AnalyzersKit
import UIComponents

/// Undo: what Sparehold moved to the Trash, and what can still be brought
/// back. Level 2 is the two kinds of thing it holds (moved to the Trash,
/// stopped dev servers); level 3 is the Trash's summary and the cleanups
/// themselves, one row each, opening to the cleanup's own screen where the
/// Restore actions live — no rows open in place.
///
/// One load reads the real Trash ONCE (`TrashSnapshot`) and judges every
/// receipt against it; each cleanup then sits in exactly one of two groups:
/// Restorable (everything or something it moved can be put back) and Emptied
/// (none of it can) — the screen's summary chips ARE those two groups, so the
/// chips, the rows and the subtitle can never disagree. When the Trash cannot
/// be read at all, the screen says exactly that instead of claiming it was
/// emptied.
///
/// This file is the screen's state and its composition. One job per file:
///   UndoView+Actions.swift     loading the history, re-reading the Trash, copying a command
///   UndoCleanupScreen.swift    the cleanup screen a row opens (its rows and Restore actions)
///   UndoNode.swift             the rows of a cleanup's table
struct UndoView: View {

    @Environment(Navigator.self) var navigator
    /// One load's history and Trash read; the groups are derived from it.
    @State var model: UndoModel?
    @State var scope: UndoEntry.Scope = .trashed
    @State var copiedID: String?

    private var tabItems: [ScopeTabItem<UndoEntry.Scope>] {
        UndoEntry.Scope.allCases.map { kind in
            ScopeTabItem(value: kind, title: title(kind), symbol: kind == .trashed ? "trash" : "hand.raised",
                         count: model?.entries.filter { $0.scope == kind }.count)
        }
    }

    var body: some View {
        DataScreen(title: Names.Screen.undo, subtitle: subtitle) { content }
            .helpTopic(.trashVsUndo, screen: Names.Screen.undo)
            .scopeTabsToolbar(screen: "undo", items: tabItems, selection: $scope)
            .toolbar {
                // the one "sync" control: what was emptied in the Finder while the
                // screen sat open shows up the moment this is pressed
                if scope == .trashed, model != nil {
                    ToolbarItem {
                        Button("Check the Trash Again", systemImage: "arrow.clockwise") { refresh() }
                            .help("Read the Trash again, past the cache")
                    }
                }
            }
            .task {
                // `undo:trashed`, `undo:servers`, `undo:opened`: which kind to show
                switch navigator.takeIntent(for: HistoryGroup.undo) {
                case "servers": scope = .stopped
                case "opened", "trashed": scope = .trashed
                default: break
                }
                await load()
            }
    }

    @ViewBuilder private var content: some View {
        switch scope {
        case .trashed: trashed
        case .stopped: stopped
        }
    }

    // MARK: - the Trash tab: the summary chips, then the cleanups as rows

    @ViewBuilder private var trashed: some View {
        if let model {
            if model.entries.contains(where: { $0.scope == .trashed }) {
                if model.trash.access == .unreadable {
                    unreadTrash(model.trash)
                } else {
                    cleanupList(model.reconciliation)
                }
            } else {
                EmptyState("Nothing Moved to the Trash Yet", systemImage: "trash",
                           description: Text("The Trash is macOS's own; Undo is Sparehold's record of what it moved "
                               + "there and whether it can still be put back. When a cleanup moves something, it shows up here."))
            }
        } else {
            LoadingState("Reading the history…")
        }
    }

    /// The screen's two groups: the chips are their headers, so the summary and
    /// the rows are one truth. Restorable first; the emptied history below,
    /// drawn dimmed. A row only opens — the cleanup's screen holds the actions.
    private func cleanupList(_ reconciliation: UndoReconciliation) -> some View {
        List {
            if !reconciliation.restorable.cleanups.isEmpty {
                Section(header: Text(restorableHeader(reconciliation.restorable))) {
                    ForEach(reconciliation.restorable.cleanups) { run in
                        CleanupRow(run: run, emptied: false) { open(run) }
                    }
                }
            }
            if !reconciliation.emptied.cleanups.isEmpty {
                Section(header: Text(emptiedHeader(reconciliation.emptied))) {
                    ForEach(reconciliation.emptied.cleanups) { run in
                        CleanupRow(run: run, emptied: true) { open(run) }
                    }
                }
            }
        }
    }

    /// "Restorable: 3 cleanups · 214 items · 1.2 GB" — what can really be put back.
    private func restorableHeader(_ group: UndoReconciliation.Group) -> String {
        var parts = [plural(group.cleanups.count, "cleanup", "cleanups"),
                     plural(group.restorableItems, "item", "items")]
        if group.restorableBytes > 0 { parts.append(ByteSize.text(group.restorableBytes, .headline)) }
        return "Restorable: " + parts.joined(separator: " · ")
    }

    /// "Emptied: 605 items — can't be brought back".
    private func emptiedHeader(_ group: UndoReconciliation.Group) -> String {
        "Emptied: " + plural(group.totalItems, "item", "items") + " — can't be brought back"
    }

    private func open(_ run: UndoRun) {
        navigator.push(.history(.cleanup(run.id)))
    }

    /// The failed read, exactly as failed: the screen refuses to guess whether
    /// the Trash was emptied when it cannot see the Trash.
    private func unreadTrash(_ trash: TrashSnapshot) -> some View {
        UnreadTrashState(trash: trash) { refresh() }
    }

    // MARK: - the guard's tab: one row per stopped server, its command to copy

    private var stopped: some View {
        let runs = UndoHistory.days((model?.entries ?? []).filter { $0.scope == .stopped })
        return Group {
            if runs.isEmpty {
                EmptyState("No Servers Stopped", systemImage: "hand.raised",
                           description: Text("The guard has not stopped anything recently."))
            } else {
                List {
                    ForEach(runs) { day in
                        Section(header: Text(day.title(now: Date()))) {
                            ForEach(day.runs.flatMap(\.entries)) { entry in
                                StoppedRow(entry: entry, view: self)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - the words that match reality

    private var subtitle: String {
        guard let model else { return "Reading the history…" }
        switch scope {
        case .trashed:
            guard model.trash.access == .readable else { return "The Trash can't be read right now" }
            let restorable = model.reconciliation.restorable.restorableItems
            return restorable > 0 ? plural(restorable, "item", "items") + " can still be restored"
                                  : "Nothing in the Trash can be restored"
        case .stopped:
            let count = model.entries.filter { $0.scope == .stopped }.count
            return count > 0 ? plural(count, "server", "servers") + " stopped in the last 90 days"
                             : "No servers stopped recently"
        }
    }

    private func title(_ kind: UndoEntry.Scope) -> String {
        kind == .trashed ? "Moved to the Trash" : "Stopped Dev Servers"
    }

    private func plural(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }
}

/// One cleanup as a row: who ran it and when, what it holds, and its state
/// against the Trash as the badge — "Restorable", "3 of 5", "Emptied". The
/// whole row opens the cleanup's screen.
private struct CleanupRow: View {
    let run: UndoRun
    let emptied: Bool
    let action: () -> Void

    var body: some View {
        OverviewRow(action: action) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(run.by).fontWeight(emptied ? .regular : .medium)
                            if let when = run.when {
                                Text("· \(when.formatted(.dateTime.month().day().hour().minute()))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(rowDetail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(emptied ? Color.secondary : Color.teal)
                }
                Spacer(minLength: 8)
                badge
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(emptied ? .secondary : .primary)   // the emptied history reads dimmed
    }

    private var rowDetail: String {
        var parts = [plural(run.count, "item", "items")]
        if run.totalBytes > 0 { parts.append(ByteSize.text(run.totalBytes, .cell)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        switch run.trashState {
        case .restorable:
            BadgeCapsule(text: "Restorable", color: .teal)
        case .partial(let restorable):
            BadgeCapsule(text: "\(restorable) of \(run.count)", color: .teal)
        case .emptied:
            BadgeCapsule(text: "Emptied", color: .secondary)
        }
    }

    private func plural(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }
}

/// One stopped server as a row: what it was, why it was stopped, and the
/// command to bring it back — the action lives on the row itself.
private struct StoppedRow: View {
    let entry: UndoEntry
    let view: UndoView

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                Text(entry.outcome).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if case .stopped(let event) = entry.source {
                Button(view.copiedID == event.id ? "Copied" : "Copy Command") { view.copy(event) }
                    .controlSize(.small)
                    .help(event.processName.count >= 140
                          ? "Recorded before the app kept full command lines, so part of it may be missing"
                          : "The command as the guard recorded it; you still supply the folder and environment")
            }
        }
    }
}

/// The one state both Undo screens show when the Trash cannot be read: what
/// happened, what fixes it, and the button that reads it again. Never a claim
/// about what is still in the Trash — a Trash that cannot be seen proves
/// nothing about what was emptied.
struct UnreadTrashState: View {
    let trash: TrashSnapshot
    let refresh: () -> Void

    var body: some View {
        EmptyState {
            Label("Can't Read the Trash Right Now", systemImage: "trash.slash")
        } description: {
            Text("macOS isn't letting Sparehold look in the Trash, so it can't say what is still in it."
                + (trash.failureText.map { " (\($0))" } ?? "")
                + " Allow Full Disk Access in System Settings › Privacy & Security, then check again.")
        } actions: {
            Button("Check Again") { refresh() }
        }
    }
}
