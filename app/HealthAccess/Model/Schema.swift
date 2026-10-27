import Foundation

// Codable mirror of docs/schema.md (healthaccess.workout.v1, healthaccess.vitals.v1, healthaccess.index.v1, healthaccess.plan.v1, plan status).
// Nullable contract fields are written as explicit `null` (manual `encode(to:)`), never omitted.
// Files written before the rename carry `tide.*` schema tags and the key `tide_version`; both stay readable (aliases).

// MARK: - workouts/<…>.json

struct WorkoutDoc: Codable, Sendable {
    var schema: String = "healthaccess.workout.v1"
    var healthaccessVersion: String
    var id: String
    var activity: String
    var source: String
    var start: Date
    var end: Date
    var durationS: Int
    var distanceM: Double?
    var activeKcal: Double?
    var avgHr: Int?
    var maxHr: Int?
    var poolLengthM: Double?
    /// Written by builds before 0.4; read for old files, never written again (the MCP computes zones from `hr_series`).
    var zones: ZonesDoc?
    var planRef: PlanRef?
    var steps: [StepDoc]
    var laps: [LapDoc]
    var hrSeries: [HRSample]
    var recoveryHr: RecoveryHR?
    var effort: Int?
    /// Where `effort` came from: "apple" (the rating entered on the Watch or in Fitness), "app" (rated here), "ai" (rate_workout).
    var effortSource: String?
    /// Apple's own estimate of the effort, 1 to 10. Never used as `effort`.
    var effortEstimated: Int?
    var feel: String?
    var metadata: [String: String]
    // v0.4 additions (docs/export-coverage.md): everything HealthKit holds about the workout, exhaustively.
    var statistics: [String: StatEntry] = [:]
    var totals: WorkoutTotals?
    var events: [EventDoc] = []
    var series: [String: SeriesDoc] = [:]
    var routeFile: String?
    var routeSummary: RouteSummary?
    var device: DeviceDoc?
    var metadataTyped: MetadataTyped?
    var workoutPlanId: String?

    enum CodingKeys: String, CodingKey {
        case schema, id, activity, source, start, end, zones, steps, laps, effort, feel, metadata
        case statistics, totals, events, series, device
        case healthaccessVersion = "healthaccess_version"
        case legacyVersion = "tide_version" // alias: written before the rename, read-only
        case durationS = "duration_s"
        case distanceM = "distance_m"
        case activeKcal = "active_kcal"
        case avgHr = "avg_hr"
        case maxHr = "max_hr"
        case poolLengthM = "pool_length_m"
        case planRef = "plan_ref"
        case hrSeries = "hr_series"
        case recoveryHr = "recovery_hr"
        case effortSource = "effort_source"
        case effortEstimated = "effort_estimated"
        case routeFile = "route_file"
        case routeSummary = "route_summary"
        case metadataTyped = "metadata_typed"
        case workoutPlanId = "workout_plan_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(healthaccessVersion, forKey: .healthaccessVersion)
        try c.encode(id, forKey: .id)
        try c.encode(activity, forKey: .activity)
        try c.encode(source, forKey: .source)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(activeKcal, forKey: .activeKcal)
        try c.encode(avgHr, forKey: .avgHr)
        try c.encode(maxHr, forKey: .maxHr)
        try c.encode(poolLengthM, forKey: .poolLengthM)
        try c.encodeIfPresent(zones, forKey: .zones)
        try c.encode(planRef, forKey: .planRef)
        try c.encode(steps, forKey: .steps)
        try c.encode(laps, forKey: .laps)
        try c.encode(hrSeries, forKey: .hrSeries)
        try c.encode(recoveryHr, forKey: .recoveryHr)
        try c.encode(effort, forKey: .effort)
        try c.encode(effortSource, forKey: .effortSource)
        try c.encode(effortEstimated, forKey: .effortEstimated)
        try c.encode(feel, forKey: .feel)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(statistics, forKey: .statistics)
        try c.encode(totals, forKey: .totals)
        try c.encode(events, forKey: .events)
        try c.encode(series, forKey: .series)
        try c.encode(routeFile, forKey: .routeFile)
        try c.encode(routeSummary, forKey: .routeSummary)
        try c.encode(device, forKey: .device)
        try c.encode(metadataTyped, forKey: .metadataTyped)
        try c.encode(workoutPlanId, forKey: .workoutPlanId)
    }
}

