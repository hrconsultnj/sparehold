import SwiftUI
import AppKit

/// One engine's vendor identity, as far as this Mac can prove it: the real
/// company behind the CLI, and where the vendor's OWN icon files live on
/// disk. Nothing here is a bundled or drawn logo — the artwork is loaded at
/// runtime from the vendor's installed app (trademark files stay out of this
/// repository, and the icon follows the vendor's updates for free). When no
/// vendor file exists, the tile falls back to a monogram of the company's
/// real name — a letter, never a fabricated logo — and then to the neutral
/// symbol tile the rest of the app uses.
public struct EngineBrand: Sendable {
    /// The engine id as stored in `config.agent.engine` (`AGENT_ENGINE`).
    public let engineID: String
    /// The company that makes the engine — the monogram's source of truth.
    public let company: String
    /// First letter of the company's real name; the fallback tile's content.
    public let monogram: String
    /// The vendor-provided icon files this Mac may carry, in preference
    /// order, tilde-expanded and checked with `fileExists` at render. Paths
    /// are the vendors' own bundle resources — never copied into Sparehold.
    public let iconLocations: [String]
    /// The neutral symbol tile when neither an icon file nor a monogram
    /// applies (unknown engine label).
    public let fallbackSymbol: String
}

/// The EngineIconLocations table: per engine, the vendor icon files known to
/// ship on a Mac, documented where they come from. Checked at render —
/// a missing file (vendor app not installed) simply falls through.
public enum EngineIconLocations {
    /// Anthropic's Claude Code. `electron.icns` is the Claude desktop app's
    /// own `CFBundleIconFile` — the sunburst logo ships inside that file
    /// even though the name is Electron's default. No Claude CLI install
    /// ships an icon file, so the desktop app on disk is the one source.
    public static let claude = EngineBrand(
        engineID: "claude",
        company: "Anthropic",
        monogram: "A",
        iconLocations: [
            "/Applications/Claude.app/Contents/Resources/electron.icns",
            "~/Applications/Claude.app/Contents/Resources/electron.icns",
        ],
        fallbackSymbol: "chevron.left.forwardslash.chevron.right")

    /// OpenAI's Codex. The ChatGPT desktop app ships icon files for its
    /// Codex integration; the dark-color tile reads on both light and dark
    /// window chrome, so it is preferred over the light variant (which
    /// vanishes into light backgrounds).
    public static let codex = EngineBrand(
        engineID: "codex",
        company: "OpenAI",
        monogram: "O",
        iconLocations: [
            "/Applications/ChatGPT.app/Contents/Resources/icon-codex-dark-color.png",
            "~/Applications/ChatGPT.app/Contents/Resources/icon-codex-dark-color.png",
            "~/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png",
        ],
        fallbackSymbol: "curlybraces.square")

    /// The brand for an engine id (the `config.agent.engine` value), if one
    /// is known to the table.
    public static func brand(engineID: String) -> EngineBrand? {
        switch engineID {
        case claude.engineID: claude
        case codex.engineID: codex
        default: nil
        }
    }

    /// The brand for the label a reply or row carries ("Claude Code",
    /// "Codex") — the strings the engines use to name themselves.
    public static func brand(label: String) -> EngineBrand? {
        let lowered = label.lowercased()
        if lowered.contains("claude") { return claude }
        if lowered.contains("codex") { return codex }
        return nil
    }
}

/// The in-memory cache behind vendor tiles: one load per icon per run, keyed
/// by engine id. Loading stays on the main actor — tiles render there, and a
/// one-time read of a local file is not worth a hop.
@MainActor
public final class EngineIconCache {
    public static let shared = EngineIconCache()

    private let images = NSCache<NSString, NSImage>()

    private init() {}

    /// The vendor's icon for a brand, loaded from the first location that
    /// exists on this Mac; nil when none does (the tile then shows the
    /// company monogram).
    public func image(for brand: EngineBrand) -> NSImage? {
        let key = brand.engineID as NSString
        if let cached = images.object(forKey: key) { return cached }
        for location in brand.iconLocations {
            let path = (location as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path),
                  let image = NSImage(contentsOfFile: path) else { continue }
            images.setObject(image, forKey: key)
            return image
        }
        return nil
    }
}

/// The tile an engine row, header or reply carries: the vendor's own icon
/// when this Mac has one, the real company's initial when it does not, or
/// the neutral symbol tile — the same shape language as `IconTile` in every
/// state.
public struct VendorEngineTile: View {
    /// The known vendor — nil means "no vendor here" (on-device, custom),
    /// which keeps the plain symbol tile.
    let brand: EngineBrand?
    /// The neutral symbol when `brand` is nil.
    let symbol: String
    let color: Color
    let side: CGFloat

    public init(brand: EngineBrand?, symbol: String, color: Color, side: CGFloat) {
        self.brand = brand
        self.symbol = symbol
        self.color = color
        self.side = side
    }

    public var body: some View {
        if let brand, let image = EngineIconCache.shared.image(for: brand) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.24))
        } else if let brand {
            // No vendor icon on this Mac: the company's real initial in the
            // tile — headline weight at IconTile's glyph scale, on the same
            // tile shape. A letter names the maker; it draws no logo.
            Text(brand.monogram)
                .font(.system(size: side * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: side * 0.24))
        } else {
            IconTile(symbol: symbol, color: color, side: side)
        }
    }
}

/// What a pane header's tile shows — the classic symbol tile, a supplied
/// picture (the app's own logo), or a vendor brand tile.
public enum PaneTile {
    case symbol(String, Color)
    case image(Image)
    case brand(EngineBrand, Color)
}
