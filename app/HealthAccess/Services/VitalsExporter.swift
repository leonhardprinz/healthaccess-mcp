import Foundation
import HealthKit

/// Builds `healthaccess.vitals.v1` documents, one per local day.
struct VitalsExporter: Sendable {
    let health: HealthService

    func document(for day: Date, timeZone: TimeZone = .current) async throws -> VitalsDoc {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var doc = VitalsDoc(date: HealthAccessJSON.dayString(start, timeZone: timeZone))

        if let s = try await health.samples(.restingHeartRate, from: start, to: end, newestFirst: true, limit: 1).first {
            doc.restingHr = Int(s.quantity.doubleValue(for: HealthService.bpm).rounded())
        }
        if let q = try await health.statistics(.heartRateVariabilitySDNN, from: start, to: end, options: .discreteAverage)?.averageQuantity() {
            doc.hrvSdnnMs = WorkoutExporter.round1(q.doubleValue(for: .secondUnit(with: .milli)))
        }
        if let s = try await health.samples(.bodyMass, from: start, to: end, newestFirst: true, limit: 1).first {
            doc.bodyMassKg = WorkoutExporter.round1(s.quantity.doubleValue(for: .gramUnit(with: .kilo)))
        }
        doc.sleepS = try await health.sleepSeconds(from: start, to: end)
        if let q = try await health.statistics(.stepCount, from: start, to: end, options: .cumulativeSum)?.sumQuantity() {
            doc.steps = Int(q.doubleValue(for: .count()).rounded())
        }
        if let s = try await health.samples(.vo2Max, from: start, to: end, newestFirst: true, limit: 1).first {
            doc.vo2max = WorkoutExporter.round1(s.quantity.doubleValue(for: HealthService.vo2MaxUnit))
        }
        doc.bp = try await health.bloodPressure(from: start, to: end)
        return doc
    }

    /// Writes `vitals/<date>.json` only when the content changed. Returns the number of files written.
    func export(days: [Date], folder: FolderStore, log: @Sendable (String) async -> Void) async -> Int {
        var written = 0
        for day in days {
            do {
                let doc = try await document(for: day)
                guard !doc.isEmpty else { continue }
                let path = "vitals/\(doc.date).json"
                let data = try HealthAccessJSON.encode(doc)
                if let existing = try folder.read(path), existing == data { continue }
                try folder.write(data, to: path)
                written += 1
            } catch {
                await log("vitals \(HealthAccessJSON.dayString(day)) failed: \(error.localizedDescription)")
            }
        }
        return written
    }
}
