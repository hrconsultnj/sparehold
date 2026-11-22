import Foundation

/// What the real Trash looks like, read ONCE per Undo load and held with the
/// history in the screen's `UndoModel`.
///
/// The reconciliation itself never guesses from a name: each receipt names the
/// exact path the cleaner put the item at, and `UndoLedger` checks that very
/// item — still there? still the same `device:inode`? — when the list is built
/// and again the moment Restore is clicked. Enumerating `~/.Trash` adds the one
/// thing those per-item checks cannot say: whether the Trash can be read AT
/// ALL. Without it, a lost Full Disk Access would make every item read as
/// "gone", and the screen would claim the Trash had been emptied when it
/// merely could not be seen.
public struct TrashSnapshot: Sendable, Equatable {
    public enum Access: Sendable, Equatable {
        /// The Trash was listed — which may mean it holds nothing.
        case readable
        /// The Trash could not be read. The app then refuses to claim
        /// anything about what is still in it.
        case unreadable
    }

    public let access: Access
    /// Items sitting in the Trash right now (its top level; 0 when it cannot be read).
    public let itemCount: Int
    /// The system's words for why the Trash could not be read, when it could not.
    public let failureText: String?

    /// One read of the Trash. A missing Trash folder is an empty Trash, not a
    /// failure; a folder that cannot be listed (Trash access revoked) is.
    public static func take(trash: URL = UndoLedger.trashDir) -> TrashSnapshot {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: trash.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return TrashSnapshot(access: .readable, itemCount: 0, failureText: nil)
        }
        do {
            let names = try fm.contentsOfDirectory(atPath: trash.path)
            return TrashSnapshot(access: .readable, itemCount: names.count, failureText: nil)
        } catch {
            return TrashSnapshot(access: .unreadable, itemCount: 0, failureText: error.localizedDescription)
        }
    }
}

/// One cleanup's true state against the Trash, decided when the history is
/// read: the three answers to "can what this run moved still be put back?".
/// A run is in exactly one of them — never per-row dead text.
public enum CleanupTrashState: Sendable, Equatable {
    /// Every item the cleanup moved is still in the Trash and can be put back.
    case restorable
    /// Some are: `restorable` of the run's items can still be put back.
    case partial(restorable: Int)
    /// None can: the Trash has been emptied, or every item is blocked for its
    /// own reason — the run says which, once.
    case emptied
}

/// The Undo screen's true picture, derived from one load: its cleanups in two
/// groups. `restorable` holds the cleanups with something live (all or some of
/// their items can come back); `emptied` holds the history that cannot.
public struct UndoReconciliation: Sendable {
    public struct Group: Sendable {
        /// The group's cleanups, newest first. A run that crossed midnight is
        /// counted once, however many days it spans.
        public let cleanups: [UndoRun]
        /// Items that can still be put back: all of a restorable cleanup's,
        /// some of a partial one's.
        public let restorableItems: Int
        /// Everything the group's cleanups moved.
        public let totalItems: Int
        /// What the still-restorable items weigh (the restorable group), or
        /// what was lost with them (the emptied group).
        public let restorableBytes: Int64
    }

    public let restorable: Group
    public let emptied: Group
}

/// Everything one Undo load read: the history's entries and the one read of
/// the real Trash they were reconciled against. The screen holds this; the
/// reconciliation is derived from it, so a re-read replaces it wholesale.
public struct UndoModel: Sendable {
    public let entries: [UndoEntry]
    public let trash: TrashSnapshot

    /// For the one that already read both halves (`UndoHistory.entries` plus a
    /// snapshot) — a probe, or a test. A screen takes `take()` instead.
    public init(entries: [UndoEntry], trash: TrashSnapshot) {
        self.entries = entries
        self.trash = trash
    }

    /// One load: the Trash once, then the receipts and the guard log judged
    /// against it.
    public static func take(now: Date = Date(), trash: URL = UndoLedger.trashDir) -> UndoModel {
        let snapshot = TrashSnapshot.take(trash: trash)
        let entries = UndoHistory.entries(now: now, trash: trash,
                                          trashReadable: snapshot.access == .readable)
        return UndoModel(entries: entries, trash: snapshot)
    }

    /// The cleanups in their two groups.
    public var reconciliation: UndoReconciliation { UndoHistory.reconcile(entries) }

    /// The cleanup a pushed screen was opened for, by its run id.
    public func cleanup(id: String) -> UndoRun? {
        UndoHistory.cleanup(id: id, in: entries)
    }
}

/// A run's place in the three states, from its own entries' restorability.
public extension UndoRun {
    var trashState: CleanupTrashState {
        guard !entries.isEmpty else { return .emptied }
        if restorable == entries.count { return .restorable }
        if restorable == 0 { return .emptied }
        return .partial(restorable: restorable)
    }
}
