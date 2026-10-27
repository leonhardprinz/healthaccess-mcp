import Foundation
import HealthKit
import WorkoutKit

/// A `plans/<id>.json` file paired with its `plans/<id>.status.json`.
struct PlanItem: Identifiable, Sendable, Hashable {
    let id: String          // file base name, e.g. "2026-10-24T20:11:03Z-s26"
    let file: String        // "plans/<id>.json"
    let statusFile: String  // "plans/<id>.status.json"
    let doc: PlanDoc?
    let parseError: String?
    let status: PlanStatus?

    enum State: String { case pending, scheduled, failed, cancelled, invalid }

    var state: State {
        guard doc != nil else { return .invalid }
        guard let status else { return .pending }
        return State(rawValue: status.state) ?? .pending
    }

    var name: String { doc?.name ?? id }
}

/// plans/*.json → WorkoutKit. Validation, building, authorization, scheduling and status files.
enum PlanInstaller {
    /// Same list as `SPORTS` in core/src/model/plan.rs.
    static let supportedSports = ["run", "indoor_run", "walk", "hike", "cycle", "indoor_cycle",
                                  "pool_swim", "open_water_swim", "indoor_row", "hiit", "elliptical"]
    /// Sports the Watch measures no distance for: time goals only.
    static let timeOnlySports = ["hiit", "elliptical"]
    /// Current schema tag plus the pre-rename alias, accepted forever.
    static let acceptedSchemas = ["healthaccess.plan.v1", "tide.plan.v1"]

    static func scan(folder: FolderStore) throws -> [PlanItem] {
        let names = try folder.list("plans", suffix: ".json").filter { !$0.hasSuffix(".status.json") }
        let items = names.map { name -> PlanItem in
            let base = String(name.dropLast(".json".count))
            let file = "plans/\(name)"
            let statusFile = "plans/\(base).status.json"
            var doc: PlanDoc?
            var parseError: String?
            do {
                guard let data = try folder.read(file) else { throw HealthAccessError("file not readable") }
                let decoded = try HealthAccessJSON.decode(PlanDoc.self, from: data)
                try validate(decoded)
                doc = decoded
            } catch {
                parseError = error.localizedDescription
            }
            var status: PlanStatus?
            if let data = try? folder.read(statusFile), let decoded = try? HealthAccessJSON.decode(PlanStatus.self, from: data) {
                status = decoded
            }
            return PlanItem(id: base, file: file, statusFile: statusFile, doc: doc, parseError: parseError, status: status)
        }
        func sortKey(_ item: PlanItem) -> Date { item.doc?.scheduledFor ?? item.doc?.createdAt ?? .distantPast }
        return items.sorted { sortKey($0) > sortKey($1) }
    }

    static func validate(_ plan: PlanDoc) throws {
        guard acceptedSchemas.contains(plan.schema) else { throw HealthAccessError("unsupported schema \(plan.schema)") }
        guard !plan.id.isEmpty, !plan.name.isEmpty else { throw HealthAccessError("id and name are required") }
        guard plan.name.count <= 40 else { throw HealthAccessError("name is longer than 40 characters") }
        if let pool = plan.poolLengthM, !(pool.isFinite && pool > 0 && pool <= 100) { throw HealthAccessError("pool length must be 1 to 100 m") }
        guard supportedSports.contains(plan.sport) else { throw HealthAccessError("sport must be one of \(supportedSports.joined(separator: ", ")), got \(plan.sport)") }
        if timeOnlySports.contains(plan.sport) {
            let steps = [plan.warmup, plan.cooldown].compactMap { $0 } + plan.blocks.flatMap(\.steps)
            if steps.contains(where: { $0.goal.type != "time_s" }) { throw HealthAccessError("\(plan.sport) takes time goals only") }
        }
        guard !plan.blocks.isEmpty else { throw HealthAccessError("plan has no blocks") }
        for (i, block) in plan.blocks.enumerated() {
            guard (1...99).contains(block.repeatCount) else { throw HealthAccessError("block \(i + 1): repeat must be 1 to 99") }
            guard !block.steps.isEmpty else { throw HealthAccessError("block \(i + 1) has no steps") }
            for (j, step) in block.steps.enumerated() {
                try validate(step: step, context: "block \(i + 1) step \(j + 1)")
                if let kind = step.kind, !["work", "recovery"].contains(kind) {
                    throw HealthAccessError("block \(i + 1) step \(j + 1): kind must be work or recovery")
                }
            }
        }
        if let warmup = plan.warmup { try validate(step: warmup, context: "warmup") }
        if let cooldown = plan.cooldown { try validate(step: cooldown, context: "cooldown") }
    }

