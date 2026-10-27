import Foundation

/// `briefing.md`: one page any AI can read without the MCP. Written after every sync and after every rating or plan
/// status change, overwritten each time. Sections and limits per docs/schema.md "briefing.md".
enum Briefing {
    static func loadVitals(folder: FolderStore, days: Int, now: Date = Date()) -> [VitalsDoc] {
        guard let names = try? folder.list("vitals") else { return [] }
        let cutoff = HealthAccessJSON.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        return names.compactMap { name -> VitalsDoc? in
            let day = String(name.dropLast(".json".count))
            guard day >= cutoff, let data = try? folder.read("vitals/\(name)") else { return nil }
            return try? HealthAccessJSON.decode(VitalsDoc.self, from: data)
        }
        .sorted { $0.date < $1.date }
    }

    static func write(folder: FolderStore, entries: [IndexEntry], effortSources: [String: String], plans: [PlanItem]) throws {
        let vitals = loadVitals(folder: folder, days: 21)
        let text = render(entries: entries, effortSources: effortSources, vitals: vitals, plans: plans)
        try folder.write(Data(text.utf8), to: "briefing.md")
    }

    static func render(entries: [IndexEntry], effortSources: [String: String], vitals: [VitalsDoc], plans: [PlanItem],
                       now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# Health Access briefing for the athlete, written \(stamp(now))")
        lines.append("")

        lines.append("## Last 4 weeks")
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = .current
        for offset in 0..<4 {
            guard let weekDate = iso.date(byAdding: .weekOfYear, value: -offset, to: now),
                  let interval = iso.dateInterval(of: .weekOfYear, for: weekDate) else { continue }
            let week = iso.component(.weekOfYear, from: weekDate)
            let label = "Week \(week) (\(day(interval.start)) to \(day(interval.end.addingTimeInterval(-1))))"
            let inWeek = entries.filter { interval.contains($0.start) }
            guard !inWeek.isEmpty else {
                lines.append("- \(label): no sessions")
                continue
            }
            let distance = inWeek.compactMap(\.distanceM).reduce(0, +)
            let time = inWeek.map(\.durationS).reduce(0, +)
            var line = "- \(label): \(inWeek.count) session\(inWeek.count == 1 ? "" : "s"), \(metres(distance)), \(Format.duration(time))"
            let efforts = inWeek.compactMap(\.effort)
            if !efforts.isEmpty {
                let mean = Double(efforts.reduce(0, +)) / Double(efforts.count)
                line += ", mean effort \(String(format: "%.1f", mean)) (\(efforts.count) rated)"
            }
            lines.append(line)
        }
        lines.append("")

        lines.append("## Recent sessions")
        if entries.isEmpty { lines.append("- none yet") }
        for entry in entries.prefix(10) {
            var parts = [dayTime(entry.start), entry.planName ?? ActivityMapping.title(entry.activity)]
            if let d = entry.distanceM { parts.append(metres(d)) }
            parts.append(Format.duration(entry.durationS))
            parts.append(entry.avgHr.map { "avg HR \($0)" } ?? "no HR")
            if let effort = entry.effort {
                let source = effortSources[entry.id].map { " (\($0))" } ?? ""
                parts.append("effort \(effort)\(source)")
            } else {
                parts.append("not rated")
            }
            lines.append("- " + parts.joined(separator: " · "))
        }
        lines.append("")

        lines.append("## Vitals")
        var vitalLines: [String] = []
        if let line = vitalLine("Resting HR", vitals, { $0.restingHr.map(Double.init) }, format: { "\(Int($0)) bpm" }) { vitalLines.append(line) }
        if let line = vitalLine("HRV", vitals, { $0.hrvSdnnMs }, format: { String(format: "%.0f ms", $0) }) { vitalLines.append(line) }
        if let line = vitalLine("Sleep", vitals, { $0.sleepS.map(Double.init) }, format: { Format.hours(Int($0)) }) { vitalLines.append(line) }
        if let line = vitalLine("Weight", vitals, { $0.bodyMassKg }, format: { String(format: "%.1f kg", $0) }) { vitalLines.append(line) }
        if let line = vitalLine("Steps", vitals, { $0.steps.map(Double.init) }, format: { "\(Int($0))" }) { vitalLines.append(line) }
        if let line = vitalLine("VO2max", vitals, { $0.vo2max }, format: { String(format: "%.1f", $0) }) { vitalLines.append(line) }
        lines.append(contentsOf: vitalLines.isEmpty ? ["- nothing recorded in the last 21 days"] : vitalLines)
        lines.append("")

        lines.append("## Next session")
        let waiting = plans.filter { $0.state == .pending }
        if let next = waiting.first, let doc = next.doc {
            lines.append("\(oneLine(doc.name)): \(doc.sportWords), \(doc.summaryLine), waiting for Put on Watch")
        } else {
            lines.append("none")
        }
        lines.append("")

        lines.append("## Open")
        let unrated = entries.filter { $0.effort == nil }
        for entry in unrated.prefix(5) {
            let what = entry.distanceM.map { " (\(metres($0)))" } ?? ""
            lines.append("- Unrated: \(day(entry.start)) \(ActivityMapping.title(entry.activity).lowercased())\(what)")
        }
        if unrated.count > 5 { lines.append("- and \(unrated.count - 5) more unrated sessions") }
        for plan in waiting { lines.append("- Plan waiting for Put on Watch: \(oneLine(plan.name))") }
        if unrated.isEmpty && waiting.isEmpty { lines.append("- nothing") }
        lines.append("")

        lines.append("## Limits")
        lines.append("Health data can be read only while the phone is unlocked, so a session finished with the phone locked is written on the next unlock.")
        lines.append("The Watch keeps its own pool length; a plan cannot set it.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: pieces (fixed en_US_POSIX formatting: the reader is an AI, not the phone's locale)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static func stamp(_ date: Date) -> String {
        "\(formatter("yyyy-MM-dd HH:mm").string(from: date)) (\(TimeZone.current.identifier))"
    }

    /// "23 Oct"
    private static func day(_ date: Date) -> String { formatter("d MMM").string(from: date) }

    /// "Thu 23 Oct 10:39"
    private static func dayTime(_ date: Date) -> String { formatter("EEE d MMM HH:mm").string(from: date) }

    /// "1100 m" or "14.8 km", no grouping separators.
    private static func metres(_ meters: Double) -> String {
        meters >= 10_000 ? String(format: "%.1f km", meters / 1000) : "\(safeInt(meters) ?? 0) m"
    }

    /// "- Resting HR 61 bpm (25 Oct), 21-day direction: flat"
    private static func vitalLine(_ name: String, _ vitals: [VitalsDoc], _ pick: (VitalsDoc) -> Double?, format: (Double) -> String) -> String? {
        let points = vitals.compactMap { doc -> (String, Double)? in pick(doc).map { (doc.date, $0) } }
        guard let latest = points.last else { return nil }
        let date = HealthAccessJSON.date(latest.0 + "T12:00:00Z").map(day) ?? latest.0
        return "- \(name) \(format(latest.1)) (\(date)), 21-day direction: \(direction(points.map(\.1)))"
    }

    /// Mean of the newest third against the mean of the rest; ±3 % is flat.
    static func direction(_ values: [Double]) -> String {
        guard values.count >= 4 else { return "not enough days yet" }
        let split = max(1, values.count / 3)
        let recent = values.suffix(split)
        let earlier = values.prefix(values.count - split)
        let a = recent.reduce(0, +) / Double(recent.count)
        let b = earlier.reduce(0, +) / Double(earlier.count)
        guard b != 0 else { return "flat" }
        let change = (a - b) / b
        if change > 0.03 { return "up" }
        if change < -0.03 { return "down" }
        return "flat"
    }
}
