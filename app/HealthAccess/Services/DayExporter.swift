import Foundation
import HealthKit

/// `days/YYYY-MM-DD.json`: every group of docs/export-coverage.md that has data for that day. Groups are present only
/// when they hold a value; inside a present group the named fields are explicit `null` when absent. Types the catalog
/// says have no data are not queried.
struct DayExporter: Sendable {
    let health: HealthService
    /// Identifiers with data per the last catalog; nil queries everything.
    let typesWithData: Set<String>?
    let includeReproductive: Bool

    static let schema = "healthaccess.day.v1"

    /// Writes the files for `days`, only when the content changed. Returns the number written.
    func export(days: [Date], folder: FolderStore, log: @Sendable (String) async -> Void) async -> Int {
        var written = 0
        for day in days {
            do {
                let object = try await document(for: day)
                let path = "days/\(object["date"] as? String ?? HealthAccessJSON.dayString(day)).json"
                var comparable = object
                comparable["updated"] = nil
                if let existing = try folder.read(path), var old = try? JSONBuilder.object(existing) {
                    old["updated"] = nil
                    if NSDictionary(dictionary: old).isEqual(to: comparable) { continue }
                }
                try folder.write(try JSONBuilder.data(object), to: path)
                written += 1
            } catch {
                await log("day \(HealthAccessJSON.dayString(day)) failed: \(error.localizedDescription)")
            }
        }
        return written
    }

    func document(for day: Date, timeZone: TimeZone = .current) async throws -> JSONObject {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let ctx = DayContext(health: health, start: start, end: end, calendar: calendar, typesWithData: typesWithData)

        var object: JSONObject = [
            "schema": Self.schema,
            "date": HealthAccessJSON.dayString(start, timeZone: timeZone),
            "time_zone": timeZone.identifier,
            "updated": HealthAccessJSON.string(Date()),
        ]
        func put(_ key: String, _ group: JSONObject?) {
            guard let group, !group.isEmpty, !JSONBuilder.isAllNull(group) else { return }
            object[key] = group
        }
        put("activity", await ctx.activity())
        put("heart", await ctx.heart())
        put("respiratory", await ctx.respiratory())
        put("sleep", await ctx.sleep())
        put("body", await ctx.body())
        put("blood", await ctx.blood())
        put("mobility", await ctx.mobility())
        put("hearing", await ctx.hearing())
        put("nutrition", await ctx.nutrition())
        put("mind", await ctx.mind())
        put("symptoms", await ctx.symptoms().map { ["entries": $0] })
        if includeReproductive { put("cycle", await ctx.cycle()) }
        put("medications", await ctx.medications().map { ["entries": $0] })
        put("hygiene", await ctx.hygiene())
        put("uv", await ctx.uv())
        put("wheelchair", await ctx.wheelchair())
        put("audiogram", await ctx.audiograms().map { ["entries": $0] })
        put("vision", await ctx.vision().map { ["entries": $0] })
        return object
    }
}

/// One day's window and the small query vocabulary the groups are written with.
struct DayContext: Sendable {
    let health: HealthService
    let start: Date
    let end: Date
    let calendar: Calendar
    let typesWithData: Set<String>?

    // MARK: vocabulary

    func spec(_ name: String) -> HealthTypeSpec? {
        HealthTypes.quantity.first { $0.name == name } ?? HealthTypes.category.first { $0.name == name }
    }

    func has(_ spec: HealthTypeSpec) -> Bool {
        guard let typesWithData else { return true }
        return typesWithData.contains(spec.identifier)
    }

    func quantity(_ name: String) -> (HKQuantityType, HealthUnits.Export)? {
        guard let found = spec(name), found.kind == .quantity, has(found),
              let type = HealthService.quantityType(found), let export = HealthUnits.export(for: found) else { return nil }
        return (type, export)
    }

    func category(_ name: String) -> (HKCategoryType, HealthTypeSpec)? {
        guard let found = spec(name), found.kind == .category, has(found), let type = HealthService.categoryType(found) else { return nil }
        return (type, found)
    }

    /// Newest sample of the day, in the file's unit.
    func latest(_ name: String) async -> Double? {
        guard let (type, export) = quantity(name),
              let sample = try? await health.quantitySamples(type, from: start, to: end, limit: 1, newestFirst: true).first else { return nil }
        return export.value(sample.quantity)
    }

