import Foundation

/// `profile.json`: the characteristics, read once per sync, written when they change. Age and birth year only, never
/// the full date of birth.
enum ProfileExporter {
    static let file = "profile.json"

    static func export(health: HealthService, folder: FolderStore, now: Date = Date()) throws -> Bool {
        let c = health.characteristics(now: now)
        var object: JSONObject = [
            "schema": "healthaccess.profile.v1",
            "age": JSONBuilder.value(c.age),
            "birth_year": JSONBuilder.value(c.birthYear),
            "biological_sex": JSONBuilder.value(c.biologicalSex),
            "blood_type": JSONBuilder.value(c.bloodType),
            "wheelchair_use": JSONBuilder.value(c.wheelchairUse),
            "activity_move_mode": JSONBuilder.value(c.activityMoveMode),
            "fitzpatrick_skin_type": JSONBuilder.value(c.fitzpatrickSkinType),
        ]
        if let existing = try folder.read(file), var old = try? JSONBuilder.object(existing) {
            old["updated"] = nil
            if NSDictionary(dictionary: old).isEqual(to: object) { return false }
        }
        object["updated"] = HealthAccessJSON.string(now)
        try folder.write(try JSONBuilder.data(object), to: file)
        return true
    }
}
