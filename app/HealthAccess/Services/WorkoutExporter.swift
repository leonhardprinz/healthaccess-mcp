import CoreLocation
import Foundation
import HealthKit

/// A plan that reached the Watch (status `scheduled`), used to join step labels and `plan_ref`.
struct InstalledPlan: Sendable {
    let planId: String
    let name: String
    let sport: String
    let workoutkitId: UUID?
    let scheduledFor: Date?
    let doc: PlanDoc
}

struct PlanLookup: Sendable {
    var plans: [InstalledPlan] = []

    /// Exact match on the WorkoutKit plan UUID first, then the contract's fallback: same sport, scheduled within ±2 h of the start.
    func match(workoutPlanID: UUID?, start: Date, activity: String) -> InstalledPlan? {
        if let id = workoutPlanID, let exact = plans.first(where: { $0.workoutkitId == id }) { return exact }
        let candidates = plans.compactMap { plan -> (InstalledPlan, TimeInterval)? in
            guard PlanInstaller.exportActivity(for: plan.sport) == activity, let at = plan.scheduledFor else { return nil }
            let distance = abs(at.timeIntervalSince(start))
            return distance <= 2 * 3600 ? (plan, distance) : nil
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }
}

/// Builds `healthaccess.workout.v1` documents from HKWorkout: everything HealthKit holds about the workout.
struct WorkoutExporter: Sendable {
    let health: HealthService
    let healthaccessVersion: String

    static let recoveryWindow: TimeInterval = 150

    /// The per-sample series written into `series` (heart rate stays in `hr_series`, the v1 field). All iOS 17 types;
    /// rowing speed (iOS 18) is added for rows at run time.
    static let seriesTypes: [(key: String, identifier: HKQuantityTypeIdentifier)] = [
        ("respiratory_rate", .respiratoryRate),
        ("oxygen_saturation", .oxygenSaturation),
        ("running_power", .runningPower),
        ("running_speed", .runningSpeed),
        ("cycling_power", .cyclingPower),
        ("cycling_cadence", .cyclingCadence),
        ("physical_effort", .physicalEffort),
        ("underwater_depth", .underwaterDepth),
        ("water_temperature", .waterTemperature),
        ("swimming_stroke_count", .swimmingStrokeCount),
    ]

    struct Built: Sendable {
        let doc: WorkoutDoc
        /// `[[t, lat, lon, alt_m, h_acc_m, speed_mps, course_deg], …]` for the sidecar, when the workout has a route.
        let route: [[Double]]?
    }

    func build(for workout: HKWorkout, plans: PlanLookup) async throws -> Built {
        let code = ActivityMapping.code(for: workout)
        let end = workout.endDate
        let allHR = try await health.heartRate(from: workout.startDate, to: end.addingTimeInterval(Self.recoveryWindow))
        let inWorkout = allHR.filter { $0.0 <= end }
        let planID = await health.workoutPlanID(for: workout)
        let matched = plans.match(workoutPlanID: planID, start: workout.startDate, activity: code)
        let meta = workout.metadata ?? [:]

        let hrStats = workout.statistics(for: HKQuantityType(.heartRate))
        let avg = hrStats?.averageQuantity()?.doubleValue(for: HealthService.bpm)
            ?? (inWorkout.isEmpty ? nil : inWorkout.map(\.1).reduce(0, +) / Double(inWorkout.count))
        let max = hrStats?.maximumQuantity()?.doubleValue(for: HealthService.bpm) ?? inWorkout.map(\.1).max()
        // Apple's Effort samples; a failed read (not authorized, iOS 17) must not stop the export.
        let effort = (try? await health.effortScores(for: workout)) ?? HealthService.EffortScores()
        var recovery = Self.recovery(allHR, end: end) ?? RecoveryHR(end: nil, oneMin: nil, twoMin: nil)
        recovery.apple1min = try? await appleRecovery(for: workout)
        let hasRecovery = recovery.end != nil || recovery.oneMin != nil || recovery.twoMin != nil || recovery.apple1min != nil

        var doc = WorkoutDoc(
            healthaccessVersion: healthaccessVersion,
            id: workout.uuid.uuidString,
            activity: code,
            source: workout.sourceRevision.source.name,
            start: workout.startDate,
            end: end,
            durationS: Int(workout.duration.rounded()),
            distanceM: Self.distance(of: workout).map(Self.round1),
            activeKcal: (workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())).map(Self.round1),
            avgHr: avg.map { Int($0.rounded()) },
            maxHr: max.map { Int($0.rounded()) },
            poolLengthM: (meta[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter()),
            zones: nil,
            planRef: matched.map { PlanRef(planId: $0.planId, name: $0.name) },
            steps: Self.steps(of: workout, plan: matched?.doc),
            laps: Self.laps(of: workout),
            hrSeries: Self.downsample(inWorkout),
            recoveryHr: hasRecovery ? recovery : nil,
            effort: effort.effort,
            effortSource: effort.effort == nil ? nil : "apple",
            effortEstimated: effort.estimated,
            feel: nil,
            metadata: Self.stringify(meta))

        doc.statistics = Self.statistics(of: workout)
        doc.totals = Self.totals(of: workout)
        doc.events = Self.events(of: workout)
        doc.series = await series(of: workout, activity: code)
        doc.device = Self.device(of: workout)
        doc.metadataTyped = Self.typed(meta)
        doc.workoutPlanId = planID?.uuidString

        var route: [[Double]]?
        if let points = try? await routePoints(for: workout), !points.isEmpty {
            route = points
            doc.routeSummary = Self.routeSummary(points, meta: meta)
        }
        return Built(doc: doc, route: route)
    }

