import Foundation
import HealthKit

/// Activity codes of the contract: pool_swim | open_water_swim | indoor_row | run | walk | cycle | other:<hk raw>.
enum ActivityMapping {
    static func code(for workout: HKWorkout) -> String {
        let meta = workout.metadata ?? [:]
        switch workout.workoutActivityType {
        case .swimming:
            let loc = (meta[HKMetadataKeySwimmingLocationType] as? NSNumber)?.intValue
            return loc == HKWorkoutSwimmingLocationType.openWater.rawValue ? "open_water_swim" : "pool_swim"
        case .rowing:
            // The Watch's "Indoor Row" sets HKIndoorWorkout = 1. Outdoor rowing is not in the contract's list.
            if let indoor = meta[HKMetadataKeyIndoorWorkout] as? NSNumber, !indoor.boolValue { return "other:\(HKWorkoutActivityType.rowing.rawValue)" }
            return "indoor_row"
        case .running: return "run"
        case .walking: return "walk"
        case .cycling: return "cycle"
        default: return "other:\(workout.workoutActivityType.rawValue)"
        }
    }

    /// Token used in the file name: `<date>_<token>_<uuid8>.json`.
    static func fileToken(_ code: String) -> String {
        switch code {
        case "pool_swim": return "PoolSwim"
        case "open_water_swim": return "OpenWaterSwim"
        case "indoor_row": return "IndoorRow"
        case "run": return "Run"
        case "walk": return "Walk"
        case "cycle": return "Cycle"
        default: return "Workout" + code.replacingOccurrences(of: "other:", with: "")
        }
    }

    static func title(_ code: String) -> String {
        switch code {
        case "pool_swim": return "Pool swim"
        case "open_water_swim": return "Open water swim"
        case "indoor_row": return "Indoor row"
        case "run": return "Run"
        case "walk": return "Walk"
        case "cycle": return "Cycle"
        // plan sports that are not export codes
        case "indoor_run": return "Indoor run"
        case "hike": return "Hike"
        case "indoor_cycle": return "Indoor cycle"
        case "hiit": return "HIIT"
        case "elliptical": return "Elliptical"
        default:
            if let raw = UInt(code.replacingOccurrences(of: "other:", with: "")), let type = HKWorkoutActivityType(rawValue: raw) {
                return type.humanName
            }
            return "Workout"
        }
    }

    /// For the rating prompt: "Rate your swim".
    static func verb(_ code: String) -> String {
        switch code {
        case "pool_swim", "open_water_swim": return "swim"
        case "indoor_row": return "row"
        case "run": return "run"
        case "walk": return "walk"
        case "cycle": return "ride"
        default: return "workout"
        }
    }

    static func symbol(_ code: String) -> String {
        switch code {
        case "pool_swim": return "figure.pool.swim"
        case "open_water_swim": return "figure.open.water.swim"
        case "indoor_row": return "figure.rower"
        case "run": return "figure.run"
        case "walk": return "figure.walk"
        case "cycle": return "figure.outdoor.cycle"
        default: return "figure.mixed.cardio"
        }
    }

    /// Distance quantity types to try, most specific first, for a workout of this type.
    static func distanceTypes(for type: HKWorkoutActivityType) -> [HKQuantityType] {
        switch type {
        case .swimming: return [HKQuantityType(.distanceSwimming)]
        case .rowing:
            if #available(iOS 18.0, *) { return [HKQuantityType(.distanceRowing)] }
            return []
        case .running, .walking, .hiking: return [HKQuantityType(.distanceWalkingRunning)]
        case .cycling: return [HKQuantityType(.distanceCycling)]
        default: return [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
        }
    }
}

extension HKWorkoutActivityType {
    var humanName: String {
        switch self {
        case .swimming: return "Swim"
        case .rowing: return "Row"
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .hiking: return "Hike"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "Stairs"
        case .coreTraining: return "Core"
        case .flexibility: return "Flexibility"
        case .cooldown: return "Cooldown"
        case .mixedCardio: return "Mixed cardio"
        default: return "Workout \(rawValue)"
        }
    }
}
