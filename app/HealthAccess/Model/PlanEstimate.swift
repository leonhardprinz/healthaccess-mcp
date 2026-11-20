import Foundation

/// What the app says about a plan before it reaches the Watch: "900 m · 5 parts · about 35 min" and the parts as text.
extension PlanDoc {
    /// One executed part per entry: the warm-up, every repeat of every block step, the cool-down.
    struct Part: Identifiable, Hashable {
        let id: String
        let section: String   // "Warm-up", "Block 2 × 3", "Cool-down"
        let label: String     // the wrist label, or the kind when the AI gave none
        let goal: String      // "200 m" | "0:45" | "until you tap"
        let zone: Int?
        /// "4:50–5:10 per km", or "30.0–33.0 km/h" on a bike: the Watch taps outside it.
        var pace: String? = nil

        /// "FR easy, long strokes · 200 m · zone 1"
        var line: String {
            var text = "\(label) · \(goal)"
            if let zone { text += " · zone \(zone)" }
            if let pace { text += " · \(pace)" }
            return text
        }
    }

    /// Planned metres over all distance goals (time goals excluded), repeats included.
    var plannedDistance: Double? {
        if let pacer { return pacer.distanceM }
        var total = 0.0
        func add(_ s: PlanStep?, times: Int = 1) {
            guard let s, s.goal.type == "distance_m" else { return }
            total += s.goal.value * Double(times)
        }
        add(warmup)
        for b in blocks { for s in b.steps { add(s, times: b.repeatCount) } }
        add(cooldown)
        return total > 0 ? total : nil
    }

    /// Seconds per metre used for distance goals, a relaxed pace per sport: 2:30 per 100 m swimming, 2:00 per 500 m
    /// rowing, 6:00 per km running, 11:00 per km walking, 13:00 per km hiking, 22 km/h cycling.
    private var secondsPerMetre: Double {
        switch sport {
        case "indoor_row": return 0.24
        case "run", "indoor_run": return 0.36
        case "walk": return 0.66
        case "hike": return 0.78
        case "cycle", "indoor_cycle": return 0.164
        default: return 1.5
        }
    }

    /// Time estimate: distance goals at the sport's pace, time goals as they are, an open step (a set) as 45 s, rests
    /// included. A pacer plan takes its own time.
    var estimatedSeconds: Int {
        if let pacer { return safeInt(pacer.timeS) ?? 0 }
        func seconds(_ s: PlanStep?) -> Double {
            guard let s else { return 0 }
            switch s.goal.type {
            case "distance_m": return s.goal.value * secondsPerMetre
            case "open": return 45
            default: return s.goal.value
            }
        }
        var total = seconds(warmup) + seconds(cooldown)
        for b in blocks { total += b.steps.map(seconds).reduce(0, +) * Double(b.repeatCount) }
        return safeInt(total) ?? 0
    }

    /// "900 m · 5 parts · about 35 min"
    var summaryLine: String {
        if let pacer {
            return "\(Format.distance(pacer.distanceM)) in \(Format.duration(safeInt(pacer.timeS) ?? 0)) · \(pacerPace(pacer))"
        }
        var parts: [String] = []
        if let d = plannedDistance { parts.append(Format.distance(d)) }
        parts.append("\(totalSteps) part\(totalSteps == 1 ? "" : "s")")
        parts.append(Format.aboutMinutes(estimatedSeconds))
        return parts.joined(separator: " · ")
    }

    /// "pool swim", "indoor row": the trailing word on the card.
    var sportWords: String { ActivityMapping.title(sport).lowercased() }

    /// "5:00 per km" for a run, "30 km/h" for a ride.
    private func pacerPace(_ pacer: PlanPacer) -> String {
        guard pacer.distanceM > 0, pacer.timeS > 0 else { return "" }
        if sport == "cycle" { return String(format: "%.1f km/h", pacer.distanceM / pacer.timeS * 3.6) }
        return "\(Format.duration(safeInt(pacer.timeS / pacer.distanceM * 1000) ?? 0)) per km"
    }

    var parts: [Part] {
        if let pacer {
            return [Part(id: "pacer", section: "Pacer", label: "Even pace, \(pacerPace(pacer))",
                         goal: "\(Format.distance(pacer.distanceM)) in \(Format.duration(safeInt(pacer.timeS) ?? 0))", zone: nil)]
        }
        func goalText(_ s: PlanStep) -> String {
            switch s.goal.type {
            case "distance_m": return Format.distance(s.goal.value)
            case "open": return "until you tap"
            default: return Format.duration(safeInt(s.goal.value) ?? 0)
            }
        }
        func kindWord(_ s: PlanStep, fallback: String) -> String {
            let kind = s.kind ?? (s.goal.type == "time_s" ? "recovery" : "work")
            switch kind {
            case "recovery": return "Rest"
            case "work": return fallback
            default: return kind.capitalized
            }
        }
        func paceText(_ s: PlanStep) -> String? {
            guard let p = s.paceRange else { return nil }
            if sport == "cycle" || sport == "indoor_cycle" {
                return String(format: "%.1f–%.1f km/h", 3600 / p.slow, 3600 / p.fast)
            }
            return "\(Format.duration(safeInt(p.fast) ?? 0))–\(Format.duration(safeInt(p.slow) ?? 0)) per km"
        }
        var out: [Part] = []
        if let w = warmup {
            out.append(Part(id: "warmup", section: "Warm-up", label: w.label ?? "Warm-up", goal: goalText(w), zone: w.zone, pace: paceText(w)))
        }
        for (i, block) in blocks.enumerated() {
            let section = block.repeatCount > 1 ? "Block \(i + 1) × \(block.repeatCount)" : "Block \(i + 1)"
            for (j, step) in block.steps.enumerated() {
                out.append(Part(id: "\(i).\(j)", section: section, label: step.label ?? kindWord(step, fallback: "Work"),
                                goal: goalText(step), zone: step.zone, pace: paceText(step)))
            }
        }
        if let c = cooldown {
            out.append(Part(id: "cooldown", section: "Cool-down", label: c.label ?? "Cool-down", goal: goalText(c), zone: c.zone, pace: paceText(c)))
        }
        return out
    }
}
