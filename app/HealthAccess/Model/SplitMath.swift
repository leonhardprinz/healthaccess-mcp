import Foundation

/// Splits of a run, walk or hike: where each whole km (or mile) was reached, from the Watch's own distance samples.
///
/// Each sample covers a few metres over a few seconds; a split ends inside the sample that crosses its boundary, at the
/// point found by spreading that sample's metres evenly over its time. Split times are moving time: the parts of a
/// split that fall inside a pause (the athlete's or the Watch's auto-pause) are not counted.
enum SplitMath {
    struct Piece: Sendable, Equatable {
        let start: Date
        let end: Date
        let metres: Double
    }

    /// A last part shorter than this is left out, the way the Watch leaves out the last few steps.
    static let minLastPartM: Double = 50

    static func splits(_ pieces: [Piece], unitM: Double, pauses: [DateInterval], hr: [(Date, Double)]) -> [SplitDoc] {
        guard unitM > 0 else { return [] }
        let sorted = pieces.filter { $0.metres > 0 && $0.metres.isFinite && $0.end >= $0.start }.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }
        var out: [SplitDoc] = []
        var covered = 0.0
        var splitStart = first.start
        var boundary = unitM
        for piece in sorted {
            let before = covered
            covered += piece.metres
            while covered >= boundary {
                // Where inside this piece the boundary lies, as a share of the piece (a fast piece can cross two).
                let fraction = (boundary - before) / piece.metres
                let at = piece.start.addingTimeInterval(piece.end.timeIntervalSince(piece.start) * min(max(fraction, 0), 1))
                out.append(split(from: splitStart, to: at, metres: unitM, pauses: pauses, hr: hr))
                splitStart = at
                boundary += unitM
            }
        }
        let rest = covered - (boundary - unitM)
        if rest >= minLastPartM, let last = sorted.last {
            out.append(split(from: splitStart, to: last.end, metres: rest, pauses: pauses, hr: hr))
        }
        return out
    }

    /// Pauses from the workout's events: pause → resume and motion paused → motion resumed. A pause with no end runs to
    /// `workoutEnd`.
    static func pauses(_ events: [(type: String, at: Date)], workoutEnd: Date) -> [DateInterval] {
        var out: [DateInterval] = []
        var manual: Date?
        var motion: Date?
        for e in events.sorted(by: { $0.at < $1.at }) {
            switch e.type {
            case "pause": manual = manual ?? e.at
            case "resume": if let s = manual { out.append(DateInterval(start: s, end: max(s, e.at))); manual = nil }
            case "motion_paused": motion = motion ?? e.at
            case "motion_resumed": if let s = motion { out.append(DateInterval(start: s, end: max(s, e.at))); motion = nil }
            default: break
            }
        }
        for s in [manual, motion].compactMap({ $0 }) where s < workoutEnd { out.append(DateInterval(start: s, end: workoutEnd)) }
        return out
    }

    static func movingSeconds(from: Date, to: Date, pauses: [DateInterval]) -> TimeInterval {
        let whole = max(0, to.timeIntervalSince(from))
        guard whole > 0 else { return 0 }
        let span = DateInterval(start: from, end: to)
        // Manual and auto-pause can overlap: merge before subtracting.
        var merged: [DateInterval] = []
        for p in pauses.compactMap({ span.intersection(with: $0) }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, p.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, p.end))
            } else {
                merged.append(p)
            }
        }
        return max(0, whole - merged.reduce(0) { $0 + $1.duration })
    }

    private static func split(from: Date, to: Date, metres: Double, pauses: [DateInterval], hr: [(Date, Double)]) -> SplitDoc {
        let moving = movingSeconds(from: from, to: to, pauses: pauses)
        let beats = hr.filter { $0.0 >= from && $0.0 < to }.map(\.1)
        return SplitDoc(start: from, end: to, distanceM: round1(metres), durationS: round1(moving),
                        paceSPerKm: metres > 0 && moving > 0 ? round1(moving / metres * 1000) : nil,
                        avgHr: beats.isEmpty ? nil : Int((beats.reduce(0, +) / Double(beats.count)).rounded()))
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
