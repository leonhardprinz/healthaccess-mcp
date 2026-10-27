import Foundation

/// Double to Int that never traps: nil for NaN, infinity or anything beyond ±1e12.
/// Every number read from a file in the folder goes through this before it becomes an Int.
func safeInt(_ value: Double) -> Int? {
    value.isFinite && abs(value) < 1e12 ? Int(value.rounded()) : nil
}

/// A 1 to 10 score, or nil for anything else (files in the folder can be written by anyone).
func score1to10(_ value: Double) -> Int? {
    safeInt(value).flatMap { (1...10).contains($0) ? $0 : nil }
}

/// Text from a file shown in a notification or written into briefing.md: one line, no
/// control characters, at most `max` characters, so it cannot fake another line or section.
func oneLine(_ text: String, max: Int = 80) -> String {
    let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        .trimmingCharacters(in: .whitespaces)
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

enum Format {
    static func distance(_ meters: Double) -> String {
        if meters >= 10_000 { return String(format: "%.1f km", meters / 1000) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: meters)) ?? "\(safeInt(meters) ?? 0)") + " m"
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "about 35 min", rounded to 5 minutes; "about 1 h 10 min" above an hour.
    static func aboutMinutes(_ seconds: Int) -> String {
        let minutes = max(5, Int((Double(seconds) / 300).rounded()) * 5)
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
        }
        return "about \(minutes) min"
    }

    static func pace(_ secondsPer100m: Double) -> String {
        let total = Int(secondsPer100m.rounded())
        return String(format: "%d:%02d /100 m", total / 60, total % 60)
    }

    /// "Thu 23 Oct"
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "23 Oct 10:39"
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// "Sat 26 Oct 10:00"
    static func dayTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// "09:41"
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "just now", "2 min ago", "3 h ago", "Thu 09:41".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 24 * 3600 { return "\(seconds / 3600) h ago" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Rated 7 on your Watch", "Rated 6 with your AI", "Unrated".
    static func effortLine(effort: Int?, source: String?) -> String {
        guard let effort else { return "Unrated" }
        switch source {
        case "apple": return "Rated \(effort) on your Watch"
        case "ai": return "Rated \(effort) with your AI"
        default: return "Rated \(effort)"
        }
    }

    static func logStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func kcal(_ value: Double) -> String { "\(Int(value.rounded())) kcal" }

    /// "7:12 h" for sleep durations.
    static func hours(_ seconds: Int) -> String {
        String(format: "%d:%02d h", seconds / 3600, (seconds % 3600) / 60)
    }
}
