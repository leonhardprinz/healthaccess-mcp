import CoreLocation
import Foundation
import HealthKit

/// Generic HealthKit reads over the generated type list, plus the special types (activity summaries, ECGs, routes,
/// state of mind, assessments, audiograms, prescriptions, medication dose events, characteristics).
/// Read-only; every query is bounded by a date window.
extension HealthService {
    // MARK: types

    static func quantityType(_ spec: HealthTypeSpec) -> HKQuantityType? {
        guard spec.kind == .quantity else { return nil }
        return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: spec.identifier))
    }

    static func categoryType(_ spec: HealthTypeSpec) -> HKCategoryType? {
        guard spec.kind == .category else { return nil }
        return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: spec.identifier))
    }

    static func characteristicType(_ spec: HealthTypeSpec) -> HKCharacteristicType? {
        guard spec.kind == .characteristic else { return nil }
        return HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: spec.identifier))
    }

    static func correlationType(_ spec: HealthTypeSpec) -> HKCorrelationType? {
        guard spec.kind == .correlation else { return nil }
        return HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: spec.identifier))
    }

    /// The sample type for a quantity or category spec, if this iOS knows it.
    static func sampleType(_ spec: HealthTypeSpec) -> HKSampleType? {
        switch spec.kind {
        case .quantity: return quantityType(spec)
        case .category: return categoryType(spec)
        case .correlation: return correlationType(spec)
        case .characteristic: return nil
        }
    }

    /// The special (non-identifier) types this build reads, by the name used in catalog.json.
    static var specialTypes: [(name: String, type: HKObjectType)] {
        var list: [(String, HKObjectType)] = [
            ("HKWorkoutType", .workoutType()),
            ("HKWorkoutRoute", HKSeriesType.workoutRoute()),
            ("HKActivitySummary", .activitySummaryType()),
            ("HKElectrocardiogram", .electrocardiogramType()),
            ("HKHeartbeatSeries", HKSeriesType.heartbeat()),
            ("HKAudiogram", .audiogramSampleType()),
            // HKVisionPrescription and HKMedicationDoseEvent are share-only: HealthKit throws
            // NSInvalidArgumentException if an app asks to READ them. Never request them.
        ]
        if #available(iOS 18.0, *) {
            list.append(("HKStateOfMind", .stateOfMindType()))
            list.append(("HKScoredAssessmentGAD7", HKScoredAssessmentType(.GAD7)))
            list.append(("HKScoredAssessmentPHQ9", HKScoredAssessmentType(.PHQ9)))
        }
        return list
    }

    // MARK: samples

    static func window(_ from: Date, _ to: Date) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    }

    func quantitySamples(_ type: HKQuantityType, from: Date, to: Date, limit: Int? = nil, newestFirst: Bool = false) async throws -> [HKQuantitySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: Self.window(from, to))],
            sortDescriptors: [],
            limit: limit)
        let sorted = try await descriptor.result(for: store).sorted { newestFirst ? $0.startDate > $1.startDate : $0.startDate < $1.startDate }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func categorySamples(_ type: HKCategoryType, from: Date, to: Date, options: HKQueryOptions = []) async throws -> [HKCategorySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: options))],
            sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    func correlations(_ type: HKCorrelationType, from: Date, to: Date) async throws -> [HKCorrelation] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.correlation(type: type, predicate: Self.window(from, to))],
            sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    func statistics(_ type: HKQuantityType, from: Date, to: Date, options: HKStatisticsOptions) async throws -> HKStatistics? {
        let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: Self.window(from, to)), options: options)
        return try await descriptor.result(for: store)
    }

    struct Count: Sendable {
        var count: Int
        var capped: Bool
        var first: Date?
        var last: Date?
    }

    /// How many samples of a type exist in the window (capped), with the first and last dates. Used by the catalog.
    func count(_ type: HKSampleType, from: Date, to: Date, cap: Int) async throws -> Count {
        let predicate = Self.window(from, to)
        let samples = try await sorted(type, predicate: predicate, limit: cap, ascending: true)
        guard let first = samples.first else { return Count(count: 0, capped: false, first: nil, last: nil) }
        var last = samples.last?.startDate
        let capped = samples.count >= cap
        if capped {
            last = try await sorted(type, predicate: predicate, limit: 1, ascending: false).first?.startDate
        }
        return Count(count: samples.count, capped: capped, first: first.startDate, last: last)
    }

    /// The classic query, because it sorts by start date without a key-path sort descriptor.
    private func sorted(_ type: HKSampleType, predicate: NSPredicate, limit: Int, ascending: Bool) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    // MARK: special types

    func activitySummary(for day: Date, calendar: Calendar) async throws -> HKActivitySummary? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.calendar = calendar
        let descriptor = HKActivitySummaryQueryDescriptor(predicate: HKQuery.predicateForActivitySummary(with: components))
        return try await descriptor.result(for: store).first
    }

    func electrocardiograms(from: Date, to: Date) async throws -> [HKElectrocardiogram] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.electrocardiogram(Self.window(from, to))], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    /// Voltage of the Watch's lead-I-like reading, in microvolts, with the offset from the sample start.
    func voltages(of ecg: HKElectrocardiogram) async throws -> [(TimeInterval, Double)] {
        let descriptor = HKElectrocardiogramQueryDescriptor(ecg)
        var out: [(TimeInterval, Double)] = []
        for try await measurement in descriptor.results(for: store) {
            if let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                out.append((measurement.timeSinceSampleStart, quantity.doubleValue(for: .voltUnit(with: .micro))))
            }
        }
        return out
    }

    func routes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [])
        return try await descriptor.result(for: store)
    }

    func locations(of route: HKWorkoutRoute) async throws -> [CLLocation] {
        let descriptor = HKWorkoutRouteQueryDescriptor(route)
        var out: [CLLocation] = []
        for try await location in descriptor.results(for: store) {
            out.append(location)
        }
        return out
    }

    @available(iOS 18.0, *)
    func statesOfMind(from: Date, to: Date) async throws -> [HKStateOfMind] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.stateOfMind(Self.window(from, to))], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    @available(iOS 18.0, *)
    func gad7(from: Date, to: Date) async throws -> [HKGAD7Assessment] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.gad7Assessment(Self.window(from, to))], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    @available(iOS 18.0, *)
    func phq9(from: Date, to: Date) async throws -> [HKPHQ9Assessment] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.phq9Assessment(Self.window(from, to))], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    func audiograms(from: Date, to: Date) async throws -> [HKAudiogramSample] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.audiogram(Self.window(from, to))], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    func visionPrescriptions(from: Date, to: Date) async throws -> [HKVisionPrescription] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.visionPrescription(Self.window(from, to))], sortDescriptors: [])
        return try await descriptor.result(for: store).sorted { $0.startDate < $1.startDate }
    }

    @available(iOS 26.0, *)
    func medicationDoseEvents(from: Date, to: Date) async throws -> [HKMedicationDoseEvent] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: .medicationDoseEventType(), predicate: Self.window(from, to))],
            sortDescriptors: [])
        return try await descriptor.result(for: store).compactMap { $0 as? HKMedicationDoseEvent }.sorted { $0.startDate < $1.startDate }
    }

    func mindfulSessions(from: Date, to: Date) async throws -> [HKCategorySample] {
        try await categorySamples(HKCategoryType(.mindfulSession), from: from, to: to)
    }

    // MARK: characteristics

    struct Characteristics: Sendable, Equatable {
        var birthYear: Int?
        var age: Int?
        var biologicalSex: String?
        var bloodType: String?
        var wheelchairUse: String?
        var activityMoveMode: String?
        var fitzpatrickSkinType: String?
    }

    /// Everything the Health profile says about the person, as words. Each one is nil when not set or not allowed.
    func characteristics(now: Date = Date()) -> Characteristics {
        var c = Characteristics()
        if let components = try? store.dateOfBirthComponents(), let year = components.year {
            c.birthYear = year
            if let birth = Calendar.current.date(from: components) {
                c.age = Calendar.current.dateComponents([.year], from: birth, to: now).year
            }
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: c.biologicalSex = "female"
            case .male: c.biologicalSex = "male"
            case .other: c.biologicalSex = "other"
            case .notSet: c.biologicalSex = nil
            @unknown default: c.biologicalSex = nil
            }
        }
        if let blood = try? store.bloodType().bloodType {
            switch blood {
            case .aPositive: c.bloodType = "A+"
            case .aNegative: c.bloodType = "A-"
            case .bPositive: c.bloodType = "B+"
            case .bNegative: c.bloodType = "B-"
            case .abPositive: c.bloodType = "AB+"
            case .abNegative: c.bloodType = "AB-"
            case .oPositive: c.bloodType = "O+"
            case .oNegative: c.bloodType = "O-"
            case .notSet: c.bloodType = nil
            @unknown default: c.bloodType = nil
            }
        }
        if let wheelchair = try? store.wheelchairUse().wheelchairUse {
            switch wheelchair {
            case .yes: c.wheelchairUse = "yes"
            case .no: c.wheelchairUse = "no"
            case .notSet: c.wheelchairUse = nil
            @unknown default: c.wheelchairUse = nil
            }
        }
        if let mode = try? store.activityMoveMode().activityMoveMode {
            switch mode {
            case .activeEnergy: c.activityMoveMode = "active_energy"
            case .appleMoveTime: c.activityMoveMode = "apple_move_time"
            @unknown default: c.activityMoveMode = nil
            }
        }
        if let skin = try? store.fitzpatrickSkinType().skinType {
            switch skin {
            case .I: c.fitzpatrickSkinType = "I"
            case .II: c.fitzpatrickSkinType = "II"
            case .III: c.fitzpatrickSkinType = "III"
            case .IV: c.fitzpatrickSkinType = "IV"
            case .V: c.fitzpatrickSkinType = "V"
            case .VI: c.fitzpatrickSkinType = "VI"
            case .notSet: c.fitzpatrickSkinType = nil
            @unknown default: c.fitzpatrickSkinType = nil
            }
        }
        return c
    }
}