    private static func validate(step: PlanStep, context: String) throws {
        guard ["distance_m", "time_s"].contains(step.goal.type) else { throw HealthAccessError("\(context): goal type must be distance_m or time_s") }
        guard step.goal.value.isFinite, step.goal.value > 0 else { throw HealthAccessError("\(context): goal value must be > 0") }
        let limit = step.goal.type == "distance_m" ? 1_000_000.0 : 86_400.0
        guard step.goal.value <= limit else { throw HealthAccessError("\(context): goal value is too large") }
        if let zone = step.zone, !(1...5).contains(zone) { throw HealthAccessError("\(context): zone must be 1–5") }
    }

    static func activity(for sport: String) -> (type: HKWorkoutActivityType, location: HKWorkoutSessionLocationType) {
        switch sport {
        case "run": return (.running, .outdoor)
        case "indoor_run": return (.running, .indoor)
        case "walk": return (.walking, .outdoor)
        case "hike": return (.hiking, .outdoor)
        case "cycle": return (.cycling, .outdoor)
        case "indoor_cycle": return (.cycling, .indoor)
        case "open_water_swim": return (.swimming, .outdoor)
        case "indoor_row": return (.rowing, .indoor)
        case "hiit": return (.highIntensityIntervalTraining, .indoor)
        case "elliptical": return (.elliptical, .indoor)
        default: return (.swimming, .indoor)
        }
    }

    /// The activity code the exported workout will carry for a plan of this sport, for the ±2 h fallback match.
    static func exportActivity(for sport: String) -> String {
        switch sport {
        case "indoor_run": return "run"
        case "indoor_cycle": return "cycle"
        case "hike", "hiit", "elliptical": return "other:\(activity(for: sport).type.rawValue)"
        default: return sport
        }
    }

    struct Built: Sendable {
        let plan: WorkoutPlan
        let warnings: [String]
    }

    /// Verified against WorkoutKit.swiftinterface (iOS 27.1 SDK): CustomWorkout(activity:location:displayName:warmup:blocks:cooldown:),
    /// IntervalBlock(steps:iterations:), IntervalStep(_:step:), WorkoutStep(goal:alert:displayName:) (displayName iOS 18+),
    /// WorkoutGoal.distance/.time, HeartRateZoneAlert(zone:). Pool length is not expressible; the Watch uses its own setting.
    static func build(_ plan: PlanDoc) throws -> Built {
        let (type, location) = activity(for: plan.sport)
        guard CustomWorkout.supportsActivity(type) else { throw HealthAccessError("WorkoutKit does not support custom \(type.humanName) workouts") }
        var warnings: [String] = []
        let warmup = try plan.warmup.map { try workoutStep($0, type: type, location: location, context: "warmup", warnings: &warnings) }
        var blocks: [IntervalBlock] = []
        for (i, block) in plan.blocks.enumerated() {
            var steps: [IntervalStep] = []
            for (j, step) in block.steps.enumerated() {
                let ws = try workoutStep(step, type: type, location: location, context: "block \(i + 1) step \(j + 1)", warnings: &warnings)
                let kind = step.kind ?? (step.goal.type == "distance_m" ? "work" : "recovery")
                steps.append(IntervalStep(kind == "recovery" ? .recovery : .work, step: ws))
            }
            blocks.append(IntervalBlock(steps: steps, iterations: block.repeatCount))
        }
        let cooldown = try plan.cooldown.map { try workoutStep($0, type: type, location: location, context: "cooldown", warnings: &warnings) }
        let custom = CustomWorkout(activity: type, location: location, displayName: plan.name, warmup: warmup, blocks: blocks, cooldown: cooldown)
        return Built(plan: WorkoutPlan(.custom(custom), id: UUID()), warnings: warnings)
    }