    func sum(_ name: String) async -> Double? {
        guard let (type, export) = quantity(name),
              let q = try? await health.statistics(type, from: start, to: end, options: .cumulativeSum)?.sumQuantity() else { return nil }
        return export.value(q)
    }

    func average(_ name: String) async -> Double? {
        guard let (type, export) = quantity(name),
              let q = try? await health.statistics(type, from: start, to: end, options: .discreteAverage)?.averageQuantity() else { return nil }
        return export.value(q)
    }

    func minMaxAvg(_ name: String) async -> (min: Double?, avg: Double?, max: Double?) {
        guard let (type, export) = quantity(name),
              let stats = try? await health.statistics(type, from: start, to: end, options: [.discreteMin, .discreteAverage, .discreteMax]) else {
            return (nil, nil, nil)
        }
        return (stats.minimumQuantity().map(export.value), stats.averageQuantity().map(export.value), stats.maximumQuantity().map(export.value))
    }

    func samples(_ name: String) async -> [HKQuantitySample] {
        guard let (type, _) = quantity(name) else { return [] }
        return (try? await health.quantitySamples(type, from: start, to: end)) ?? []
    }

    func categorySamples(_ name: String, options: HKQueryOptions = []) async -> [HKCategorySample] {
        guard let (type, _) = category(name) else { return [] }
        return (try? await health.categorySamples(type, from: start, to: end, options: options)) ?? []
    }

    /// Entries of a category type as `[{at, end, value}]` with the value as a word.
    func categoryEntries(_ name: String, extra: ((HKCategorySample) -> JSONObject)? = nil) async -> [JSONObject]? {
        guard let (_, found) = category(name) else { return nil }
        let samples = await categorySamples(name)
        guard !samples.isEmpty else { return nil }
        return samples.map { sample in
            var entry: JSONObject = [
                "at": HealthAccessJSON.string(sample.startDate),
                "end": HealthAccessJSON.string(sample.endDate),
                "value": CategoryValues.word(sample.value, valueType: found.valueType),
            ]
            if let extra { entry.merge(extra(sample)) { _, new in new } }
            return entry
        }
    }

    func times(of samples: [HKCategorySample]) -> [String] { samples.map { HealthAccessJSON.string($0.startDate) } }

    // MARK: groups

