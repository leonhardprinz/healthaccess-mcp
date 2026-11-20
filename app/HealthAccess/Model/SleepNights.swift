import Foundation

/// Which sleep belongs to a day. A night is credited to the day it ends on (the morning).
///
/// The Watch writes one night as dozens of short stage samples (core, deep, REM, awake). Counting each sample on the day
/// it ended split every night that crossed midnight over two day files. So the samples of each source are first joined
/// into sessions (a gap of more than an hour starts a new one), and a whole session counts for the day its last sample
/// ends in. Naps are sessions of their own and count for the day they end in too.
///
/// The asleep figures come from the one source with the most sleep that night, so Watch and iPhone are not added up.
/// Time in bed comes from whichever source recorded it: the Watch records stages only, the iPhone records time in bed
/// (Health → Sleep → Track Time in Bed with iPhone), and other apps may record either.
enum SleepNights {
    /// How far before the day's start the samples of a night that ends that day can begin.
    static let lookBack: TimeInterval = 24 * 3600
    /// A longer gap between two samples of one source starts a new session.
    static let sessionGap: TimeInterval = 3600

    /// `HKCategoryValueSleepAnalysis` raw values, kept here so this file needs no HealthKit.
    enum Value {
        static let inBed = 0
        static let asleepUnspecified = 1
        static let awake = 2
        static let asleepCore = 3
        static let asleepDeep = 4
        static let asleepREM = 5
        static let asleep: Set<Int> = [asleepUnspecified, asleepCore, asleepDeep, asleepREM]
    }

    struct Sample: Sendable, Equatable {
        let source: String       // bundle identifier
        let sourceName: String
        let value: Int
        let start: Date
        let end: Date

        var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    struct Session: Sendable, Equatable {
        let start: Date
        let end: Date
        let samples: [Sample]
    }

    struct Night: Sendable, Equatable {
        /// The source the asleep figures and the sessions come from.
        let sourceName: String
        /// That source's sessions ending in the day, oldest first.
        let sessions: [Session]
        /// Seconds in bed, from the source that recorded the most of it; nil when nobody recorded it.
        let inBedS: Int?

        var samples: [Sample] { sessions.flatMap(\.samples) }

        func seconds(_ values: Set<Int>) -> Int {
            Int(samples.filter { values.contains($0.value) }.reduce(0) { $0 + $1.seconds }.rounded())
        }
    }

    /// One source's samples joined into sessions.
    static func sessions(_ samples: [Sample]) -> [Session] {
        var out: [Session] = []
        var current: [Sample] = []
        var currentEnd = Date.distantPast
        for s in samples.sorted(by: { $0.start < $1.start }) {
            if let first = current.first, s.start.timeIntervalSince(currentEnd) > sessionGap {
                out.append(Session(start: first.start, end: currentEnd, samples: current))
                current = []
            }
            if current.isEmpty { currentEnd = s.end }
            current.append(s)
            currentEnd = max(currentEnd, s.end)
        }
        if let first = current.first { out.append(Session(start: first.start, end: currentEnd, samples: current)) }
        return out
    }

    /// The night (and naps) that end inside `[dayStart, dayEnd)`. `samples` must reach back `lookBack` before `dayStart`.
    static func night(_ samples: [Sample], dayStart: Date, dayEnd: Date) -> Night? {
        let bySource = Dictionary(grouping: samples, by: \.source)
        var kept: [String: [Session]] = [:]
        for (source, own) in bySource {
            let ending = sessions(own).filter { $0.end >= dayStart && $0.end < dayEnd }
            if !ending.isEmpty { kept[source] = ending }
        }
        func total(_ source: String, _ values: Set<Int>) -> TimeInterval {
            (kept[source] ?? []).flatMap(\.samples).filter { values.contains($0.value) }.reduce(0) { $0 + $1.seconds }
        }
        // Ties go to the source that sorts first, so the same data always gives the same file.
        func most(_ values: Set<Int>) -> String? {
            kept.keys.sorted().max { total($0, values) < total($1, values) }.flatMap { total($0, values) > 0 ? $0 : nil }
        }
        let inBedSource = most([Value.inBed])
        guard let best = most(Value.asleep) ?? inBedSource, let chosen = kept[best] else { return nil }
        let inBed = inBedSource.map { Int(total($0, [Value.inBed]).rounded()) }
        return Night(sourceName: chosen.first?.samples.first?.sourceName ?? best, sessions: chosen, inBedS: inBed)
    }
}
