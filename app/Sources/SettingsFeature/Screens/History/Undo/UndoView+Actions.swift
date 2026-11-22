import AppKit
import SwiftUI
import AnalyzersKit

/// Loading the history, re-reading the Trash, copying a stopped server's command.
/// The Restore actions live on the cleanup screen (`UndoCleanupScreen`), where
/// the rows they act on are.
extension UndoView {

    /// One load: the Trash once, then every receipt judged against it (and the
    /// guard log read). Keyed and cached like every pane's load, so re-entering
    /// the screen costs nothing — and `.task` runs this again whenever the
    /// screen reappears, past the TTL, so what changed while it was away is seen.
    func load() async {
        await awaitLoad({ UndoModel.take() }, key: "undo.entries") { model = $0 }
    }

    /// Re-reads now, past the load cache: what the person emptied in the Finder
    /// while the screen sat open shows here the moment this runs. The screen's
    /// own refresh ("Check the Trash Again") and the unread-Trash state use it.
    func refresh() {
        Task {
            await LoadCoordinator.shared.invalidateAll()
            await load()
        }
    }

    func copy(_ event: GuardEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.processName, forType: .string)
        copiedID = event.id
    }
}
