import SwiftUI
import AnalyzersKit
import UIComponents

/// One cleanup's screen, opened from a row of the Undo screen: everything that
/// run moved to the Trash, with Restore on what is still there. The row's
/// state (restorable, partial, emptied) was decided once per Undo load; this
/// screen re-reads the same load on appear, so it shows the Trash as it is NOW
/// — a cleanup that was emptied or put back in the meantime says so here.
///
/// One table for the run's items (`OutlineTable`): apps opened to their files,
/// families folded into one row. Rows with nothing to bring back are dimmed
/// and say why; the run says the reason once, in the subtitle.
struct UndoCleanupScreen: View {

    let runID: String

    /// The same load the Undo screen holds — one read, one truth.
    @State var model: UndoModel?
    @State var nodes: [UndoNode] = []
    @State var selection: Set<String> = []
    /// Which apps' files are open, kept across window close and relaunch.
    @State var open = RememberedExpansion<String>(screen: "undo.cleanup")
    /// A restore is running: every Restore button is disabled until it finishes.
    @State var restoring = false
    @State var restoreError: String?

    private var run: UndoRun? { model?.cleanup(id: runID) }

    var body: some View {
        Group {
            if let model {
                if model.trash.access == .unreadable {
                    UnreadTrashState(trash: model.trash) { refresh() }
                } else if model.cleanup(id: runID) != nil {
                    table
                } else {
                    // the cleanup's last items were put back while this screen was open:
                    // there is nothing left to show, and that is the truth to say
                    EmptyState("Everything Was Put Back", systemImage: "checkmark.circle",
                               description: Text("Every item this cleanup moved has been restored, so it is no longer listed."))
                }
            } else {
                LoadingState("Reading the history…")
            }
        }
        .navigationTitle(run?.by ?? Names.Screen.undo)
        .navigationSubtitle(subtitle)
        .helpTopic(.trashVsUndo, screen: Names.Screen.undo)
        .toolbar {
            if let run, run.restorable > 0 {
                ToolbarItem {
                    Button("Restore All", systemImage: "arrow.uturn.backward") {
                        restore(run.entries.filter(\.isRestorable))
                    }
                    .disabled(restoring)
                    .help("Put back the \(run.restorable) items that are still in the Trash")
                }
            }
        }
        .alert("Couldn't Restore", isPresented: Binding(get: { restoreError != nil },
                                                        set: { if !$0 { restoreError = nil } })) {
            Button("OK") { restoreError = nil }
        } message: {
            Text(restoreError ?? "")
        }
        .task { await load() }
    }

    private var table: some View {
        OutlineTable(nodes, children: \.children, selection: $selection,
                     expanded: open.binding, autosave: "undo.cleanup") {
            OutlineColumn("name", Names.Column.name) { UndoRowLabel(node: $0) }
                .lines { $0.lineCount }
            OutlineColumn("action", "") { node in UndoRowAction(node: node, screen: self) }
                .hideable(false)
                .width(min: 110, ideal: 120, max: 160)
                .alignment(.trailing)
        }
        .columnHeaders(.hidden)
        // a history of what moved, not a table of values: no stripes behind the rows
        .alternatingRows(false)
        // a row with nothing to bring back reads dimmed; its outcome line says why
        .rowEnabled { !$0.child.restorable.isEmpty }
        .contextMenu({ ids in UndoRowMenu(nodes: nodes, ids: ids, screen: self) })
        .emptyContent(isLoading: model == nil) { EmptyView() }
    }

    /// The run's truth in one line: what it holds and how much can come back
    /// (the summary says both), or the one reason none of it can.
    private var subtitle: String {
        guard let run else { return "" }
        return run.restoreNote ?? run.summary
    }

    // MARK: - loading and restoring

    /// The same keyed load the Undo screen uses, so both screens (and a
    /// re-appear past the TTL) read one fresh picture of the Trash.
    private func load() async {
        await awaitLoad({ UndoModel.take() }, key: "undo.entries") { model in
            self.model = model
            if let run = model.cleanup(id: runID) {
                nodes = UndoNode.rows(run)
            } else {
                nodes = []
            }
        }
    }

    /// Re-reads now, past the cache — the same move the Undo screen's
    /// "Check the Trash Again" makes.
    private func refresh() {
        Task {
            await LoadCoordinator.shared.invalidateAll()
            await load()
        }
    }

    /// Moves each item back out of the Trash, off the main thread (the buttons are disabled
    /// while it runs). This is an app-side file move, not an engine script, so it is not a
    /// job; one Restore click writes ONE block in each cleaner's log (Activity lists it as
    /// its own row, "Restored 3 Items"). `UndoLedger.restore` re-checks that the item in the
    /// Trash is the one the cleaner put there at this moment; anything it refuses, or a block
    /// it could not write, is said in an alert. Not private: the row cells in this file
    /// drive it.
    func restore(_ entries: [UndoEntry]) {
        guard !restoring else { return }
        restoring = true
        let wanted = entries.compactMap { entry -> (title: String, item: TrashedItem)? in
            guard case .trashed(let item) = entry.source else { return nil }
            return (entry.title, item)
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                UndoLedger.restore(wanted.map(\.item), titles: wanted.map(\.title))
            }.value
            var messages = outcome.failures.prefix(3).map { "\($0.title): \($0.message)" }
            if outcome.failures.count > 3 { messages.append("and \(outcome.failures.count - 3) more.") }
            if outcome.unrecorded > 0 {
                messages.append("\(outcome.unrecorded) item\(outcome.unrecorded == 1 ? " was" : "s were") put back, "
                    + "but the cleanup log could not be written to, so the list may still show them.")
            }
            restoreError = messages.isEmpty ? nil : messages.joined(separator: "\n")
            await LoadCoordinator.shared.invalidateAll()
            await load()
            restoring = false
        }
    }
}

/// The name cell: what the item is, and what happened to it.
private struct UndoRowLabel: View {
    let node: UndoNode

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(node.child.title)
            if !node.child.outcome.isEmpty {
                Text(node.child.outcome).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The action cell: Restore on a row with something to bring back (an app's
/// row restores its bundle and files together). A row that cannot be brought
/// back has no button — the run's subtitle says why, once.
private struct UndoRowAction: View {
    let node: UndoNode
    let screen: UndoCleanupScreen

    var body: some View {
        if !node.child.restorable.isEmpty {
            Button("Restore") { screen.restore(node.child.restorable) }
                .controlSize(.small)
                .disabled(screen.restoring)
        }
    }
}

/// The right-click menu of an item: the same action as its button.
private struct UndoRowMenu: View {
    let nodes: [UndoNode]
    let ids: Set<String>
    let screen: UndoCleanupScreen

    var body: some View {
        let picked = nodes.flatMap(\.flattened).filter { ids.contains($0.id) }
        if let node = picked.first, !node.child.restorable.isEmpty {
            Button("Restore") { screen.restore(node.child.restorable) }
                .disabled(screen.restoring)
        }
    }
}