    private static func workoutStep(_ step: PlanStep, type: HKWorkoutActivityType, location: HKWorkoutSessionLocationType,
                                    context: String, warnings: inout [String]) throws -> WorkoutStep {
        let goal: WorkoutGoal = step.goal.type == "distance_m" ? .distance(step.goal.value, .meters) : .time(step.goal.value, .seconds)
        guard CustomWorkout.supportsGoal(goal, activity: type, location: location) else {
            throw HealthAccessError("\(context): goal \(step.goal.type) = \(step.goal.value) is not supported for \(type.humanName)")
        }
        var alert: (any WorkoutAlert)?
        if let zone = step.zone {
            let zoneAlert = HeartRateZoneAlert(zone: zone)
            if CustomWorkout.supportsAlert(zoneAlert, activity: type, location: location) {
                alert = zoneAlert
            } else {
                warnings.append("\(context): heart-rate zone alert not supported for \(type.humanName), dropped")
            }
        }
        var label = step.label
        if let text = label, text.count > 40 {
            label = String(text.prefix(40))
            warnings.append("\(context): label truncated to 40 characters")
        }
        if #available(iOS 18.0, *) {
            return WorkoutStep(goal: goal, alert: alert, displayName: label)
        }
        if label != nil { warnings.append("\(context): step labels need iOS 18, dropped") }
        return WorkoutStep(goal: goal, alert: alert)
    }

    // MARK: scheduler

    static var isSupported: Bool { WorkoutScheduler.isSupported }

    struct Authorization: Sendable {
        let authorized: Bool
        let description: String
    }

    /// Current state, asking the user once when it is not determined. Returns plain values (the enum is not Sendable).
    static func authorize() async -> Authorization {
        var state = await WorkoutScheduler.shared.authorizationState
        if state != .authorized { state = await WorkoutScheduler.shared.requestAuthorization() }
        return Authorization(authorized: state == .authorized, description: describe(state))
    }

    static func currentAuthorizationDescription() async -> String {
        describe(await WorkoutScheduler.shared.authorizationState)
    }

    static func describe(_ state: WorkoutScheduler.AuthorizationState) -> String {
        switch state {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    static func isScheduled(_ id: UUID) async -> Bool {
        await WorkoutScheduler.shared.scheduledWorkouts.contains { $0.plan.id == id }
    }

    /// Schedules on the Watch. Returns an error message, or nil on success (verified against the scheduler's list).
    static func schedule(_ plan: WorkoutPlan, at date: Date) async -> String? {
        guard isSupported else { return "WorkoutKit scheduling is not supported on this iPhone (is a Watch paired?)" }
        let auth = await authorize()
        guard auth.authorized else { return "WorkoutKit authorization is \(auth.description)" }
        let existing = await WorkoutScheduler.shared.scheduledWorkouts
        if existing.contains(where: { $0.plan.id == plan.id }) { return nil }
        if existing.count >= WorkoutScheduler.maxAllowedScheduledWorkoutCount {
            return "the Watch already has \(existing.count) scheduled workouts (limit \(WorkoutScheduler.maxAllowedScheduledWorkoutCount)); remove one in the Workout app"
        }
        let components = Calendar.autoupdatingCurrent.dateComponents(in: .autoupdatingCurrent, from: date)
        await WorkoutScheduler.shared.schedule(plan, at: components)
        return await isScheduled(plan.id) ? nil : "schedule() returned but the plan is not in the scheduler's list"
    }

    /// Undo of "Put on Watch": takes the plan off the Watch's schedule again.
    /// Removes the scheduled workout whose plan id is `id`. Returns false when the scheduler has no such workout.
    static func removeScheduled(id: String) async -> Bool {
        guard isSupported else { return false }
        let scheduled = await WorkoutScheduler.shared.scheduledWorkouts
        guard let match = scheduled.first(where: { $0.plan.id.uuidString == id }) else { return false }
        await WorkoutScheduler.shared.remove(match.plan, at: match.date)
        return !(await isScheduled(match.plan.id))
    }

    static func remove(_ plan: WorkoutPlan, at date: Date) async {
        let components = Calendar.autoupdatingCurrent.dateComponents(in: .autoupdatingCurrent, from: date)
        await WorkoutScheduler.shared.remove(plan, at: components)
    }

    static func writeStatus(_ status: PlanStatus, for item: PlanItem, folder: FolderStore) throws {
        try folder.write(try HealthAccessJSON.encode(status), to: item.statusFile)
    }

    /// Plans that reached the Watch, for `plan_ref` matching and label joins.
    static func installed(from items: [PlanItem]) -> PlanLookup {
        PlanLookup(plans: items.compactMap { item in
            guard let doc = item.doc, let status = item.status, status.state == "scheduled" else { return nil }
            return InstalledPlan(planId: doc.id, name: doc.name, sport: doc.sport,
                                 workoutkitId: status.workoutkitId.flatMap(UUID.init(uuidString:)),
                                 scheduledFor: status.scheduledFor ?? doc.scheduledFor, doc: doc)
        })
    }
}
