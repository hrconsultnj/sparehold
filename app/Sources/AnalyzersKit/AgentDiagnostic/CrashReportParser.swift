import Foundation

/// Parses macOS diagnostic reports (§1): an `.ips` file is line 1 a JSON header (`bug_type`, `captureTime`,
/// `incident_id`) and the rest a JSON body; a legacy `.panic` file is plain text whose first date-looking line
/// is the event time. A field the report lacks parses as nil, never a guess; an unrecognized `bug_type` is kept.
///
/// The file name's `-YYYY-MM-DD-HHMMSS` part is the save time, stamped by the reporting Mac's local clock. A
/// header that writes its own offset (`…+01:00`) names that clock, so the name is read in the header's offset;
/// the stock macOS shape (`…Z`) is read in this Mac's local zone — the clock that stamped the name it saved.
public enum CrashReportParser {

    /// Reads a report file: `.ips` by the two-part JSON shape, `.panic` (and anything that does not open with
    /// a brace) as legacy text.
    public static func parse(url: URL) -> CrashReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data, fileName: url.lastPathComponent)
    }

    /// The same parse over data already read, named by the file it came from — how a fixture probe tests a
    /// report under the incident-shaped name it would have been saved as.
    public static func parse(data: Data, fileName: String) -> CrashReport? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if fileName.hasSuffix(".panic") || !text.hasPrefix("{") { return parsePanic(text: text, fileName: fileName) }
        return parseIPS(text: text, fileName: fileName)
    }

    // MARK: .ips

    private static func parseIPS(text: String, fileName: String) -> CrashReport? {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = all.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let header = jsonObject(all[headerIndex]) else { return nil }
        // The body is every line after the header; a report whose body does not parse still carries its header.
        let body = jsonObject(all[(headerIndex + 1)...].joined(separator: "\n")) ?? [:]

        let captureText = header["captureTime"] as? String ?? ""
        let zone = fileNameZone(captureTime: captureText)

        // Memory figures sit at the body's top level; some report kinds nest them under a status object.
        let containers: [[String: Any]] = [body,
                                           body["memoryStatus"] as? [String: Any] ?? [:],
                                           body["system"] as? [String: Any] ?? [:]]
        func number(_ key: String) -> Double? {
            for container in containers {
                if let value = container[key] as? NSNumber { return value.doubleValue }
                if let value = container[key] as? String, let parsed = Double(value) { return parsed }
            }
            return nil
        }
        func flag(_ key: String) -> Bool? {
            for container in containers where container[key] != nil {
                return (container[key] as? NSNumber)?.boolValue
            }
            return nil
        }

        // GB, not pages (issue §1): page size comes from the report when it says, else the arm64 default.
        let pageSize = number("pagesize") ?? 16_384
        func pagesToGB(_ pages: Double?) -> Double? { pages.map { $0 * pageSize / 1_073_741_824 } }

        return CrashReport(
            id: header["incident_id"] as? String ?? fileName,
            bugType: CrashReport.BugType(headerBugType: header["bug_type"] as? String ?? "unknown"),
            eventTime: eventTime(from: captureText),
            captureTimeText: captureText,
            fileTime: fileNameTime(in: fileName, zone: zone),
            panicString: header["panicString"] as? String ?? body["panicString"] as? String,
            pagesFreeGB: pagesToGB(number("pagesFree")),
            wiredGB: pagesToGB(number("wired")),
            compressedGB: pagesToGB(number("compressor") ?? number("compressed")),
            compressorSegmentLimitReached: flag("compressorSegmentLimitReached"),
            swapFiles: number("swapfiles").map(Int.init),
            swapUsedGB: number("swapUsage").map { $0 / 1_073_741_824 },
            procName: body["procName"] as? String,
            fileName: fileName)
    }

    /// A brace-led line or block read as a JSON object; nil when it is not one.
    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    /// ISO8601 with offset (`…Z` or `…+01:00`, with or without fractional seconds). nil when the header writes
    /// no readable time — the row says so, never a guess from the save date.
    static func eventTime(from captureTime: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: captureTime) { return date }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: captureTime)
    }

    /// The clock the file name was stamped with: a header that writes its own offset (`…+01:00`) names it; the
    /// stock macOS shape (`…Z`) means this Mac's local zone, which stamped the name it saved.
    static func fileNameZone(captureTime: String) -> TimeZone {
        if let range = captureTime.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) {
            let offset = captureTime[range]
            let sign = offset.first == "-" ? -1 : 1
            let parts = offset.components(separatedBy: CharacterSet(charactersIn: "+-:")).filter { !$0.isEmpty }
            if let hours = Int(parts.first ?? ""), let minutes = Int(parts.last ?? "") {
                return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60)) ?? .current
            }
        }
        return .current
    }

    /// The `-YYYY-MM-DD-HHMMSS` tail of a report file name, read in `zone` — the save time. nil when the name
    /// carries no time in that shape (a bare fixture name keeps `fileTime` nil rather than guessing).
    public static func fileNameTime(in fileName: String, zone: TimeZone) -> Date? {
        let stem = (fileName as NSString).deletingPathExtension
        guard stem.count >= 17 else { return nil }
        let tail = String(stem.suffix(17))
        let bytes = Array(tail.utf8)
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard bytes[index] >= 48, bytes[index] <= 57 else { return nil }
                value = value * 10 + Int(bytes[index]) - 48
            }
            return value
        }
        guard bytes[4] == UInt8(45), bytes[7] == UInt8(45), bytes[10] == UInt8(45),
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(13..<15), let second = digits(15..<17)
        else { return nil }
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: parts)
    }

    // MARK: legacy .panic

    /// A legacy `.panic` text file: its first date-looking line is the event time; when none parses, the event
    /// time is unknown and the row says so — never a guess from the save date.
    static func parsePanic(text: String, fileName: String) -> CrashReport? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let eventTime = lines.compactMap(legacyTime).first
        let panicString = lines.first { $0.contains("panic(") }
        return CrashReport(
            id: fileName,
            bugType: .panic,
            eventTime: eventTime,
            captureTimeText: eventTime.map { legacyFormat.string(from: $0) } ?? "",
            fileTime: fileNameTime(in: fileName, zone: .current),
            panicString: panicString,
            pagesFreeGB: nil, wiredGB: nil, compressedGB: nil,
            compressorSegmentLimitReached: nil, swapFiles: nil, swapUsedGB: nil,
            procName: nil,
            fileName: fileName)
    }

    /// The date line a saved panic opens with ("Sat Nov 21 09:03:45 2026").
    private static let legacyFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static func legacyTime(_ line: String) -> Date? {
        legacyFormat.date(from: line.trimmingCharacters(in: .whitespaces))
    }
}
