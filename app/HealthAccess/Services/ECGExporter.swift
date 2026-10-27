import Foundation
import HealthKit

/// `ecg/<yyyy-MM-dd_HHmm>_<uuid8>.json` per electrocardiogram of the last 90 days, never overwritten; the voltage
/// series goes into `ecg/<same>.voltage.json` only when Settings → "Include ECG voltage" is on (large).
struct ECGExporter: Sendable {
    let health: HealthService
    static let windowDays = 90

    struct Result: Sendable {
        var written = 0
        var voltages = 0
    }

    func export(folder: FolderStore, includeVoltage: Bool, now: Date = Date(), log: @Sendable (String) async -> Void) async -> Result {
        var result = Result()
        let from = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let ecgs: [HKElectrocardiogram]
        do {
            ecgs = try await health.electrocardiograms(from: from, to: now)
        } catch {
            await log("ecg query failed: \(error.localizedDescription)")
            return result
        }
        guard !ecgs.isEmpty else { return result }
        let existing = Set((try? folder.list("ecg")) ?? [])
        for ecg in ecgs {
            let zone = (ecg.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
            let base = "\(HealthAccessJSON.fileStamp(ecg.startDate, timeZone: zone))_\(ecg.uuid.uuidString.prefix(8))"
            let file = "\(base).json"
            let voltageFile = "\(base).voltage.json"
            let needVoltage = includeVoltage && !existing.contains(voltageFile)
            guard !existing.contains(file) || needVoltage else { continue }
            do {
                if needVoltage {
                    let samples = try await health.voltages(of: ecg)
                    let sidecar: JSONObject = [
                        "schema": "healthaccess.ecg_voltage.v1",
                        "id": ecg.uuid.uuidString,
                        "sampling_frequency_hz": JSONBuilder.value(ecg.samplingFrequency?.doubleValue(for: .hertz())),
                        "unit": "uV",
                        "samples": samples.map { [JSONBuilder.round($0.0, 4), JSONBuilder.round($0.1, 2)] },
                    ]
                    try folder.write(try JSONBuilder.data(sidecar), to: "ecg/\(voltageFile)")
                    result.voltages += 1
                }
                let hasVoltage = includeVoltage || existing.contains(voltageFile)
                let object: JSONObject = [
                    "schema": "healthaccess.ecg.v1",
                    "id": ecg.uuid.uuidString,
                    "start": HealthAccessJSON.string(ecg.startDate),
                    "end": HealthAccessJSON.string(ecg.endDate),
                    "classification": Self.classification(ecg.classification),
                    "symptoms_status": Self.symptoms(ecg.symptomsStatus),
                    "average_heart_rate_bpm": JSONBuilder.value(ecg.averageHeartRate.map { JSONBuilder.round($0.doubleValue(for: HealthService.bpm), 0) }),
                    "sampling_frequency_hz": JSONBuilder.value(ecg.samplingFrequency?.doubleValue(for: .hertz())),
                    "number_of_voltage_measurements": ecg.numberOfVoltageMeasurements,
                    "algorithm_version": JSONBuilder.value(ecg.metadata?[HKMetadataKeyAppleECGAlgorithmVersion].map { "\($0)" }),
                    "device": JSONBuilder.value(ecg.device?.name),
                    "source": ecg.sourceRevision.source.name,
                    "voltage_file": hasVoltage ? "ecg/\(voltageFile)" : JSONBuilder.null,
                ]
                try folder.write(try JSONBuilder.data(object), to: "ecg/\(file)")
                result.written += 1
            } catch {
                await log("ecg \(base) failed: \(error.localizedDescription)")
            }
        }
        return result
    }

    static func classification(_ c: HKElectrocardiogram.Classification) -> String {
        switch c {
        case .notSet: return "not_set"
        case .sinusRhythm: return "sinus_rhythm"
        case .atrialFibrillation: return "atrial_fibrillation"
        case .inconclusiveLowHeartRate: return "inconclusive_low_heart_rate"
        case .inconclusiveHighHeartRate: return "inconclusive_high_heart_rate"
        case .inconclusivePoorReading: return "inconclusive_poor_reading"
        case .inconclusiveOther: return "inconclusive_other"
        case .unrecognized: return "unrecognized"
        @unknown default: return "value_\(c.rawValue)"
        }
    }

    static func symptoms(_ s: HKElectrocardiogram.SymptomsStatus) -> String {
        switch s {
        case .notSet: return "not_set"
        case .none: return "none"
        case .present: return "present"
        @unknown default: return "value_\(s.rawValue)"
        }
    }
}
