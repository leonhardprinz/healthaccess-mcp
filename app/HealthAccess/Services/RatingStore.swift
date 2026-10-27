import Foundation

/// Rewrites only the effort fields (`effort`, `effort_source`, `effort_estimated`) and, for late heart-rate data,
/// `recovery_hr` / `max_hr` inside an existing workout file. Works on the raw JSON object so every other field survives
/// byte-for-byte in meaning, then writes atomically. The athlete rates on the Watch; Apple exports that rating, so the
/// app only ever copies Apple's numbers in, it never asks.
enum RatingStore {
    /// What a workout file currently says about effort.
    struct EffortState: Sendable, Equatable {
        var effort: Int?
        var source: String?
        var estimated: Int?
        var feel: String?
    }

    static func patch(file: String, folder: FolderStore, _ mutate: (inout [String: Any]) -> Void) throws {
        guard let data = try folder.read(file) else { throw HealthAccessError("workout file missing: \(file)") }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HealthAccessError("workout file is not a JSON object: \(file)")
        }
        mutate(&object)
        var out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        try folder.write(out, to: file)
    }

    static func readEffort(file: String, folder: FolderStore) throws -> EffortState {
        guard let data = try folder.read(file),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HealthAccessError("workout file missing: \(file)")
        }
        return EffortState(effort: score(object["effort"]), source: object["effort_source"] as? String,
                           estimated: score(object["effort_estimated"]), feel: object["feel"] as? String)
    }

    private static func score(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        return score1to10(n.doubleValue)
    }

    /// Apple's Effort samples arrived (at export time or on a later run). Per the contract, Apple's rating overwrites an
    /// `ai` or missing effort but never one the athlete entered in the app. Returns true when the file changed.
    @discardableResult
    static func applyAppleEffort(effort: Int?, estimated: Int?, file: String, folder: FolderStore) throws -> Bool {
        let before = try readEffort(file: file, folder: folder)
        var after = before
        if let estimated { after.estimated = estimated }
        if let effort, before.source != "app" {
            after.effort = effort
            after.source = "apple"
        }
        guard after != before else { return false }
        try patch(file: file, folder: folder) { object in
            object["effort"] = after.effort.map { NSNumber(value: $0) } ?? NSNull()
            object["effort_source"] = after.effort == nil ? NSNull() : (after.source.map { $0 as Any } ?? NSNull())
            object["effort_estimated"] = after.estimated.map { NSNumber(value: $0) } ?? NSNull()
        }
        return true
    }

    static func saveLateHeartRate(recovery: RecoveryHR?, maxHr: Int?, file: String, folder: FolderStore) throws {
        let encoded = try recovery.map { try JSONSerialization.jsonObject(with: HealthAccessJSON.encode($0)) }
        try patch(file: file, folder: folder) { object in
            if let encoded { object["recovery_hr"] = encoded }
            if let maxHr { object["max_hr"] = NSNumber(value: maxHr) }
        }
    }
}
