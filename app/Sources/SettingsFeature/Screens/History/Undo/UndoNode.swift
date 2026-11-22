import SwiftUI
import AnalyzersKit
import UIComponents

/// One row of a cleanup's table: an item the cleanup moved (a family folded
/// into one row; an app opened to its bundle and files). Built from the run's
/// own children as data; nothing is recovered by splitting a title.
struct UndoNode: Identifiable {
    let child: UndoRun.Child
    let children: [UndoNode]?

    var id: String { child.id }

    /// One cleanup's rows: apps first (each opened to its files), then the
    /// folded rows, the order `UndoRun.children` already chose.
    static func rows(_ run: UndoRun) -> [UndoNode] {
        run.children.map { UndoNode(child: $0, children: $0.isApp
            ? $0.files.map { UndoNode(child: $0, children: nil) } : nil) }
    }

    /// How many text lines the name cell needs: the title, and what happened to it.
    var lineCount: Int { child.outcome.isEmpty ? 1 : 2 }

    /// Every node below this one and itself, to find a row by id.
    var flattened: [UndoNode] { [self] + (children ?? []).flatMap(\.flattened) }
}
