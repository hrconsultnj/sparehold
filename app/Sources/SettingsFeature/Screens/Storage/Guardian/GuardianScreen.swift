import AnalyzersKit
import SwiftUI

/// Cache Guardian: what coding agents left behind — merged worktrees, oversized
/// package stores, Sparehold's own old reports — as a review you tick through.
/// Nothing is removed until you review it, and a worktree is only ever removed
/// after its changes and local files are parked (the removal ledger is the
/// receipt, with the commands that bring it back). Dirty or changed trees are
/// shown but never tickable; the mode menu chooses how long things are kept
/// before they are offered, and the apply repeats the preview's numbers.
struct GuardianScreen: View {
    @State private var model = StorageReviewModel()
    /// The person's own pick for the next preview; nil until they pick. What the screen SHOWS
    /// (`mode`) comes from the preview on screen, because that is what an Apply runs with.
    @State private var chosen: GuardianMode?
    @Environment(JobStore.self) private var store
    /// Example rows for `SnapshotRunner`; nil in the app.
    var fixture: StorageRows?
    /// `SnapshotRunner`: the screen as it is with no preview behind it (no last-known list).
    var fixtureNoneOn = false

    private var mode: GuardianMode {
        GuardianMode(options: model.setting(kind: .guardian, chosen: (chosen ?? .balanced).options))
    }

    private var modeBinding: Binding<GuardianMode> {
        Binding(get: { mode }, set: { picked in
            if model.pick(picked.options, kind: .guardian, chosen: (chosen ?? .balanced).options, store) { chosen = picked }
        })
    }

    var body: some View {
        let words = model.words(kind: .guardian, chosen: (chosen ?? .balanced).options)
        StorageReviewScreen<GuardianCategory>(
            model: model, title: Names.Screen.guardian, kind: .guardian, screenKey: "guardian",
            // a new preview starts with the app's own pick; only SHOWING an existing preview (one made in
            // Terminal) follows that preview's setting
            options: model.phase == .lastKnown ? (chosen ?? .balanced).options : mode.options,
            parse: { GuardianReview.build(lines: $0.lines, banner: $0.banner).rows },
            // before the person picks, the newest logged preview of any mode; after, only that mode's
            lastKnownMatches: { [picked = chosen] block in
                if fixtureNoneOn { return false }
                return picked.map { StorageSetting.options(kind: .guardian, banner: block.banner) == $0.options } ?? true
            },
            applyTitle: words.applyTitle,
            confirmation: ReviewConfirmation(words: words),
            emptyText: "Looks for merged worktrees agents left behind, oversized package stores, and Sparehold's own old "
                + "reports. Nothing is removed until you review it, and a worktree is only ever removed after its changes "
                + "and local files are parked, with the commands that bring it back written down first.",
            destination: Names.Review.deletedPermanently)
            .toolbar {
                ToolbarItem {
                    // a menu whose label is the current choice, icon and title: the value is always in view
                    Menu {
                        Picker("Keep For", selection: modeBinding) {
                            ForEach(GuardianMode.allCases) { Label($0.title, systemImage: Self.symbol($0)).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(mode.title, systemImage: Self.symbol(mode))
                    }
                    .labelStyle(.titleAndIcon)
                    .help(mode.sentence)
                }
                .toolbarRank(.primary)
            }
            .onAppear { if let fixture { model.showFixture(fixture) } }
    }

    private static func symbol(_ mode: GuardianMode) -> String {
        switch mode {
        case .balanced: "scale.3d"
        case .keepLonger: "calendar.badge.clock"
        case .reclaimSooner: "calendar.badge.exclamationmark"
        }
    }
}