/// One entry of `statistics`: `HKWorkout.allStatistics` for a quantity type, in the unit named.
struct StatEntry: Codable, Sendable, Hashable {
    var unit: String
    var avg: Double?
    var min: Double?
    var max: Double?
    var sum: Double?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unit, forKey: .unit)
        try c.encode(avg, forKey: .avg)
        try c.encode(min, forKey: .min)
        try c.encode(max, forKey: .max)
        try c.encode(sum, forKey: .sum)
    }
}

struct WorkoutTotals: Codable, Sendable, Hashable {
    var swimmingStrokeCount: Int?
    var flightsClimbed: Int?
    var energyBasalKcal: Double?

    enum CodingKeys: String, CodingKey {
        case swimmingStrokeCount = "swimming_stroke_count"
        case flightsClimbed = "flights_climbed"
        case energyBasalKcal = "energy_basal_kcal"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(swimmingStrokeCount, forKey: .swimmingStrokeCount)
        try c.encode(flightsClimbed, forKey: .flightsClimbed)
        try c.encode(energyBasalKcal, forKey: .energyBasalKcal)
    }
}

/// Every `HKWorkoutEvent`, not only laps.
struct EventDoc: Codable, Sendable, Hashable {
    var type: String   // lap | segment | marker | pause | resume | motion_paused | motion_resumed | pause_or_resume_request
    var start: Date
    var end: Date
    var durationS: Int
    var metadata: [String: String]

    enum CodingKeys: String, CodingKey { case type, start, end, metadata, durationS = "duration_s" }
}

/// A per-sample series inside the workout window: `[[timestamp, value], …]`, ≥ 4 s apart.
struct SeriesDoc: Codable, Sendable, Hashable {
    var unit: String
    var samples: [SeriesSample]
}

struct SeriesSample: Codable, Sendable, Hashable {
    var at: Date
    var value: Double

    init(at: Date, value: Double) { self.at = at; self.value = value }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let s = try c.decode(String.self)
        guard let d = HealthAccessJSON.date(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad series timestamp \(s)")
        }
        at = d
        value = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(HealthAccessJSON.string(at))
        try c.encode(value)
    }
}

/// Summary of the route sidecar `workouts/<name>.route.json`, a bare array of `[t, lat, lon, alt_m, h_acc_m, speed_mps, course_deg]`.
struct RouteSummary: Codable, Sendable, Hashable {
    var points: Int
    var distanceM: Double?
    var ascentM: Double?
    var descentM: Double?
    var columns: [String] = RouteSummary.columnNames

    static let columnNames = ["t_unix_s", "lat", "lon", "alt_m", "h_acc_m", "speed_mps", "course_deg"]

    enum CodingKeys: String, CodingKey {
        case points, columns
        case distanceM = "distance_m"
        case ascentM = "ascent_m"
        case descentM = "descent_m"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(ascentM, forKey: .ascentM)
        try c.encode(descentM, forKey: .descentM)
        try c.encode(columns, forKey: .columns)
    }
}

struct DeviceDoc: Codable, Sendable, Hashable {
    var name: String?
    var model: String?
    var manufacturer: String?
    var hardwareVersion: String?
    var softwareVersion: String?
    var sourceName: String
    var sourceBundleId: String
    var sourceVersion: String?
    var operatingSystem: String?

    enum CodingKeys: String, CodingKey {
        case name, model, manufacturer
        case hardwareVersion = "hardware_version"
        case softwareVersion = "software_version"
        case sourceName = "source_name"
        case sourceBundleId = "source_bundle_id"
        case sourceVersion = "source_version"
        case operatingSystem = "operating_system"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(model, forKey: .model)
        try c.encode(manufacturer, forKey: .manufacturer)
        try c.encode(hardwareVersion, forKey: .hardwareVersion)
        try c.encode(softwareVersion, forKey: .softwareVersion)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(sourceBundleId, forKey: .sourceBundleId)
        try c.encode(sourceVersion, forKey: .sourceVersion)
        try c.encode(operatingSystem, forKey: .operatingSystem)
    }
}

