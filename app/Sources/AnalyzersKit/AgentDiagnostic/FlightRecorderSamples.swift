import Foundation

/// One flight-recorder sample (§7): the ring's `iso epoch disk_free_gb swap_used_mb swap_files wired_mb
/// compressed_mb pressure procs top5` line, read for the timeline's `recorder` rows. The fast-rate stretches
/// (10 s while pressure ran high or swap grew, against the 60 s base rate) stay visible — "the recorder
/// noticed" is the point of them.
public struct FlightSample: Identifiable, Hashable, Sendable {

    /// One `name:mb` entry of the sample's top-5 (command name only, never args or paths).
    public struct TopProcess: Hashable, Sendable {
        public let name: String
        public let megabytes: Double
    }

    public let iso: String
    public let epoch: TimeInterval
    public let diskFreeGB: Double?
    public let swapUsedMB: Double?
    public let swapFiles: Int?
    public let wiredMB: Double?
    public let compressedMB: Double?
    public let pressure: Int?
    public let procs: Int?
    public let top5: [TopProcess]
    /// The sample was taken at the fast rate: its gap from the previous sample is at most `fastGapThreshold`.
    public let fastRate: Bool

    public var date: Date { Date(timeIntervalSince1970: epoch) }
    public var id: TimeInterval { epoch }
}

/// Reads the flight recorder's ring file (§7) for the timeline's `recorder` rows and its fast-rate stretches.
public enum FlightRecorderSamples {

    /// The ring's header line, exact (§7) — the fixture carries it, and the probe holds the guard's phase-four
    /// writer to it. The ring is the guard's own format, not a run TSV, so it does not go through RunTSV.
    public static let headerLine =
        "# sparehold flight recorder v1: iso epoch disk_free_gb swap_used_mb swap_files wired_mb compressed_mb pressure procs top5"
    public static let columns = "iso epoch disk_free_gb swap_used_mb swap_files wired_mb compressed_mb pressure procs top5"

    /// A gap at most this long is the fast rate (10 s against the 60 s base) — the midpoint of the two rates.
    public static let fastGapThreshold: TimeInterval = 15

    /// Ring text → samples, oldest first. A `-` cell reads as unknown; a line the shape does not fit is
    /// skipped. The epoch column is the sample's time; fast-rate flags come from the gap to the previous sample.
    public static func parse(text: String) -> [FlightSample] {
        var samples: [FlightSample] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        where !line.hasPrefix("#") {
            let cells = line.components(separatedBy: "\t")
            guard cells.count >= 10, let epoch = TimeInterval(cells[1]) else { continue }
            func number(_ index: Int) -> Double? { cells[index] == "-" ? nil : Double(cells[index]) }
            let top5: [FlightSample.TopProcess] = cells[9] == "-" ? [] : cells[9]
                .components(separatedBy: ";")
                .compactMap { entry -> FlightSample.TopProcess? in
                    let parts = entry.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let megabytes = Double(parts[1]) else { return nil }
                    return FlightSample.TopProcess(name: String(parts[0]), megabytes: megabytes)
                }
            let fast = samples.last.map { previous in
                epoch >= previous.epoch && epoch - previous.epoch <= fastGapThreshold
            } ?? false
            samples.append(FlightSample(
                iso: cells[0], epoch: epoch,
                diskFreeGB: number(2), swapUsedMB: number(3),
                swapFiles: number(4).map(Int.init), wiredMB: number(5), compressedMB: number(6),
                pressure: number(7).map(Int.init), procs: number(8).map(Int.init),
                top5: top5, fastRate: fast))
        }
        return samples
    }

    /// The maximal runs of fast-rate samples — the recorder's own "something was happening" stretches.
    public static func fastStretches(in samples: [FlightSample]) -> [[FlightSample]] {
        var stretches: [[FlightSample]] = []
        var current: [FlightSample] = []
        for sample in samples where sample.fastRate {
            if let last = current.last, sample.epoch - last.epoch > fastGapThreshold {
                stretches.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { stretches.append(current) }
        return stretches
    }
}
