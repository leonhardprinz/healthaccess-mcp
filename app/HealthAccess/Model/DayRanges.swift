import Foundation

/// A set of calendar days, kept as sorted inclusive ranges of day numbers (days since 1970-01-01, Gregorian).
/// It is the queue of day files still to write: the gap since the last sync, and older history the user asked for.
/// Day numbers carry no time zone; a day is "2026-11-08" wherever the phone is.
struct DayRanges: Equatable, Sendable {
    private(set) var ranges: [ClosedRange<Int>] = []

    init() {}

    /// From the stored form, `[[from, to], …]`. Bad pairs are dropped.
    init(stored: [[Int]]) {
        for pair in stored where pair.count == 2 && pair[0] <= pair[1] {
            insert(pair[0]...pair[1])
        }
    }

    var stored: [[Int]] { ranges.map { [$0.lowerBound, $0.upperBound] } }
    var isEmpty: Bool { ranges.isEmpty }
    var count: Int { ranges.reduce(0) { $0 + $1.count } }
    var newest: Int? { ranges.last?.upperBound }
    var oldest: Int? { ranges.first?.lowerBound }

    func contains(_ day: Int) -> Bool { ranges.contains { $0.contains(day) } }

    /// Adds a range and merges it with every range it touches or overlaps.
    mutating func insert(_ range: ClosedRange<Int>) {
        var lower = range.lowerBound
        var upper = range.upperBound
        var kept: [ClosedRange<Int>] = []
        for existing in ranges {
            if existing.upperBound < lower - 1 || existing.lowerBound > upper + 1 {
                kept.append(existing)
            } else {
                lower = min(lower, existing.lowerBound)
                upper = max(upper, existing.upperBound)
            }
        }
        kept.append(lower...upper)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    mutating func remove(_ day: Int) {
        guard let i = ranges.firstIndex(where: { $0.contains(day) }) else { return }
        let range = ranges.remove(at: i)
        var parts: [ClosedRange<Int>] = []
        if range.lowerBound < day { parts.append(range.lowerBound...(day - 1)) }
        if range.upperBound > day { parts.append((day + 1)...range.upperBound) }
        ranges.insert(contentsOf: parts, at: i)
    }

    /// The newest `limit` days, newest first, without removing them.
    func newest(_ limit: Int) -> [Int] {
        var out: [Int] = []
        for range in ranges.reversed() {
            var day = range.upperBound
            while day >= range.lowerBound && out.count < limit {
                out.append(day)
                day -= 1
            }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: day numbers

    /// Days since 1970-01-01 for a civil date (proleptic Gregorian).
    static func number(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(_ number: Int) -> (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, month, day)
    }

    /// "2026-11-08" → day number.
    static func number(_ string: String) -> Int? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return number(year: parts[0], month: parts[1], day: parts[2])
    }

    static func string(_ number: Int) -> String {
        let c = civil(number)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// The local day a moment falls on.
    static func number(of date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return number(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Local noon of a day, safe to hand to anything that takes "a moment on that day".
    static func date(_ number: Int, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = civil(number)
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? Date(timeIntervalSince1970: Double(number) * 86_400 + 43_200)
    }
}
