import Foundation

/// What the app says about a plan before it reaches the Watch: "900 m · 5 parts · about 35 min" and the parts as text.
extension PlanDoc {
    /// One executed part per entry: the warm-up, every repeat of every block step, the cool-down.
    struct Part: Identifiable, Hashable {
        let id: String
        let section: String   // "Warm-up", "Block 2 × 3", "Cool-down"
        let label: String     // the wrist label, or the kind when the AI gave none
        let goal: String      // "200 m" | "0:45"
        let zone: Int?

        /// "FR easy, long strokes · 200 m · zone 1"
        var line: String {
            var text = "\(label) · \(goal)"
            if let zone { text += " · zone \(zone)" }
            return text
        }
    }

    /// Planned metres over all distance goals (time goals excluded), repeats included.
    var plannedDistance: Double? {
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

    /// Time estimate: distance goals at the sport's pace, time goals as they are, rests included.
    var estimatedSeconds: Int {
        func seconds(_ s: PlanStep?) -> Double {
            guard let s else { return 0 }
            return s.goal.type == "distance_m" ? s.goal.value * secondsPerMetre : s.goal.value
        }
        var total = seconds(warmup) + seconds(cooldown)
        for b in blocks { total += b.steps.map(seconds).reduce(0, +) * Double(b.repeatCount) }
        return safeInt(total) ?? 0
    }

    /// "900 m · 5 parts · about 35 min"
    var summaryLine: String {
        var parts: [String] = []
        if let d = plannedDistance { parts.append(Format.distance(d)) }
        parts.append("\(totalSteps) part\(totalSteps == 1 ? "" : "s")")
        parts.append(Format.aboutMinutes(estimatedSeconds))
        return parts.joined(separator: " · ")
    }

    /// "pool swim", "indoor row": the trailing word on the card.
    var sportWords: String { ActivityMapping.title(sport).lowercased() }

    var parts: [Part] {
        func goalText(_ s: PlanStep) -> String {
            s.goal.type == "distance_m" ? Format.distance(s.goal.value) : Format.duration(safeInt(s.goal.value) ?? 0)
        }
        func kindWord(_ s: PlanStep, fallback: String) -> String {
            let kind = s.kind ?? (s.goal.type == "distance_m" ? "work" : "recovery")
            switch kind {
            case "recovery": return "Rest"
            case "work": return fallback
            default: return kind.capitalized
            }
        }
        var out: [Part] = []
        if let w = warmup {
            out.append(Part(id: "warmup", section: "Warm-up", label: w.label ?? "Warm-up", goal: goalText(w), zone: w.zone))
        }
        for (i, block) in blocks.enumerated() {
            let section = block.repeatCount > 1 ? "Block \(i + 1) × \(block.repeatCount)" : "Block \(i + 1)"
            for (j, step) in block.steps.enumerated() {
                out.append(Part(id: "\(i).\(j)", section: section, label: step.label ?? kindWord(step, fallback: "Swim"),
                                goal: goalText(step), zone: step.zone))
            }
        }
        if let c = cooldown {
            out.append(Part(id: "cooldown", section: "Cool-down", label: c.label ?? "Cool-down", goal: goalText(c), zone: c.zone))
        }
        return out
    }
}