    func activity() async -> JSONObject? {
        var g: JSONObject = [:]
        if let summary = try? await health.activitySummary(for: start, calendar: calendar) {
            var rings: JSONObject = [
                "move_kcal": JSONBuilder.round(summary.activeEnergyBurned.doubleValue(for: .kilocalorie()), 0),
                "move_kcal_goal": JSONBuilder.round(summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()), 0),
                "exercise_min": JSONBuilder.round(summary.appleExerciseTime.doubleValue(for: .minute()), 0),
                "exercise_min_goal": JSONBuilder.round(summary.appleExerciseTimeGoal.doubleValue(for: .minute()), 0),
                "stand_hours": JSONBuilder.round(summary.appleStandHours.doubleValue(for: .count()), 0),
                "stand_hours_goal": JSONBuilder.round(summary.appleStandHoursGoal.doubleValue(for: .count()), 0),
                "move_mode": summary.activityMoveMode == .appleMoveTime ? "apple_move_time" : "active_energy",
            ]
            if summary.activityMoveMode == .appleMoveTime {
                rings["move_min"] = JSONBuilder.round(summary.appleMoveTime.doubleValue(for: .minute()), 0)
                rings["move_min_goal"] = JSONBuilder.round(summary.appleMoveTimeGoal.doubleValue(for: .minute()), 0)
            }
            if #available(iOS 18.0, *) { rings["paused"] = summary.isPaused }
            g["rings"] = rings
        } else {
            g["rings"] = JSONBuilder.null
        }
        g["steps"] = JSONBuilder.value(await sum("StepCount"))
        g["distance_walking_running_m"] = JSONBuilder.value(await sum("DistanceWalkingRunning"))
        g["distance_cycling_m"] = JSONBuilder.value(await sum("DistanceCycling"))
        g["distance_swimming_m"] = JSONBuilder.value(await sum("DistanceSwimming"))
        for spec in HealthTypes.quantity where spec.name.hasPrefix("Distance") && has(spec) {
            let key = spec.key + "_m"
            if g[key] == nil, let value = await sum(spec.name) { g[key] = value }
        }
        g["flights_climbed"] = JSONBuilder.value(await sum("FlightsClimbed"))
        g["active_energy_kcal"] = JSONBuilder.value(await sum("ActiveEnergyBurned"))
        g["basal_energy_kcal"] = JSONBuilder.value(await sum("BasalEnergyBurned"))
        g["exercise_min"] = JSONBuilder.value(await sum("AppleExerciseTime"))
        g["stand_min"] = JSONBuilder.value(await sum("AppleStandTime"))
        g["move_min"] = JSONBuilder.value(await sum("AppleMoveTime"))
        g["time_in_daylight_min"] = JSONBuilder.value(await sum("TimeInDaylight"))
        g["physical_effort_avg_met"] = JSONBuilder.value(await average("PhysicalEffort"))
        g["push_count"] = JSONBuilder.value(await sum("PushCount"))
        return g
    }

    func heart() async -> JSONObject? {
        var g: JSONObject = [:]
        g["resting_hr"] = JSONBuilder.value(await latest("RestingHeartRate"))
        g["walking_hr_avg"] = JSONBuilder.value(await latest("WalkingHeartRateAverage"))
        let hr = await minMaxAvg("HeartRate")
        if hr.avg != nil, let (type, _) = quantity("HeartRate") {
            let count = (try? await health.count(type, from: start, to: end, cap: 100_000))?.count
            g["hr"] = ["min": JSONBuilder.value(hr.min), "avg": JSONBuilder.value(hr.avg), "max": JSONBuilder.value(hr.max), "samples": JSONBuilder.value(count)] as JSONObject
        } else {
            g["hr"] = JSONBuilder.null
        }
        g["hrv_sdnn_ms"] = JSONBuilder.value(await average("HeartRateVariabilitySDNN"))
        if let rmssd = await average("HeartRateVariabilityRMSSD") { g["hrv_rmssd_ms"] = rmssd }
        g["recovery_1min_bpm"] = JSONBuilder.value(await latest("HeartRateRecoveryOneMinute"))
        g["vo2max"] = JSONBuilder.value(await latest("VO2Max"))
        g["afib_burden_pct"] = JSONBuilder.value(await latest("AtrialFibrillationBurden"))
        g["peripheral_perfusion_index_pct"] = JSONBuilder.value(await latest("PeripheralPerfusionIndex"))
        var events: JSONObject = [:]
        for (key, name) in [("high_hr", "HighHeartRateEvent"), ("low_hr", "LowHeartRateEvent"), ("irregular_rhythm", "IrregularHeartRhythmEvent"),
                            ("low_cardio_fitness", "LowCardioFitnessEvent"), ("hypertension", "HypertensionEvent")] {
            let samples = await categorySamples(name)
            guard !samples.isEmpty else { continue }
            var entry: JSONObject = ["count": samples.count, "times": times(of: samples)]
            let thresholds = samples.compactMap { ($0.metadata?[HKMetadataKeyHeartRateEventThreshold] as? HKQuantity)?.doubleValue(for: HealthService.bpm) }
            if let threshold = thresholds.first { entry["threshold_bpm"] = JSONBuilder.round(threshold, 0) }
            events[key] = entry
        }
        g["events"] = events.isEmpty ? JSONBuilder.null : events
        return g
    }

    func respiratory() async -> JSONObject? {
        var g: JSONObject = [:]
        g["rate_avg"] = JSONBuilder.value(await average("RespiratoryRate"))
        let spo2 = await minMaxAvg("OxygenSaturation")
        g["spo2"] = spo2.avg == nil ? JSONBuilder.null : ["avg": JSONBuilder.value(spo2.avg), "min": JSONBuilder.value(spo2.min)] as JSONObject
        g["breathing_disturbances"] = JSONBuilder.value(await average("AppleSleepingBreathingDisturbances"))
        let apnea = await categorySamples("SleepApneaEvent")
        g["sleep_apnea_events"] = apnea.isEmpty ? JSONBuilder.null : apnea.count
        g["fev1_l"] = JSONBuilder.value(await latest("ForcedExpiratoryVolume1"))
        g["fvc_l"] = JSONBuilder.value(await latest("ForcedVitalCapacity"))
        g["peak_flow_l_min"] = JSONBuilder.value(await latest("PeakExpiratoryFlowRate"))
        g["inhaler_usage"] = JSONBuilder.value(await sum("InhalerUsage"))
        return g
    }

    func sleep() async -> JSONObject? {
        // Sleep is credited to the day it ended (the morning); the source with the most sleep wins, no double counting.
        let samples = await categorySamples("SleepAnalysis", options: [.strictEndDate])
        guard !samples.isEmpty else { return nil }
        let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        var bySource: [String: TimeInterval] = [:]
        for s in samples where asleepValues.contains(s.value) {
            bySource[s.sourceRevision.source.bundleIdentifier, default: 0] += s.endDate.timeIntervalSince(s.startDate)
        }
        let best = bySource.max { $0.value < $1.value }?.key ?? samples[0].sourceRevision.source.bundleIdentifier
        let mine = samples.filter { $0.sourceRevision.source.bundleIdentifier == best }
        func seconds(_ values: Set<Int>) -> Int {
            Int(mine.filter { values.contains($0.value) }.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }.rounded())
        }
        var g: JSONObject = [:]
        let inBed = seconds([HKCategoryValueSleepAnalysis.inBed.rawValue])
        let asleep = seconds(asleepValues)
        g["in_bed_s"] = inBed > 0 ? inBed : JSONBuilder.null
        g["asleep_s"] = asleep > 0 ? asleep : JSONBuilder.null
        g["core_s"] = JSONBuilder.value(nonZero(seconds([HKCategoryValueSleepAnalysis.asleepCore.rawValue])))
        g["deep_s"] = JSONBuilder.value(nonZero(seconds([HKCategoryValueSleepAnalysis.asleepDeep.rawValue])))
        g["rem_s"] = JSONBuilder.value(nonZero(seconds([HKCategoryValueSleepAnalysis.asleepREM.rawValue])))
        g["awake_s"] = JSONBuilder.value(nonZero(seconds([HKCategoryValueSleepAnalysis.awake.rawValue])))
        // Sessions: the best source's samples, split where the gap is over an hour.
        var sessions: [JSONObject] = []
        var sessionStart: Date?
        var sessionEnd: Date?
        for s in mine.sorted(by: { $0.startDate < $1.startDate }) {
            if let currentEnd = sessionEnd, s.startDate.timeIntervalSince(currentEnd) > 3600, let currentStart = sessionStart {
                sessions.append(["start": HealthAccessJSON.string(currentStart), "end": HealthAccessJSON.string(currentEnd), "source": mine[0].sourceRevision.source.name])
                sessionStart = nil
                sessionEnd = nil
            }
            if sessionStart == nil { sessionStart = s.startDate }
            sessionEnd = max(sessionEnd ?? s.endDate, s.endDate)
        }
        if let currentStart = sessionStart, let currentEnd = sessionEnd {
            sessions.append(["start": HealthAccessJSON.string(currentStart), "end": HealthAccessJSON.string(currentEnd), "source": mine[0].sourceRevision.source.name])
        }
        g["sessions"] = sessions
        g["wrist_temperature_c"] = JSONBuilder.value(await latest("AppleSleepingWristTemperature"))
        // Respiratory rate and SpO2 inside the sleep sessions.
        if let first = sessions.first?["start"] as? String, let last = sessions.last?["end"] as? String,
           let from = HealthAccessJSON.date(first), let to = HealthAccessJSON.date(last) {
            g["respiratory_rate_sleep"] = JSONBuilder.value(await averageBetween("RespiratoryRate", from, to))
            g["spo2_sleep"] = JSONBuilder.value(await averageBetween("OxygenSaturation", from, to))
        } else {
            g["respiratory_rate_sleep"] = JSONBuilder.null
            g["spo2_sleep"] = JSONBuilder.null
        }
        return g
    }

    private func nonZero(_ x: Int) -> Int? { x > 0 ? x : nil }

    private func averageBetween(_ name: String, _ from: Date, _ to: Date) async -> Double? {
        guard let (type, export) = quantity(name),
              let q = try? await health.statistics(type, from: from, to: to, options: .discreteAverage)?.averageQuantity() else { return nil }
        return export.value(q)
    }

    func body() async -> JSONObject? {
        var g: JSONObject = [:]
        g["mass_kg"] = JSONBuilder.value(await latest("BodyMass"))
        g["fat_pct"] = JSONBuilder.value(await latest("BodyFatPercentage"))
        g["lean_kg"] = JSONBuilder.value(await latest("LeanBodyMass"))
        g["bmi"] = JSONBuilder.value(await latest("BodyMassIndex"))
        g["waist_cm"] = JSONBuilder.value(await latest("WaistCircumference"))
        g["height_cm"] = JSONBuilder.value(await latest("Height"))
        g["temperature_c"] = JSONBuilder.value(await latest("BodyTemperature"))
        g["basal_body_temperature_c"] = JSONBuilder.value(await latest("BasalBodyTemperature"))
        g["electrodermal_activity_s"] = JSONBuilder.value(await latest("ElectrodermalActivity"))
        return g
    }

    func blood() async -> JSONObject? {
        var g: JSONObject = [:]
        var pressure: [JSONObject] = []
        if let bp = HealthTypes.correlation.first(where: { $0.name == "BloodPressure" }), let type = HealthService.correlationType(bp),
           let sys = spec(forName: "BloodPressureSystolic"), has(sys),
           let correlations = try? await health.correlations(type, from: start, to: end) {
            let mmHg = HKUnit.millimeterOfMercury()
            for c in correlations {
                guard let s = (c.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg),
                      let d = (c.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg) else { continue }
                pressure.append(["sys": Int(s.rounded()), "dia": Int(d.rounded()), "at": HealthAccessJSON.string(c.startDate)])
            }
        }
        g["pressure"] = pressure.isEmpty ? JSONBuilder.null : pressure
        let glucose = await samples("BloodGlucose")
        let mgdl = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        g["glucose"] = glucose.isEmpty ? JSONBuilder.null : glucose.map { s -> JSONObject in
            let value = s.quantity.doubleValue(for: mgdl)
            var entry: JSONObject = ["mmol_l": JSONBuilder.round(value / 18.016, 1), "mg_dl": JSONBuilder.round(value, 0), "at": HealthAccessJSON.string(s.startDate)]
            if let meal = (s.metadata?[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber)?.intValue {
                entry["meal_time"] = meal == 1 ? "preprandial" : (meal == 2 ? "postprandial" : "value_\(meal)")
            } else {
                entry["meal_time"] = JSONBuilder.null
            }
            return entry
        }
        g["alcohol_pct"] = JSONBuilder.value(await latest("BloodAlcoholContent"))
        g["alcoholic_beverages"] = JSONBuilder.value(await sum("NumberOfAlcoholicBeverages"))
        let insulin = await samples("InsulinDelivery")
        g["insulin"] = insulin.isEmpty ? JSONBuilder.null : insulin.map { s -> JSONObject in
            let reason = (s.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber)?.intValue
            return ["units": JSONBuilder.round(s.quantity.doubleValue(for: .internationalUnit()), 2),
                    "reason": reason.map { $0 == 1 ? "basal" : ($0 == 2 ? "bolus" : "value_\($0)") } ?? JSONBuilder.null,
                    "at": HealthAccessJSON.string(s.startDate)]
        }
        return g
    }

    private func spec(forName name: String) -> HealthTypeSpec? { spec(name) }

    func mobility() async -> JSONObject? {
        var g: JSONObject = [:]
        g["walking_speed_mps"] = JSONBuilder.value(await average("WalkingSpeed"))
        g["step_length_cm"] = JSONBuilder.value(await average("WalkingStepLength"))
        g["asymmetry_pct"] = JSONBuilder.value(await average("WalkingAsymmetryPercentage"))
        g["double_support_pct"] = JSONBuilder.value(await average("WalkingDoubleSupportPercentage"))
        g["stair_ascent_mps"] = JSONBuilder.value(await average("StairAscentSpeed"))
        g["stair_descent_mps"] = JSONBuilder.value(await average("StairDescentSpeed"))
        g["steadiness_pct"] = JSONBuilder.value(await latest("AppleWalkingSteadiness"))
        g["steadiness_events"] = await categoryEntries("AppleWalkingSteadinessEvent") ?? JSONBuilder.null
        g["six_minute_walk_m"] = JSONBuilder.value(await latest("SixMinuteWalkTestDistance"))
        g["falls"] = JSONBuilder.value(await sum("NumberOfTimesFallen"))
        g["running_stride_length_cm"] = JSONBuilder.value(await average("RunningStrideLength"))
        g["running_ground_contact_time_ms"] = JSONBuilder.value(await average("RunningGroundContactTime"))
        g["running_vertical_oscillation_cm"] = JSONBuilder.value(await average("RunningVerticalOscillation"))
        g["cycling_ftp_w"] = JSONBuilder.value(await latest("CyclingFunctionalThresholdPower"))
        return g
    }

    func hearing() async -> JSONObject? {
        var g: JSONObject = [:]
        g["environmental_exposure_db"] = JSONBuilder.value(await average("EnvironmentalAudioExposure"))
        g["headphone_exposure_db"] = JSONBuilder.value(await average("HeadphoneAudioExposure"))
        g["environmental_sound_reduction_db"] = JSONBuilder.value(await average("EnvironmentalSoundReduction"))
        var events: JSONObject = [:]
        let environmental = await categorySamples("EnvironmentalAudioExposureEvent")
        if !environmental.isEmpty { events["environmental"] = ["count": environmental.count, "times": times(of: environmental)] as JSONObject }
        let headphone = await categorySamples("HeadphoneAudioExposureEvent")
        if !headphone.isEmpty { events["headphone"] = ["count": headphone.count, "times": times(of: headphone)] as JSONObject }
        g["events"] = events.isEmpty ? JSONBuilder.null : events
        return g
    }

    /// Every `Dietary*` quantity with a sample that day, summed, keyed by identifier and unit.
    func nutrition() async -> JSONObject? {
        var g: JSONObject = [:]
        for spec in HealthTypes.quantity where spec.name.hasPrefix("Dietary") && has(spec) {
            guard let value = await sum(spec.name) else { continue }
            let suffix: String
            switch spec.unit {
            case "kcal": suffix = "_kcal"
            case "mL": suffix = "_ml"
            default: suffix = "_g"
            }
            g[spec.key + suffix] = value
        }
        return g.isEmpty ? nil : g
    }

    func mind() async -> JSONObject? {
        var g: JSONObject = [:]
        let mindful = await categorySamples("MindfulSession")
        g["mindful_minutes"] = mindful.isEmpty ? JSONBuilder.null : JSONBuilder.round(mindful.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 60, 1)
        var states: [JSONObject] = []
        var assessments: [JSONObject] = []
        if #available(iOS 18.0, *) {
            if typesWithData == nil || typesWithData?.contains("HKStateOfMind") == true,
               let moods = try? await health.statesOfMind(from: start, to: end) {
                states = moods.map { mood in
                    ["at": HealthAccessJSON.string(mood.startDate),
                     "kind": mood.kind == .dailyMood ? "daily_mood" : "momentary_emotion",
                     "valence": JSONBuilder.round(mood.valence, 2),
                     "valence_class": "\(mood.valenceClassification)",
                     "labels": mood.labels.map { "\($0)" },
                     "associations": mood.associations.map { "\($0)" }]
                }
            }
            if typesWithData == nil || typesWithData?.contains("HKScoredAssessmentGAD7") == true,
               let gad7 = try? await health.gad7(from: start, to: end) {
                assessments += gad7.map { ["kind": "gad7", "score": $0.score, "risk": "\($0.risk)", "at": HealthAccessJSON.string($0.startDate)] }
            }
            if typesWithData == nil || typesWithData?.contains("HKScoredAssessmentPHQ9") == true,
               let phq9 = try? await health.phq9(from: start, to: end) {
                assessments += phq9.map { ["kind": "phq9", "score": $0.score, "risk": "\($0.risk)", "at": HealthAccessJSON.string($0.startDate)] }
            }
        }
        g["state_of_mind"] = states.isEmpty ? JSONBuilder.null : states
        g["assessments"] = assessments.isEmpty ? JSONBuilder.null : assessments
        return g
    }

    /// The symptom category types (severity, presence, appetite) logged that day.
    func symptoms() async -> [JSONObject]? {
        var out: [JSONObject] = []
        let symptomValueTypes: Set<String> = ["HKCategoryValueSeverity", "HKCategoryValuePresence", "HKCategoryValueAppetiteChanges"]
        for spec in HealthTypes.category where symptomValueTypes.contains(spec.valueType) && has(spec) {
            for s in await categorySamples(spec.name) {
                out.append(["type": spec.key, "severity": CategoryValues.word(s.value, valueType: spec.valueType),
                            "at": HealthAccessJSON.string(s.startDate), "end": HealthAccessJSON.string(s.endDate)])
            }
        }
        return out.isEmpty ? nil : out
    }

    func cycle() async -> JSONObject? {
        var g: JSONObject = [:]
        g["menstrual_flow"] = await categoryEntries("MenstrualFlow") { s in
            ["cycle_start": (s.metadata?[HKMetadataKeyMenstrualCycleStart] as? NSNumber)?.boolValue ?? false]
        } ?? JSONBuilder.null
        for name in ["IntermenstrualBleeding", "InfrequentMenstrualCycles", "IrregularMenstrualCycles", "ProlongedMenstrualPeriods",
                     "PersistentIntermenstrualBleeding", "BleedingDuringPregnancy", "BleedingAfterPregnancy", "BleedingAfterMenopause",
                     "CervicalMucusQuality", "OvulationTestResult", "PregnancyTestResult", "ProgesteroneTestResult", "Contraceptive",
                     "Pregnancy", "Lactation", "MenopausalState"] {
            if let found = spec(name), let entries = await categoryEntries(name) { g[found.key] = entries }
        }
        g["sexual_activity"] = await categoryEntries("SexualActivity") { s in
            ["protection_used": (s.metadata?[HKMetadataKeySexualActivityProtectionUsed] as? NSNumber).map { $0.boolValue } ?? JSONBuilder.null]
        } ?? JSONBuilder.null
        return g
    }

    func medications() async -> [JSONObject]? {
        guard #available(iOS 26.0, *), typesWithData?.contains("HKMedicationDoseEvent") == true,
              let events = try? await health.medicationDoseEvents(from: start, to: end), !events.isEmpty else { return nil }
        return events.map { event in
            ["concept_id": "\(event.medicationConceptIdentifier)",
             "at": HealthAccessJSON.string(event.startDate),
             "scheduled_for": JSONBuilder.value(event.scheduledDate),
             "status": "\(event.logStatus)",
             "schedule": "\(event.scheduleType)",
             "dose": JSONBuilder.value(event.doseQuantity),
             "scheduled_dose": JSONBuilder.value(event.scheduledDoseQuantity),
             "unit": event.unit.unitString]
        }
    }

    func hygiene() async -> JSONObject? {
        var g: JSONObject = [:]
        let hands = await categorySamples("HandwashingEvent")
        g["handwashing"] = hands.isEmpty ? JSONBuilder.null : ["count": hands.count, "seconds": Int(hands.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }.rounded())] as JSONObject
        let teeth = await categorySamples("ToothbrushingEvent")
        g["toothbrushing"] = teeth.isEmpty ? JSONBuilder.null : ["count": teeth.count, "seconds": Int(teeth.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }.rounded())] as JSONObject
        return g
    }

    func uv() async -> JSONObject? {
        let uv = await minMaxAvg("UVExposure")
        guard let max = uv.max else { return nil }
        return ["uv_index_max": max]
    }

    func wheelchair() async -> JSONObject? {
        var g: JSONObject = [:]
        g["push_count"] = JSONBuilder.value(await sum("PushCount"))
        g["distance_m"] = JSONBuilder.value(await sum("DistanceWheelchair"))
        return g
    }

    func audiograms() async -> [JSONObject]? {
        guard typesWithData == nil || typesWithData?.contains("HKAudiogram") == true,
              let samples = try? await health.audiograms(from: start, to: end), !samples.isEmpty else { return nil }
        return samples.map { sample in
            var entry: JSONObject = ["at": HealthAccessJSON.string(sample.startDate), "points": sample.sensitivityPoints.count]
            if #available(iOS 18.1, *) {
                entry["tests"] = sample.sensitivityPoints.flatMap { point in
                    point.tests.map { test -> JSONObject in
                        ["frequency_hz": JSONBuilder.round(point.frequency.doubleValue(for: .hertz()), 0),
                         "sensitivity_db": JSONBuilder.round(test.sensitivity.doubleValue(for: .decibelHearingLevel()), 1),
                         "side": "\(test.side)", "conduction": "\(test.type)", "masked": test.masked]
                    }
                }
            }
            return entry
        }
    }

    func vision() async -> [JSONObject]? {
        guard typesWithData?.contains("HKVisionPrescription") == true,
              let samples = try? await health.visionPrescriptions(from: start, to: end), !samples.isEmpty else { return nil }
        return samples.map { sample in
            ["at": HealthAccessJSON.string(sample.startDate),
             "type": sample.prescriptionType == .glasses ? "glasses" : "contacts",
             "issued": HealthAccessJSON.string(sample.dateIssued),
             "expires": JSONBuilder.value(sample.expirationDate)]
        }
    }
}
