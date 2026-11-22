import SwiftUI
import UIComponents

/// The ONE container every settings pane uses: centered header as the first
/// row of the grouped form, pane name as the window title.
///
/// LESSON (v2.7.1 regression): the header must stay INSIDE the Form. Hoisting
/// it above the Form put it in the toolbar's backdrop region — rendered as a
/// light band with a doubled title. And no .scrollEdgeEffectStyle here: the
/// hard edge paints an opaque backdrop that fights the Settings window.
struct PaneScaffold<Content: View>: View {
    let tile: PaneTile
    let title: String
    let caption: String
    @ViewBuilder var content: Content

    init(symbol: String, color: Color, title: String, caption: String,
         @ViewBuilder content: () -> Content) {
        self.tile = .symbol(symbol, color)
        self.title = title
        self.caption = caption
        self.content = content()
    }

    /// A pane whose header tile is something other than a symbol — a vendor
    /// brand (icon file, company monogram) or a supplied picture.
    init(tile: PaneTile, title: String, caption: String,
         @ViewBuilder content: () -> Content) {
        self.tile = tile
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer(minLength: 0)
                    PaneHeader(tile: tile, title: title, caption: caption)
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            content
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }
}