/// Typed copies of the useful metadata keys (the raw strings stay in `metadata`).
struct MetadataTyped: Codable, Sendable, Hashable {
    var indoor: Bool?
    var poolLengthM: Double?
    var swimmingLocation: String?
    var weather: WeatherDoc?
    var elevationAscendedM: Double?
    var elevationDescendedM: Double?
    var averageMets: Double?
    var averageSpeedMps: Double?
    var maximumSpeedMps: Double?
    var coached: Bool?
    var fitnessPlus: Bool?
    var brand: String?
    var timeZone: String?

    enum CodingKeys: String, CodingKey {
        case indoor, weather, coached, brand
        case poolLengthM = "pool_length_m"
        case swimmingLocation = "swimming_location"
        case elevationAscendedM = "elevation_ascended_m"
        case elevationDescendedM = "elevation_descended_m"
        case averageMets = "average_mets"
        case averageSpeedMps = "average_speed_mps"
        case maximumSpeedMps = "maximum_speed_mps"
        case fitnessPlus = "fitness_plus"
        case timeZone = "time_zone"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(indoor, forKey: .indoor)
        try c.encode(poolLengthM, forKey: .poolLengthM)
        try c.encode(swimmingLocation, forKey: .swimmingLocation)
        try c.encode(weather, forKey: .weather)
        try c.encode(elevationAscendedM, forKey: .elevationAscendedM)
        try c.encode(elevationDescendedM, forKey: .elevationDescendedM)
        try c.encode(averageMets, forKey: .averageMets)
        try c.encode(averageSpeedMps, forKey: .averageSpeedMps)
        try c.encode(maximumSpeedMps, forKey: .maximumSpeedMps)
        try c.encode(coached, forKey: .coached)
        try c.encode(fitnessPlus, forKey: .fitnessPlus)
        try c.encode(brand, forKey: .brand)
        try c.encode(timeZone, forKey: .timeZone)
    }
}

struct WeatherDoc: Codable, Sendable, Hashable {
    var tempC: Double?
    var humidityPct: Double?
    var condition: String?

    enum CodingKeys: String, CodingKey { case condition, tempC = "temp_c", humidityPct = "humidity_pct" }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tempC, forKey: .tempC)
        try c.encode(humidityPct, forKey: .humidityPct)
        try c.encode(condition, forKey: .condition)
    }
}

extension WorkoutDoc {
    /// Manual decoder so the memberwise initializer survives and the pre-rename `tide_version` key is read as an alias.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? "healthaccess.workout.v1"
        healthaccessVersion = try c.decodeIfPresent(String.self, forKey: .healthaccessVersion)
            ?? c.decodeIfPresent(String.self, forKey: .legacyVersion) ?? ""
        id = try c.decode(String.self, forKey: .id)
        activity = try c.decode(String.self, forKey: .activity)
        source = try c.decode(String.self, forKey: .source)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        durationS = min(max(try c.decode(Int.self, forKey: .durationS), 0), 31_536_000)
        distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
        activeKcal = try c.decodeIfPresent(Double.self, forKey: .activeKcal)
        avgHr = try c.decodeIfPresent(Int.self, forKey: .avgHr)
        maxHr = try c.decodeIfPresent(Int.self, forKey: .maxHr)
        poolLengthM = try c.decodeIfPresent(Double.self, forKey: .poolLengthM)
        zones = try c.decodeIfPresent(ZonesDoc.self, forKey: .zones)
        planRef = try c.decodeIfPresent(PlanRef.self, forKey: .planRef)
        steps = try c.decode([StepDoc].self, forKey: .steps)
        laps = try c.decode([LapDoc].self, forKey: .laps)
        hrSeries = try c.decodeIfPresent([HRSample].self, forKey: .hrSeries) ?? []
        recoveryHr = try c.decodeIfPresent(RecoveryHR.self, forKey: .recoveryHr)
        effort = try Self.decodeScore(c, .effort)
        effortSource = try c.decodeIfPresent(String.self, forKey: .effortSource)
        effortEstimated = try Self.decodeScore(c, .effortEstimated)
        feel = try c.decodeIfPresent(String.self, forKey: .feel)
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        statistics = try c.decodeIfPresent([String: StatEntry].self, forKey: .statistics) ?? [:]
        totals = try c.decodeIfPresent(WorkoutTotals.self, forKey: .totals)
        events = try c.decodeIfPresent([EventDoc].self, forKey: .events) ?? []
        series = try c.decodeIfPresent([String: SeriesDoc].self, forKey: .series) ?? [:]
        routeFile = try c.decodeIfPresent(String.self, forKey: .routeFile)
        routeSummary = try c.decodeIfPresent(RouteSummary.self, forKey: .routeSummary)
        device = try c.decodeIfPresent(DeviceDoc.self, forKey: .device)
        metadataTyped = try c.decodeIfPresent(MetadataTyped.self, forKey: .metadataTyped)
        workoutPlanId = try c.decodeIfPresent(String.self, forKey: .workoutPlanId)
    }

    /// A 1 to 10 score written as an integer by the app or as a float by other writers.
    private static func decodeScore(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return (1...10).contains(value) ? value : nil }
        return try c.decodeIfPresent(Double.self, forKey: key).flatMap(score1to10)
    }
}

