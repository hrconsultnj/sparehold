import Foundation

/// The agent inventory (agents/agent-sweep.sh's output): what is on this Mac
/// right now — installed coding-agent CLIs (the ONE list's exe rows found on
/// PATH), the live sessions (the same walk the Memory Guard's exemption uses),
/// the guard's headroom figures folded in with a staleness flag, and the git
/// worktrees under the Guardian's roots. The Ask agent's `readAgents`
/// capability reads this file; nothing here is a decision Sparehold makes.
public struct AgentInventory: Decodable, Equatable, Sendable {

    public struct InstalledAgent: Decodable, Equatable, Sendable {
        public let name: String
        /// exe | container — the kinds presence can be claimed from; a
        /// fragment is never claimed installed (unknown, never a guess).
        public let kind: String
        public let path: String
    }

    public struct LiveSession: Decodable, Equatable, Sendable {
        public let pid: Int
        public let command: String
    }

    public struct Worktree: Decodable, Equatable, Sendable {
        public let path: String
        public let branch: String
        public let kb: Int
        /// true when the branch is an ancestor of main; nil when detached —
        /// the sweep says unknown, never a guess.
        public let mergedToMain: Bool?

        enum CodingKeys: String, CodingKey {
            case path, branch, kb
            case mergedToMain = "merged_to_main"
        }
    }

    public struct Headroom: Decodable, Equatable, Sendable {
        public init(diskFreeGB: Double?, swapUsedMB: Double?, wiredMB: Double?, compressedMB: Double?,
                    pressure: Int?, updated: String, stale: Bool) {
            self.diskFreeGB = diskFreeGB
            self.swapUsedMB = swapUsedMB
            self.wiredMB = wiredMB
            self.compressedMB = compressedMB
            self.pressure = pressure
            self.updated = updated
            self.stale = stale
        }

        public let diskFreeGB: Double?
        public let swapUsedMB: Double?
        public let wiredMB: Double?
        public let compressedMB: Double?
        public let pressure: Int?
        public let updated: String
        /// true when the guard has not ticked for over two minutes: an agent
        /// reading a stale file is reading history, and the JSON says so.
        public let stale: Bool

        enum CodingKeys: String, CodingKey {
            case diskFreeGB = "disk_free_gb"
            case swapUsedMB = "swap_used_mb"
            case wiredMB = "wired_mb"
            case compressedMB = "compressed_mb"
            case pressure, updated, stale
        }
    }

    public let sweptAt: String
    public let agents: [InstalledAgent]
    public let sessionCount: Int
    public let sessions: [LiveSession]
    /// Absent when the guard's headroom file was missing — the sweep invents
    /// nothing, and neither does this parser.
    public let headroom: Headroom?
    public let worktrees: [Worktree]

    enum CodingKeys: String, CodingKey {
        case sweptAt = "swept_at"
        case agents, sessions, sessionCount = "session_count"
        case headroom, worktrees
    }
}

/// Reads the inventory the sweep wrote.
public enum AgentInventoryReader {

    /// The newest inventory, nil when there is none (the Ask tool says so and
    /// names the scan to run).
    public static func load(url: URL) -> AgentInventory? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(AgentInventory.self, from: data)
    }

    /// How old the inventory is, in a sentence: freshness is part of the
    /// answer, because "what is running now" expires.
    public static func age(_ inventory: AgentInventory, now: Date = Date()) -> String {
        guard let swept = Self.inventoryDate(inventory.sweptAt) else { return "the sweep's time could not be read" }
        let minutes = Int(now.timeIntervalSince(swept) / 60)
        if minutes < 2 { return "swept just now" }
        if minutes < 60 { return "swept \(minutes) minutes ago" }
        return "swept \(minutes / 60)h \(minutes % 60)m ago"
    }

    /// The sweep writes a local-time ISO stamp ("2026-11-27T18:50:16-0500");
    /// nil when it cannot be read.
    static func inventoryDate(_ iso: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)
    }
}
