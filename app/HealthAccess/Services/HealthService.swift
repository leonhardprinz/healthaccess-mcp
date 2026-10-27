import Foundation
import HealthKit
import WorkoutKit

/// Thin async wrapper over HKHealthStore. Read-only; Health Access never writes health data.
final class HealthService: @unchecked Sendable {
    static let shared = HealthService()

    let store = HKHealthStore()
    private let lock = NSLock()
    private var observer: HKObserverQuery?

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let vo2MaxUnit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    /// The reproductive-health category types, left out of the request and the day files when the Settings toggle is off.
    static let reproductiveNames: Set<String> = [
        "BleedingAfterMenopause", "BleedingAfterPregnancy", "BleedingDuringPregnancy", "CervicalMucusQuality", "Contraceptive",
        "InfrequentMenstrualCycles", "IntermenstrualBleeding", "IrregularMenstrualCycles", "Lactation", "MenopausalState",
        "MenstrualFlow", "OvulationTestResult", "PersistentIntermenstrualBleeding", "Pregnancy", "PregnancyTestResult",
        "ProgesteroneTestResult", "ProlongedMenstrualPeriods", "SexualActivity",
    ]

    /// Everything the SDK knows (docs/export-coverage.md): every quantity, category and characteristic type this iOS
    /// has, plus workouts, routes, activity summaries, ECGs, heartbeat series, audiograms, prescriptions, state of mind,
    /// assessments and medication dose events. One request, one sheet. Correlations are read through their parts.
    func readTypes(includeReproductive: Bool) -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for spec in HealthTypes.all {
            if !includeReproductive && Self.reproductiveNames.contains(spec.name) { continue }
            switch spec.kind {
            case .quantity: if let t = Self.quantityType(spec) { types.insert(t) }
            case .category: if let t = Self.categoryType(spec) { types.insert(t) }
            case .characteristic: if let t = Self.characteristicType(spec) { types.insert(t) }
            case .correlation: break
            }
        }
        for special in Self.specialTypes { types.insert(special.type) }
        return types
    }

    func requestAuthorization(includeReproductive: Bool) async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes(includeReproductive: includeReproductive))
    }

    struct EffortScores: Sendable {
        var effort: Int?      // the athlete's own rating, entered on the Watch or in Fitness
        var estimated: Int?   // Apple's estimate
    }

    /// The Effort samples Apple relates to a workout (iOS 18+): the athlete's rating and Apple's estimate, 1 to 10.
    /// The athlete often rates minutes after the workout ends, so callers re-check on later runs.
    func effortScores(for workout: HKWorkout) async throws -> EffortScores {
        guard #available(iOS 18.0, *) else { return EffortScores() }
        let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        let unit = HKUnit.appleEffortScore()
        func newest(_ id: HKQuantityTypeIdentifier) async throws -> Int? {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
                sortDescriptors: [])
            let sample = try await descriptor.result(for: store).max { $0.startDate < $1.startDate }
            guard let value = sample?.quantity.doubleValue(for: unit) else { return nil }
            return min(10, max(1, Int(value.rounded())))
        }
        return EffortScores(effort: try await newest(.workoutEffortScore), estimated: try await newest(.estimatedWorkoutEffortScore))
    }

    /// Registers the long-running observer query once per process. HealthKit calls `handler` whenever workouts change,
    /// including background launches when background delivery is enabled.
    func startObserving(_ handler: @escaping @Sendable (Error?) async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard observer == nil else { return }
        let query = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { _, completion, error in
            Task {
                await handler(error)
                completion()
            }
        }
        observer = query
        store.execute(query)
    }

    func enableBackgroundDelivery() async throws {
        try await store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
    }

    struct WorkoutDelta {
        let added: [HKWorkout]
        let deleted: Int
        let anchor: HKQueryAnchor
    }

    /// Anchored query: everything after `anchor` (or everything since `since` when there is no anchor yet).
    func newWorkouts(anchor: HKQueryAnchor?, since: Date?) async throws -> WorkoutDelta {
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: [.strictStartDate]) }
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout(predicate)], anchor: anchor)
        let result = try await descriptor.result(for: store)
        return WorkoutDelta(added: result.addedSamples, deleted: result.deletedObjects.count, anchor: result.newAnchor)
    }

    func workouts(ids: Set<UUID>) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForObjects(with: ids)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    func heartRate(from: Date, to: Date) async throws -> [(Date, Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
            sortDescriptors: [])
        return try await descriptor.result(for: store)
            .sorted { $0.startDate < $1.startDate }
            .map { ($0.startDate, $0.quantity.doubleValue(for: Self.bpm)) }
    }

    /// Samples in the window, sorted in memory (windows are a day at most, so this is cheap and avoids SortDescriptor).
    func samples(_ id: HKQuantityTypeIdentifier, from: Date, to: Date, newestFirst: Bool = false, limit: Int? = nil) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
            sortDescriptors: [])
        let sorted = try await descriptor.result(for: store).sorted { newestFirst ? $0.startDate > $1.startDate : $0.startDate < $1.startDate }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func statistics(_ id: HKQuantityTypeIdentifier, from: Date, to: Date, options: HKStatisticsOptions) async throws -> HKStatistics? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate), options: options)
        return try await descriptor.result(for: store)
    }

    /// Seconds asleep (core + deep + REM + unspecified) for sleep samples ending inside the window.
    /// When several sources overlap (Watch and iPhone), the source with the most sleep wins instead of double counting.
    func sleepSeconds(from: Date, to: Date) async throws -> Int? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [.strictEndDate])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [])
        let samples = try await descriptor.result(for: store)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var bySource: [String: TimeInterval] = [:]
        for sample in samples where asleep.contains(sample.value) {
            bySource[sample.sourceRevision.source.bundleIdentifier, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
        }
        guard let best = bySource.values.max() else { return nil }
        return Int(best.rounded())
    }

    func bloodPressure(from: Date, to: Date) async throws -> BloodPressure? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.correlation(type: HKCorrelationType(.bloodPressure), predicate: predicate)],
            sortDescriptors: [])
        guard let correlation = try await descriptor.result(for: store).max(by: { $0.startDate < $1.startDate }) else { return nil }
        let mmHg = HKUnit.millimeterOfMercury()
        guard let sys = (correlation.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg),
              let dia = (correlation.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg)
        else { return nil }
        return BloodPressure(sys: Int(sys.rounded()), dia: Int(dia.rounded()), at: correlation.startDate)
    }

    /// The WorkoutKit plan a finished workout was started from, if any.
    func workoutPlanID(for workout: HKWorkout) async -> UUID? {
        (try? await workout.workoutPlan)?.id
    }

    static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}