struct ZonesDoc: Codable, Sendable {
    var bounds: [Int]
    var seconds: [String: Int]
}

struct PlanRef: Codable, Sendable, Hashable {
    var planId: String
    var name: String
    enum CodingKeys: String, CodingKey { case planId = "plan_id", name }
}

struct StepDoc: Codable, Sendable, Identifiable, Hashable {
    var key: String
    var block: Int
    var rep: Int
    var step: Int
    var label: String?
    var kind: String
    var start: Date
    var end: Date
    var durationS: Int
    var distanceM: Double?
    var avgHr: Int?
    var goalMet: Bool?
    var paceSPer100m: Double?

    var id: String { key + "@" + HealthAccessJSON.string(start) }

    enum CodingKeys: String, CodingKey {
        case key, block, rep, step, label, kind, start, end
        case durationS = "duration_s"
        case distanceM = "distance_m"
        case avgHr = "avg_hr"
        case goalMet = "goal_met"
        case paceSPer100m = "pace_s_per_100m"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(block, forKey: .block)
        try c.encode(rep, forKey: .rep)
        try c.encode(step, forKey: .step)
        try c.encode(label, forKey: .label)
        try c.encode(kind, forKey: .kind)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(avgHr, forKey: .avgHr)
        try c.encode(goalMet, forKey: .goalMet)
        try c.encode(paceSPer100m, forKey: .paceSPer100m)
    }
}

struct LapDoc: Codable, Sendable, Hashable {
    var start: Date
    var end: Date
    var durationS: Int
    var stroke: String?
    var swolf: Double?

    enum CodingKeys: String, CodingKey { case start, end, stroke, swolf, durationS = "duration_s" }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(stroke, forKey: .stroke)
        try c.encode(swolf, forKey: .swolf)
    }
}

/// `["2026-05-14T05:12:10Z", 84]`
struct HRSample: Codable, Sendable, Hashable {
    var at: Date
    var bpm: Int

    init(at: Date, bpm: Int) { self.at = at; self.bpm = bpm }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let s = try c.decode(String.self)
        guard let d = HealthAccessJSON.date(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad hr_series timestamp \(s)")
        }
        at = d
        bpm = try c.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(HealthAccessJSON.string(at))
        try c.encode(bpm)
    }
}

/// `end` / `1min` / `2min` are the app's own reading of the heart-rate series (kept flat for v1 readers and repeated
/// under `computed`); `apple_1min` is Apple's `HeartRateRecoveryOneMinute` sample with its metadata.
struct RecoveryHR: Codable, Sendable, Hashable {
    var end: Int?
    var oneMin: Int?
    var twoMin: Int?
    var apple1min: AppleRecovery?

