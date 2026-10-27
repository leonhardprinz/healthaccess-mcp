import Foundation
import HealthKit

/// `catalog.json`: per type, whether Health has data (90-day sample count, first and last date) and where this build
/// exports it. iOS hides read authorization, so `authorized` is always null and `has_data` is the real signal.
/// `healthaccess doctor` compares this against its own copy of the SDK list.
struct CatalogBuilder: Sendable {
    let health: HealthService
    static let cap = 10_000
    static let windowDays = 90
    static let file = "catalog.json"

    func build(includeReproductive: Bool, appVersion: String, now: Date = Date()) async -> JSONObject {
        let from = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        var types: JSONObject = [:]
        let characteristics = health.characteristics(now: now)
        for spec in HealthTypes.all {
            var entry: JSONObject = [
                "kind": spec.kind.rawValue,
                "ios": spec.ios,
                "authorized": JSONBuilder.null,
                "has_data": false,
                "samples_90d": 0,
                "capped": false,
                "first": JSONBuilder.null,
                "last": JSONBuilder.null,
                "exported_in": "none",
            ]
            if spec.kind == .quantity { entry["unit"] = spec.unit }
            if !includeReproductive && HealthService.reproductiveNames.contains(spec.name) {
                entry["exported_in"] = "excluded"
                entry["note"] = "reproductive health data is switched off in Settings"
            } else if spec.kind == .characteristic {
                let value: String?
                switch spec.name {
                case "DateOfBirth": value = characteristics.birthYear.map(String.init)
                case "BiologicalSex": value = characteristics.biologicalSex
                case "BloodType": value = characteristics.bloodType
                case "WheelchairUse": value = characteristics.wheelchairUse
                case "ActivityMoveMode": value = characteristics.activityMoveMode
                case "FitzpatrickSkinType": value = characteristics.fitzpatrickSkinType
                default: value = nil
                }
                entry["has_data"] = value != nil
                entry["exported_in"] = value != nil ? "profile" : "none"
            } else if let type = HealthService.sampleType(spec) {
                if let count = try? await health.count(type, from: from, to: now, cap: Self.cap) {
                    entry["has_data"] = count.count > 0
                    entry["samples_90d"] = count.count
                    entry["capped"] = count.capped
                    entry["first"] = JSONBuilder.value(count.first)
                    entry["last"] = JSONBuilder.value(count.last)
                    entry["exported_in"] = count.count > 0 ? "days" : "none"
                } else {
                    entry["note"] = "query failed"
                }
            } else {
                entry["note"] = "not in this iOS"
            }
            types[spec.identifier] = entry
        }

        for special in HealthService.specialTypes {
            var entry: JSONObject = [
                "kind": "special",
                "authorized": JSONBuilder.null,
                "has_data": false,
                "samples_90d": 0,
                "capped": false,
                "first": JSONBuilder.null,
                "last": JSONBuilder.null,
                "exported_in": "none",
            ]
            if let sampleType = special.type as? HKSampleType {
                if let count = try? await health.count(sampleType, from: from, to: now, cap: Self.cap) {
                    entry["has_data"] = count.count > 0
                    entry["samples_90d"] = count.count
                    entry["capped"] = count.capped
                    entry["first"] = JSONBuilder.value(count.first)
                    entry["last"] = JSONBuilder.value(count.last)
                    if count.count > 0 { entry["exported_in"] = Self.exportedIn(special.name) }
                } else {
                    entry["note"] = "query failed"
                }
            } else if special.name == "HKActivitySummary" {
                let days = await activitySummaryDays(from: from, to: now)
                entry["has_data"] = days > 0
                entry["samples_90d"] = days
                entry["exported_in"] = days > 0 ? "days" : "none"
            }
            if special.name == "HKHeartbeatSeries" { entry["note"] = "counted, not exported (raw beat-to-beat series)" }
            types[special.name] = entry
        }

        return [
            "schema": "healthaccess.catalog.v1",
            "generated": HealthAccessJSON.string(now),
            "app_version": appVersion,
            "sdk": "iOS \(HealthTypes.sdkVersion)",
            "window_days": Self.windowDays,
            "cap": Self.cap,
            "types": types,
            "unknown_types_with_data": [] as [String],
        ]
    }

    private static func exportedIn(_ special: String) -> String {
        switch special {
        case "HKWorkoutType", "HKWorkoutRoute": return "workouts"
        case "HKElectrocardiogram": return "ecg"
        case "HKHeartbeatSeries": return "none"
        default: return "days"
        }
    }

    private func activitySummaryDays(from: Date, to: Date) async -> Int {
        var calendar = Calendar.current
        calendar.timeZone = .current
        var start = calendar.dateComponents([.year, .month, .day], from: from)
        start.calendar = calendar
        var end = calendar.dateComponents([.year, .month, .day], from: to)
        end.calendar = calendar
        let descriptor = HKActivitySummaryQueryDescriptor(predicate: HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end))
        return (try? await descriptor.result(for: health.store).count) ?? 0
    }

    /// The identifiers the last catalog said have data (nil when there is no catalog yet: then everything is queried).
    static func typesWithData(folder: FolderStore) -> Set<String>? {
        guard let data = try? folder.read(file), let object = try? JSONBuilder.object(data),
              let types = object["types"] as? JSONObject else { return nil }
        var out = Set<String>()
        for (identifier, value) in types {
            if let entry = value as? JSONObject, (entry["has_data"] as? Bool) == true { out.insert(identifier) }
        }
        return out
    }

    static func countWithData(_ catalog: JSONObject) -> Int {
        guard let types = catalog["types"] as? JSONObject else { return 0 }
        return types.values.filter { (($0 as? JSONObject)?["has_data"] as? Bool) == true }.count
    }
}
