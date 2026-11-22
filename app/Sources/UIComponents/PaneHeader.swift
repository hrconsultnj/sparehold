import SwiftUI

/// General-pane-style header: large tile, title, one-line description —
/// opens every settings pane so they all share the same anatomy.
public struct PaneHeader: View {
    let tile: PaneTile
    let title: String
    let caption: String
    /// A small line under the title, such as a version.
    let detail: String?

    public init(symbol: String, color: Color, title: String, caption: String) {
        self.tile = .symbol(symbol, color)
        self.title = title
        self.caption = caption
        self.detail = nil
    }

    /// The header of a screen about the app itself: its logo instead of a symbol tile.
    public init(logo: Image, title: String, detail: String? = nil, caption: String) {
        self.tile = .image(logo)
        self.title = title
        self.caption = caption
        self.detail = detail
    }

    /// A header with an explicit tile — symbol, picture, or a vendor brand
    /// (icon file, company monogram, or neutral symbol).
    public init(tile: PaneTile, title: String, caption: String) {
        self.tile = tile
        self.title = title
        self.caption = caption
        self.detail = nil
    }

    public var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Group {
                switch tile {
                case .symbol(let symbol, let color):
                    IconTile(symbol: symbol, color: color, side: 44)
                case .image(let logo):
                    logo.resizable().interpolation(.high).frame(width: Tokens.Icon.hero * 1.5, height: Tokens.Icon.hero * 1.5)
                case .brand(let brand, let color):
                    VendorEngineTile(brand: brand, symbol: brand.fallbackSymbol, color: color, side: Tokens.Icon.hero)
                }
            }
            .accessibilityHidden(true)  // decorative — title below already names the pane
            Text(title).font(.title2.weight(.bold))
            if let detail { Text(detail).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Tokens.Space.l)
        .padding(.horizontal, Tokens.Space.pane)
    }
}