    /// v0.3 entry point, kept for callers that only want the document.
    func buildDocument(for workout: HKWorkout, plans: PlanLookup) async throws -> WorkoutDoc {
        try await build(for: workout, plans: plans).doc
    }

    /// Only the fields that depend on heart-rate samples arriving after the workout: used to patch a file exported too early.
    func lateHeartRate(for workout: HKWorkout) async throws -> (recovery: RecoveryHR?, maxHr: Int?) {
        let end = workout.endDate
        let allHR = try await health.heartRate(from: workout.startDate, to: end.addingTimeInterval(Self.recoveryWindow))
        let maxHr = workout.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HealthService.bpm)
            ?? allHR.filter { $0.0 <= end }.map(\.1).max()
        var recovery = Self.recovery(allHR, end: end)
        if let apple = try? await appleRecovery(for: workout) {
            if recovery == nil { recovery = RecoveryHR(end: nil, oneMin: nil, twoMin: nil) }
            recovery?.apple1min = apple
        }
        return (recovery, maxHr.map { Int($0.rounded()) })
    }

    static func fileName(for doc: WorkoutDoc) -> String {
        let zone = doc.metadata["HKTimeZone"].flatMap(TimeZone.init(identifier:)) ?? .current
        return "\(HealthAccessJSON.fileStamp(doc.start, timeZone: zone))_\(ActivityMapping.fileToken(doc.activity))_\(doc.id.prefix(8)).json"
    }

    static func routeFileName(for workoutFile: String) -> String {
        String(workoutFile.dropLast(".json".count)) + ".route.json"
    }

    // MARK: pieces

