import Foundation

/// Fast, allocation-light formatting used while building scenes (thousands of calls per layout).
enum Format {
    /// Finder-style decimal byte count: "0 bytes", "12 KB", "3.4 GB".
    static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        if v < 1000 { return "\(Int(v)) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var size = v / 1000
        var unit = 0
        while size >= 1000, unit < units.count - 1 {
            size /= 1000
            unit += 1
        }
        if size >= 100 || unit == 0 { return "\(Int(size.rounded())) \(units[unit])" }
        let tenths = (size * 10).rounded() / 10
        return "\(tenths) \(units[unit])"
    }

    static func count(_ value: Int64) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func items(_ value: Int64) -> String {
        value == 1 ? "1 item" : "\(count(value)) items"
    }

    nonisolated(unsafe) private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let dayCache = DayCache()

    /// Medium date string for a Unix timestamp, cached by calendar day.
    static func day(_ unixTime: Double?) -> String {
        guard let unixTime else { return "—" }
        return dayCache.string(for: unixTime)
    }

    static func dateTime(_ unixTime: Double?) -> String {
        guard let unixTime else { return "—" }
        return Date(timeIntervalSince1970: unixTime).formatted(date: .abbreviated, time: .shortened)
    }
}

/// Thread-safe cache of formatted days.
private final class DayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [Int: String] = [:]
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    func string(for unixTime: Double) -> String {
        let key = Int((unixTime / 86_400).rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let s = formatter.string(from: Date(timeIntervalSince1970: unixTime))
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = s
        return s
    }
}
