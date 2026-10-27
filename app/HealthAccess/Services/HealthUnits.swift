import Foundation
import HealthKit

/// Units for the generated type list. The header names every quantity type's canonical unit ("count/min", "kcal",
/// "ml/(kg*min)" …); `unit(for:)` builds the HKUnit for it, `export(for:)` picks the unit the files use (rates in
/// bpm, small lengths in cm, percentages as 0 to 100) and its label.
enum HealthUnits {
    struct Export: Sendable {
        let unit: HKUnit
        let label: String
        /// Multiply the HKUnit value by this for the file (percent: HealthKit's 0.97 → 97).
        let scale: Double
        let decimals: Int

        func value(_ quantity: HKQuantity) -> Double {
            let raw = quantity.doubleValue(for: unit) * scale
            let factor = pow(10.0, Double(decimals))
            return (raw * factor).rounded() / factor
        }
    }

    static let bpm = HKUnit.count().unitDivided(by: .minute())

    /// The HKUnit for a header unit string; nil for a string this build does not know.
    static func unit(for string: String) -> HKUnit? {
        switch string {
        case "g": return .gram()
        case "kg": return .gramUnit(with: .kilo)
        case "kcal": return .kilocalorie()
        case "m": return .meter()
        case "cm": return .meterUnit(with: .centi)
        case "m/s": return HKUnit.meter().unitDivided(by: .second())
        case "count": return .count()
        case "count/min": return bpm
        case "count/s": return HKUnit.count().unitDivided(by: .second())
        case "%": return .percent()
        case "min": return .minute()
        case "ms": return .secondUnit(with: .milli)
        case "degC": return .degreeCelsius()
        case "mmHg": return .millimeterOfMercury()
        case "W": return .watt()
        case "L": return .liter()
        case "mL": return .literUnit(with: .milli)
        case "L/min": return HKUnit.liter().unitDivided(by: .minute())
        case "mg/dL": return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case "ml/(kg*min)", "mL/(kg*min)":
            return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case "kcal/(kg*hr)":
            return HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        case "dBASPL": return .decibelAWeightedSoundPressureLevel()
        case "IU": return .internationalUnit()
        case "S": return .siemen()
        case "": return .count()   // UV index
        case "appleEffortScore":
            if #available(iOS 18.0, *) { return .appleEffortScore() }
            return nil
        default: return nil
        }
    }

    /// The unit the files use for this type and how to label it.
    static func export(for spec: HealthTypeSpec) -> Export? {
        switch spec.unit {
        case "count/s":   // heart rate, respiratory rate
            return Export(unit: bpm, label: "count/min", scale: 1, decimals: 1)
        case "%":
            return Export(unit: .percent(), label: "%", scale: 100, decimals: 1)
        case "m":
            if spec.name == "Height" || spec.name == "WaistCircumference" || spec.name == "WalkingStepLength" || spec.name == "RunningStrideLength" {
                return Export(unit: .meterUnit(with: .centi), label: "cm", scale: 1, decimals: 1)
            }
            return Export(unit: .meter(), label: "m", scale: 1, decimals: 1)
        case "g":
            return Export(unit: .gram(), label: "g", scale: 1, decimals: 3)
        case "ml/(kg*min)", "mL/(kg*min)":
            return unit(for: spec.unit).map { Export(unit: $0, label: "mL/kg/min", scale: 1, decimals: 1) }
        case "kcal/(kg*hr)":
            return unit(for: spec.unit).map { Export(unit: $0, label: "MET", scale: 1, decimals: 2) }
        case "":
            return Export(unit: .count(), label: "index", scale: 1, decimals: 1)
        default:
            return unit(for: spec.unit).map { Export(unit: $0, label: spec.unit, scale: 1, decimals: 2) }
        }
    }
}