    static func distance(of workout: HKWorkout) -> Double? {
        for type in ActivityMapping.distanceTypes(for: workout.workoutActivityType) {
            if let d = workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter()), d > 0 { return d }
        }
        if let d = workout.totalDistance?.doubleValue(for: .meter()), d > 0 { return d }
        return nil
    }

    /// Nearest sample to end / end+60 s / end+120 s, within a tolerance; nil when nothing is near.
    static func recovery(_ series: [(Date, Double)], end: Date) -> RecoveryHR? {
        func nearest(_ t: Date, tolerance: TimeInterval) -> Int? {
            guard let best = series.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) }),
                  abs(best.0.timeIntervalSince(t)) <= tolerance else { return nil }
            return Int(best.1.rounded())
        }
        let atEnd = nearest(end, tolerance: 20)
        let oneMin = nearest(end.addingTimeInterval(60), tolerance: 20)
        let twoMin = nearest(end.addingTimeInterval(120), tolerance: 25)
        if atEnd == nil && oneMin == nil && twoMin == nil { return nil }
        return RecoveryHR(end: atEnd, oneMin: oneMin, twoMin: twoMin)
    }

    /// Apple's own 1-minute recovery sample, written shortly after the workout, with its metadata.
    func appleRecovery(for workout: HKWorkout) async throws -> AppleRecovery? {
        let type = HKQuantityType(.heartRateRecoveryOneMinute)
        let samples = try await health.quantitySamples(type, from: workout.endDate.addingTimeInterval(-60),
                                                       to: workout.endDate.addingTimeInterval(20 * 60), newestFirst: true)
        guard let sample = samples.first else { return nil }
        let meta = sample.metadata ?? [:]
        let activityType = Self.metaInt(meta[HKMetadataKeyHeartRateRecoveryActivityType])
            .flatMap { HKWorkoutActivityType(rawValue: UInt($0)) }?.humanName.lowercased()
        let duration = (meta[HKMetadataKeyHeartRateRecoveryActivityDuration] as? HKQuantity)?.doubleValue(for: .second())
        let maxObserved = (meta[HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate] as? HKQuantity)?.doubleValue(for: HealthService.bpm)
        let testType = Self.metaInt(meta[HKMetadataKeyHeartRateRecoveryTestType]).map { $0 == 1 ? "max_exercise" : ($0 == 2 ? "predicted_max" : "value_\($0)") }
        return AppleRecovery(bpm: Int(sample.quantity.doubleValue(for: HealthService.bpm).rounded()), at: sample.startDate,
                             activityType: activityType, activityDurationS: duration.map { Int($0.rounded()) },
                             maxObservedBpm: maxObserved.map { Int($0.rounded()) }, testType: testType)
    }

    /// ~1 sample per 5 s: keep a sample when ≥ 4 s have passed since the last kept one; always keep first and last.
    static func downsample(_ series: [(Date, Double)]) -> [HRSample] {
        var out: [HRSample] = []
        var lastKept: Date?
        for (i, s) in series.enumerated() {
            let isLast = i == series.count - 1
            if let last = lastKept, s.0.timeIntervalSince(last) < 4, !isLast { continue }
            out.append(HRSample(at: s.0, bpm: Int(s.1.rounded())))
            lastKept = s.0
        }
        return out
    }

    static func downsampleSeries(_ samples: [HKQuantitySample], export: HealthUnits.Export) -> [SeriesSample] {
        var out: [SeriesSample] = []
        var lastKept: Date?
        for (i, s) in samples.enumerated() {
            let isLast = i == samples.count - 1
            if let last = lastKept, s.startDate.timeIntervalSince(last) < 4, !isLast { continue }
            out.append(SeriesSample(at: s.startDate, value: export.value(s.quantity)))
            lastKept = s.startDate
        }
        return out
    }

    // MARK: statistics, totals, events

    /// Every entry of `HKWorkout.allStatistics`, keyed by the type's snake name, in the file's unit for that type.
    static func statistics(of workout: HKWorkout) -> [String: StatEntry] {
        var out: [String: StatEntry] = [:]
        for (type, stats) in workout.allStatistics {
            guard let spec = HealthTypes.quantity.first(where: { $0.identifier == type.identifier }),
                  let export = HealthUnits.export(for: spec) else { continue }
            let entry = StatEntry(unit: export.label,
                                  avg: stats.averageQuantity().map(export.value),
                                  min: stats.minimumQuantity().map(export.value),
                                  max: stats.maximumQuantity().map(export.value),
                                  sum: stats.sumQuantity().map(export.value))
            if entry.avg != nil || entry.min != nil || entry.max != nil || entry.sum != nil { out[spec.key] = entry }
        }
        return out
    }

    static func totals(of workout: HKWorkout) -> WorkoutTotals? {
        let strokes = workout.statistics(for: HKQuantityType(.swimmingStrokeCount))?.sumQuantity()?.doubleValue(for: .count())
        let flights = workout.statistics(for: HKQuantityType(.flightsClimbed))?.sumQuantity()?.doubleValue(for: .count())
        let basal = workout.statistics(for: HKQuantityType(.basalEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        guard strokes != nil || flights != nil || basal != nil else { return nil }
        return WorkoutTotals(swimmingStrokeCount: strokes.map { Int($0.rounded()) }, flightsClimbed: flights.map { Int($0.rounded()) },
                             energyBasalKcal: basal.map(round1))
    }

    static func eventName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motion_paused"
        case .motionResumed: return "motion_resumed"
        case .segment: return "segment"
        case .pauseOrResumeRequest: return "pause_or_resume_request"
        @unknown default: return "event_\(type.rawValue)"
        }
    }

    static func events(of workout: HKWorkout) -> [EventDoc] {
        (workout.workoutEvents ?? []).map { event in
            EventDoc(type: eventName(event.type), start: event.dateInterval.start, end: event.dateInterval.end,
                     durationS: Int(event.dateInterval.duration.rounded()), metadata: stringify(event.metadata ?? [:]))
        }
    }

    /// Per-sample series inside the workout window for the types that have samples, plus the sport's distance type.
    func series(of workout: HKWorkout, activity: String) async -> [String: SeriesDoc] {
        var out: [String: SeriesDoc] = [:]
        var wanted: [(key: String, type: HKQuantityType)] = Self.seriesTypes.map { ($0.key, HKQuantityType($0.identifier)) }
        if #available(iOS 18.0, *), activity == "indoor_row" || activity == "other:\(HKWorkoutActivityType.rowing.rawValue)" {
            wanted.append(("rowing_speed", HKQuantityType(.rowingSpeed)))
        }
        for type in ActivityMapping.distanceTypes(for: workout.workoutActivityType) {
            if let spec = HealthTypes.quantity.first(where: { $0.identifier == type.identifier }) { wanted.append((spec.key, type)) }
        }
        for (key, type) in wanted {
            guard let spec = HealthTypes.quantity.first(where: { $0.identifier == type.identifier }),
                  let export = HealthUnits.export(for: spec),
                  let samples = try? await health.quantitySamples(type, from: workout.startDate, to: workout.endDate),
                  !samples.isEmpty else { continue }
            out[key] = SeriesDoc(unit: export.label, samples: Self.downsampleSeries(samples, export: export))
        }
        return out
    }

    // MARK: route

    func routePoints(for workout: HKWorkout) async throws -> [[Double]] {
        var points: [[Double]] = []
        for route in try await health.routes(for: workout) {
            for location in try await health.locations(of: route) {
                points.append([
                    location.timestamp.timeIntervalSince1970.rounded(),
                    Self.round5(location.coordinate.latitude),
                    Self.round5(location.coordinate.longitude),
                    Self.round1(location.altitude),
                    Self.round1(location.horizontalAccuracy),
                    location.speed >= 0 ? Self.round1(location.speed) : -1,
                    location.course >= 0 ? Self.round1(location.course) : -1,
                ])
            }
        }
        return points
    }

    static func routeSummary(_ points: [[Double]], meta: [String: Any]) -> RouteSummary {
        var distance = 0.0
        var previous: CLLocation?
        for p in points where p.count >= 3 {
            let location = CLLocation(latitude: p[1], longitude: p[2])
            if let previous { distance += location.distance(from: previous) }
            previous = location
        }
        return RouteSummary(points: points.count, distanceM: round1(distance),
                            ascentM: (meta[HKMetadataKeyElevationAscended] as? HKQuantity).map { round1($0.doubleValue(for: .meter())) },
                            descentM: (meta[HKMetadataKeyElevationDescended] as? HKQuantity).map { round1($0.doubleValue(for: .meter())) })
    }

    // MARK: device and typed metadata

    static func device(of workout: HKWorkout) -> DeviceDoc {
        let device = workout.device
        let revision = workout.sourceRevision
        let version = revision.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return DeviceDoc(name: device?.name, model: device?.model, manufacturer: device?.manufacturer,
                         hardwareVersion: device?.hardwareVersion, softwareVersion: device?.softwareVersion,
                         sourceName: revision.source.name, sourceBundleId: revision.source.bundleIdentifier,
                         sourceVersion: revision.version, operatingSystem: os)
    }

    static func typed(_ meta: [String: Any]) -> MetadataTyped {
        var t = MetadataTyped()
        t.indoor = (meta[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue
        t.poolLengthM = (meta[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter())
        if let location = metaInt(meta[HKMetadataKeySwimmingLocationType]) {
            switch location {
            case HKWorkoutSwimmingLocationType.pool.rawValue: t.swimmingLocation = "pool"
            case HKWorkoutSwimmingLocationType.openWater.rawValue: t.swimmingLocation = "open_water"
            default: t.swimmingLocation = "unknown"
            }
        }
        let temp = (meta[HKMetadataKeyWeatherTemperature] as? HKQuantity)?.doubleValue(for: .degreeCelsius())
        let humidity = (meta[HKMetadataKeyWeatherHumidity] as? HKQuantity)?.doubleValue(for: .percent())
        let condition = metaInt(meta[HKMetadataKeyWeatherCondition]).map(weatherName)
        if temp != nil || humidity != nil || condition != nil {
            t.weather = WeatherDoc(tempC: temp.map(round1), humidityPct: humidity.map { round1($0 * 100) }, condition: condition)
        }
        t.elevationAscendedM = (meta[HKMetadataKeyElevationAscended] as? HKQuantity).map { round1($0.doubleValue(for: .meter())) }
        t.elevationDescendedM = (meta[HKMetadataKeyElevationDescended] as? HKQuantity).map { round1($0.doubleValue(for: .meter())) }
        let metUnit = HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        t.averageMets = (meta[HKMetadataKeyAverageMETs] as? HKQuantity).map { JSONBuilder.round($0.doubleValue(for: metUnit), 2) }
        let mps = HKUnit.meter().unitDivided(by: .second())
        t.averageSpeedMps = (meta[HKMetadataKeyAverageSpeed] as? HKQuantity).map { JSONBuilder.round($0.doubleValue(for: mps), 2) }
        t.maximumSpeedMps = (meta[HKMetadataKeyMaximumSpeed] as? HKQuantity).map { JSONBuilder.round($0.doubleValue(for: mps), 2) }
        t.coached = (meta[HKMetadataKeyCoachedWorkout] as? NSNumber)?.boolValue
        if meta[HKMetadataKeyAppleFitnessPlusSession] != nil {
            t.fitnessPlus = (meta[HKMetadataKeyAppleFitnessPlusSession] as? NSNumber)?.boolValue ?? true
        }
        t.brand = meta[HKMetadataKeyWorkoutBrandName] as? String
        t.timeZone = meta[HKMetadataKeyTimeZone] as? String
        return t
    }

    static func weatherName(_ raw: Int) -> String {
        guard let condition = HKWeatherCondition(rawValue: raw) else { return "value_\(raw)" }
        switch condition {
        case .none: return "none"
        case .clear: return "clear"
        case .fair: return "fair"
        case .partlyCloudy: return "partly_cloudy"
        case .mostlyCloudy: return "mostly_cloudy"
        case .cloudy: return "cloudy"
        case .foggy: return "foggy"
        case .haze: return "haze"
        case .windy: return "windy"
        case .blustery: return "blustery"
        case .smoky: return "smoky"
        case .dust: return "dust"
        case .snow: return "snow"
        case .hail: return "hail"
        case .sleet: return "sleet"
        case .freezingDrizzle: return "freezing_drizzle"
        case .freezingRain: return "freezing_rain"
        case .mixedRainAndHail: return "mixed_rain_and_hail"
        case .mixedRainAndSnow: return "mixed_rain_and_snow"
        case .mixedRainAndSleet: return "mixed_rain_and_sleet"
        case .mixedSnowAndSleet: return "mixed_snow_and_sleet"
        case .drizzle: return "drizzle"
        case .scatteredShowers: return "scattered_showers"
        case .showers: return "showers"
        case .thunderstorms: return "thunderstorms"
        case .tropicalStorm: return "tropical_storm"
        case .hurricane: return "hurricane"
        case .tornado: return "tornado"
        @unknown default: return "value_\(raw)"
        }
    }

    // MARK: steps and laps

    struct KeyPath3 { let block: Int; let rep: Int; let step: Int }

    static func parse(keyPath: String) -> KeyPath3? {
        let parts = keyPath.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return KeyPath3(block: parts[0], rep: parts[1], step: parts[2])
    }

    /// One step per HKWorkoutActivity. A single activity without a key path carries no information → `[]`.
    static func steps(of workout: HKWorkout, plan: PlanDoc?) -> [StepDoc] {
        let activities = workout.workoutActivities.sorted { $0.startDate < $1.startDate }
        let keyed = activities.map { ($0, $0.metadata?["WOIntervalStepKeyPath"] as? String) }
        guard activities.count > 1 || keyed.contains(where: { $0.1 != nil }) else { return [] }
        let parsed = keyed.compactMap { $0.1 }.compactMap(parse(keyPath:))
        let maxBlock = parsed.map(\.block).max() ?? 0
        let perBlock = Dictionary(grouping: parsed, by: \.block).mapValues(\.count)
        let distanceTypes = ActivityMapping.distanceTypes(for: workout.workoutActivityType)

        return keyed.enumerated().map { index, pair in
            let (activity, key) = pair
            let kp = key.flatMap(parse(keyPath:))
            let block = kp?.block ?? index
            let rep = kp?.rep ?? 0
            let step = kp?.step ?? 0
            let meta = activity.metadata ?? [:]
            let end = activity.endDate ?? workout.endDate
            let duration = activity.duration

            var distance: Double?
            for type in distanceTypes {
                if let d = activity.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter()), d > 0 { distance = d; break }
            }
            let avg = activity.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HealthService.bpm)
            let resolved = key.flatMap { plan?.resolve(keyPath: $0) }
            let hadDistanceGoal = meta["WOIntervalStepDistacnceGoalAchievedDuration"] != nil

            let kind: String
            if let resolved {
                kind = resolved.kind
            } else if kp != nil && block == 0 {
                kind = "warmup"
            } else if kp != nil && block == maxBlock && maxBlock > 1 && perBlock[block] == 1 {
                kind = "cooldown" // Apple appends the cooldown as a trailing single-step block
            } else if distance != nil || hadDistanceGoal {
                kind = "work"
            } else {
                kind = "recovery"
            }

            var pace: Double?
            if let d = distance, d > 0 { pace = round1(duration / d * 100) }

            return StepDoc(
                key: key ?? "\(index)",
                block: block, rep: rep, step: step,
                label: resolved?.step.label,
                kind: kind,
                start: activity.startDate, end: end,
                durationS: Int(duration.rounded()),
                distanceM: distance.map(round1),
                avgHr: avg.map { Int($0.rounded()) },
                goalMet: metaBool(meta["WOIntervalStepSuccessful"]),
                paceSPer100m: pace)
        }
    }

    static func laps(of workout: HKWorkout) -> [LapDoc] {
        (workout.workoutEvents ?? []).filter { $0.type == .lap }.map { event in
            let meta = event.metadata ?? [:]
            let style = metaInt(meta[HKMetadataKeySwimmingStrokeStyle]).flatMap(HKSwimmingStrokeStyle.init(rawValue:))
            return LapDoc(
                start: event.dateInterval.start,
                end: event.dateInterval.end,
                durationS: Int(event.dateInterval.duration.rounded()),
                stroke: style.flatMap(strokeName),
                swolf: metaDouble(meta[HKMetadataKeySWOLFScore]).map(round1))
        }
    }

    static func strokeName(_ style: HKSwimmingStrokeStyle) -> String? {
        switch style {
        case .mixed: return "mixed"
        case .freestyle: return "freestyle"
        case .backstroke: return "backstroke"
        case .breaststroke: return "breaststroke"
        case .butterfly: return "butterfly"
        case .kickboard: return "kickboard"
        case .unknown: return nil
        @unknown default: return nil
        }
    }

    static func stringify(_ meta: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in meta {
            if let date = v as? Date { out[k] = HealthAccessJSON.string(date) } else { out[k] = "\(v)" }
        }
        return out
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round5(_ x: Double) -> Double { (x * 100_000).rounded() / 100_000 }

    static func metaInt(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func metaDouble(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func metaBool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "1" || s.lowercased() == "true" }
        return nil
    }
}
