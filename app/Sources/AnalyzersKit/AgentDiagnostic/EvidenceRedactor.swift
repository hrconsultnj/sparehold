import Foundation

/// The ONE redaction service (DEC-7), applied before anything is shown or copied. The rules (§6): the home
/// prefix becomes `~`; any other absolute path collapses to `…/<folder>`; the account's short name becomes
/// `<user>`; the hostname becomes `<host>`; token-shaped strings (`sk-…`, `ghp_…`, `gho_…`, `xoxb-…`, `AKIA…`,
/// `Bearer …`) become `<redacted>`. The defaults read this account (what the app shows); a fixture probe names
/// its own planted user, host and home instead and asserts none of them survive.
public struct EvidenceRedactor: Sendable {

    private let homePath: String
    private let user: String
    private let host: String

    /// `home` is the folder paths are shortened against; `user` and `host` default to this account's own short
    /// name and hostname. A probe passes its fixture's planted values so the test does not depend on whose Mac
    /// runs it.
    public init(home: URL = AnalyzersPaths.home, user: String? = nil, host: String? = nil) {
        self.homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        self.user = user ?? NSUserName()
        self.host = host ?? ProcessInfo.processInfo.hostName
    }

    /// The token shapes the issue names, as regular expressions (the same families the secrets check sweeps).
    private static let tokenPatterns: [String] = [
        "sk-[A-Za-z0-9_-]{8,}",
        "ghp_[A-Za-z0-9]{20,}",
        "gho_[A-Za-z0-9]{20,}",
        "github_pat_[A-Za-z0-9_]{22,}",
        "xox[baprs]-[A-Za-z0-9-]{10,}",
        "AKIA[0-9A-Z]{16}",
        "Bearer +[A-Za-z0-9._~+/=-]{8,}",
    ]

    /// An absolute path with at least two components that is not already `~`-shortened; the replacement keeps
    /// only the folder it ends in (`/private/var/db/fixture` → `…/fixture`) — a path outside the standard
    /// folders says where a person keeps nothing the evidence needs. The look-behind keeps the `~` form and
    /// relative `a/b` text out of the match.
    private static let otherPathPattern = "(?<![~\\w])/(?:[^\\s/:\"']+/)*([^\\s/:\"']+)"

    /// `text` with every rule applied, in the order the rules need: tokens, the home prefix, other paths, then
    /// the account and host names.
    public func redact(_ text: String) -> String {
        var out = text
        for pattern in Self.tokenPatterns {
            out = out.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        if out.contains(homePath) {
            out = out.replacingOccurrences(of: homePath + "/", with: "~/")
            out = out.replacingOccurrences(of: homePath, with: "~")
        }
        out = out.replacingOccurrences(of: Self.otherPathPattern, with: "…/$1", options: .regularExpression)
        out = out.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: user),
                                       with: "<user>", options: .regularExpression)
        out = out.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: host),
                                       with: "<host>", options: .regularExpression)
        return out
    }
}