    enum CodingKeys: String, CodingKey { case end, oneMin = "1min", twoMin = "2min", computed, apple1min = "apple_1min" }

    init(end: Int?, oneMin: Int?, twoMin: Int?, apple1min: AppleRecovery? = nil) {
        self.end = end
        self.oneMin = oneMin
        self.twoMin = twoMin
        self.apple1min = apple1min
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        end = try c.decodeIfPresent(Int.self, forKey: .end)
        oneMin = try c.decodeIfPresent(Int.self, forKey: .oneMin)
        twoMin = try c.decodeIfPresent(Int.self, forKey: .twoMin)
        apple1min = try c.decodeIfPresent(AppleRecovery.self, forKey: .apple1min)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(end, forKey: .end)
        try c.encode(oneMin, forKey: .oneMin)
        try c.encode(twoMin, forKey: .twoMin)
        var computed = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .computed)
        try computed.encode(end, forKey: .end)
        try computed.encode(oneMin, forKey: .oneMin)
        try computed.encode(twoMin, forKey: .twoMin)
        try c.encode(apple1min, forKey: .apple1min)
    }
}

struct AppleRecovery: Codable, Sendable, Hashable {
    var bpm: Int
    var at: Date
    var activityType: String?
    var activityDurationS: Int?
    var maxObservedBpm: Int?
    var testType: String?

    enum CodingKeys: String, CodingKey {
        case bpm, at
        case activityType = "activity_type"
        case activityDurationS = "activity_duration_s"
        case maxObservedBpm = "max_observed_bpm"
        case testType = "test_type"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(at, forKey: .at)
        try c.encode(activityType, forKey: .activityType)
        try c.encode(activityDurationS, forKey: .activityDurationS)
        try c.encode(maxObservedBpm, forKey: .maxObservedBpm)
        try c.encode(testType, forKey: .testType)
    }
}

// MARK: - vitals/<yyyy-MM-dd>.json

struct VitalsDoc: Codable, Sendable, Equatable {
    var schema: String = "healthaccess.vitals.v1"
    var date: String
    var restingHr: Int?
    var hrvSdnnMs: Double?
    var bodyMassKg: Double?
    var sleepS: Int?
    var steps: Int?
    var vo2max: Double?
    var bp: BloodPressure?

    enum CodingKeys: String, CodingKey {
        case schema, date, steps, vo2max, bp
        case restingHr = "resting_hr"
        case hrvSdnnMs = "hrv_sdnn_ms"
        case bodyMassKg = "body_mass_kg"
        case sleepS = "sleep_s"
    }

    var isEmpty: Bool {
        restingHr == nil && hrvSdnnMs == nil && bodyMassKg == nil && sleepS == nil && steps == nil && vo2max == nil && bp == nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(date, forKey: .date)
        try c.encode(restingHr, forKey: .restingHr)
        try c.encode(hrvSdnnMs, forKey: .hrvSdnnMs)
        try c.encode(bodyMassKg, forKey: .bodyMassKg)
        try c.encode(sleepS, forKey: .sleepS)
        try c.encode(steps, forKey: .steps)
        try c.encode(vo2max, forKey: .vo2max)
        try c.encode(bp, forKey: .bp)
    }
}

struct BloodPressure: Codable, Sendable, Equatable {
    var sys: Int
    var dia: Int
    var at: Date
}

// MARK: - index.json

struct IndexDoc: Codable, Sendable {
    var schema: String = "healthaccess.index.v1"
    var updated: Date
    var workouts: [IndexEntry]
}