/// Words for HealthKit's category values, by the value enum the header names for each type.
enum CategoryValues {
    static func word(_ value: Int, valueType: String) -> String {
        switch valueType {
        case "HKCategoryValueSleepAnalysis":
            switch value {
            case 0: return "in_bed"
            case 1: return "asleep"
            case 2: return "awake"
            case 3: return "asleep_core"
            case 4: return "asleep_deep"
            case 5: return "asleep_rem"
            default: return "value_\(value)"
            }
        case "HKCategoryValueSeverity":
            switch value {
            case 0: return "unspecified"
            case 1: return "not_present"
            case 2: return "mild"
            case 3: return "moderate"
            case 4: return "severe"
            default: return "value_\(value)"
            }
        case "HKCategoryValuePresence":
            return value == 0 ? "present" : "not_present"
        case "HKCategoryValueAppetiteChanges":
            switch value {
            case 0: return "unspecified"
            case 1: return "no_change"
            case 2: return "decreased"
            case 3: return "increased"
            default: return "value_\(value)"
            }
        case "HKCategoryValueVaginalBleeding":
            switch value {
            case 1: return "unspecified"
            case 2: return "light"
            case 3: return "medium"
            case 4: return "heavy"
            case 5: return "none"
            default: return "value_\(value)"
            }
        case "HKCategoryValueOvulationTestResult":
            switch value {
            case 1: return "negative"
            case 2: return "luteinizing_hormone_surge"
            case 3: return "indeterminate"
            case 4: return "estrogen_surge"
            default: return "value_\(value)"
            }
        case "HKCategoryValuePregnancyTestResult", "HKCategoryValueProgesteroneTestResult":
            switch value {
            case 1: return "negative"
            case 2: return "positive"
            case 3: return "indeterminate"
            default: return "value_\(value)"
            }
        case "HKCategoryValueCervicalMucusQuality":
            switch value {
            case 1: return "dry"
            case 2: return "sticky"
            case 3: return "creamy"
            case 4: return "watery"
            case 5: return "egg_white"
            default: return "value_\(value)"
            }
        case "HKCategoryValueContraceptive":
            switch value {
            case 1: return "unspecified"
            case 2: return "implant"
            case 3: return "injection"
            case 4: return "intrauterine_device"
            case 5: return "intravaginal_ring"
            case 6: return "oral"
            case 7: return "patch"
            default: return "value_\(value)"
            }
        case "HKCategoryValueMenopausalState":
            switch value {
            case 1: return "premenopausal"
            case 2: return "perimenopausal"
            case 3: return "postmenopausal"
            default: return "value_\(value)"
            }
        case "HKCategoryValueAppleStandHour":
            return value == 0 ? "stood" : "idle"
        case "HKCategoryValueLowCardioFitnessEvent":
            return "low_fitness"
        case "HKCategoryValueEnvironmentalAudioExposureEvent", "HKCategoryValueHeadphoneAudioExposureEvent":
            return "seven_day_limit"
        case "HKCategoryValueAppleWalkingSteadinessEvent":
            switch value {
            case 1: return "initial_low"
            case 2: return "initial_very_low"
            case 3: return "repeat_low"
            case 4: return "repeat_very_low"
            default: return "value_\(value)"
            }
        case "HKCategoryValue":
            return "logged"
        default:
            return "value_\(value)"
        }
    }
}