struct IndexEntry: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var file: String
    var activity: String
    var start: Date
    var durationS: Int
    var distanceM: Double?
    var avgHr: Int?
    var effort: Int?
    var planName: String?
    /// Extension beyond the contract's key list (the Rust side reads it as optional): lets every reader apply the
    /// dedupe rule (same start ±2 s, same source) to the index itself.
    var source: String?

    enum CodingKeys: String, CodingKey {
        case id, file, activity, start, effort, source
        case durationS = "duration_s"
        case distanceM = "distance_m"
        case avgHr = "avg_hr"
        case planName = "plan_name"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(file, forKey: .file)
        try c.encode(activity, forKey: .activity)
        try c.encode(start, forKey: .start)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(avgHr, forKey: .avgHr)
        try c.encode(effort, forKey: .effort)
        try c.encode(planName, forKey: .planName)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

// MARK: - plans/<plan_id>.json (written by the MCP/CLI, read here)

struct PlanDoc: Codable, Sendable, Hashable {
    var schema: String
    var id: String
    var name: String
    var sport: String
    var poolLengthM: Double?
    var warmup: PlanStep?
    var blocks: [PlanBlock]
    var cooldown: PlanStep?
    var notes: String?
    var createdBy: String?
    var createdAt: Date?
    var scheduledFor: Date?

    enum CodingKeys: String, CodingKey {
        case schema, id, name, sport, warmup, blocks, cooldown, notes
        case poolLengthM = "pool_length_m"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case scheduledFor = "scheduled_for"
    }

    struct Resolved: Sendable { let step: PlanStep; let kind: String }

    /// Joins a HealthKit `WOIntervalStepKeyPath` ("block.rep.step", warm-up = 0.0.0, cooldown = blocks.count+1) to this plan.
    func resolve(keyPath: String) -> Resolved? {
        let parts = keyPath.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let block = parts[0], step = parts[2]
        if block == 0 { return warmup.map { Resolved(step: $0, kind: "warmup") } }
        if block >= 1 && block <= blocks.count {
            let steps = blocks[block - 1].steps
            guard step >= 0 && step < steps.count else { return nil }
            let s = steps[step]
            return Resolved(step: s, kind: s.kind ?? (s.goal.type == "distance_m" ? "work" : "recovery"))
        }
        if block == blocks.count + 1 { return cooldown.map { Resolved(step: $0, kind: "cooldown") } }
        return nil
    }

    var totalSteps: Int { (warmup == nil ? 0 : 1) + blocks.reduce(0) { $0 + $1.repeatCount * $1.steps.count } + (cooldown == nil ? 0 : 1) }
}

struct PlanBlock: Codable, Sendable, Hashable {
    var repeatCount: Int
    var steps: [PlanStep]
    enum CodingKeys: String, CodingKey { case repeatCount = "repeat", steps }

    init(repeatCount: Int, steps: [PlanStep]) {
        self.repeatCount = repeatCount
        self.steps = steps
    }

    /// The repeat count is clamped on the way in (validation then rejects anything above 99),
    /// so no count from a file can overflow the arithmetic that sums steps and parts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repeatCount = min(max(try c.decode(Int.self, forKey: .repeatCount), 0), 1_000)
        steps = try c.decode([PlanStep].self, forKey: .steps)
    }
}

struct PlanStep: Codable, Sendable, Hashable {
    var kind: String?
    var goal: PlanGoal
    var zone: Int?
    var label: String?
}

struct PlanGoal: Codable, Sendable, Hashable {
    var type: String   // distance_m | time_s
    var value: Double
}

// MARK: - plans/<plan_id>.status.json (written here)

struct PlanStatus: Codable, Sendable, Hashable {
    var planId: String
    var state: String      // scheduled | failed | cancelled
    var at: Date
    var error: String?
    // Additions beyond the contract (documented in docs/schema.md → Deviations): how the plan reached the Watch and
    // the WorkoutKit plan UUID, which lets a finished HKWorkout be matched back to its plan exactly.
    var method: String?    // schedule | preview
    var workoutkitId: String?
    var scheduledFor: Date?

    enum CodingKeys: String, CodingKey {
        case state, at, error, method
        case planId = "plan_id"
        case workoutkitId = "workoutkit_id"
        case scheduledFor = "scheduled_for"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(planId, forKey: .planId)
        try c.encode(state, forKey: .state)
        try c.encode(at, forKey: .at)
        try c.encode(error, forKey: .error)
        try c.encodeIfPresent(method, forKey: .method)
        try c.encodeIfPresent(workoutkitId, forKey: .workoutkitId)
        try c.encodeIfPresent(scheduledFor, forKey: .scheduledFor)
    }
}
