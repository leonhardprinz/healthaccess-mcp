import Foundation

/// Dictionary-shaped documents (days, catalog, profile, ecg) written with the contract's conventions:
/// sorted keys, ISO-8601 UTC timestamps, explicit `null` for named fields without a value, trailing newline.
typealias JSONObject = [String: Any]

enum JSONBuilder {
    static let null = NSNull()

    static func data(_ object: JSONObject) throws -> Data {
        var out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        return out
    }

    static func object(_ data: Data) throws -> JSONObject {
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw HealthAccessError("not a JSON object")
        }
        return object
    }

    /// A value or `null`.
    static func value(_ x: Double?) -> Any { x.map { NSNumber(value: $0) } ?? null }
    static func value(_ x: Int?) -> Any { x.map { NSNumber(value: $0) } ?? null }
    static func value(_ x: Bool?) -> Any { x.map { NSNumber(value: $0) } ?? null }
    static func value(_ x: String?) -> Any { x ?? null }
    static func value(_ x: Date?) -> Any { x.map(HealthAccessJSON.string) ?? null }

    static func round(_ x: Double, _ decimals: Int = 1) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (x * factor).rounded() / factor
    }

    /// True when every value of the object is `null` (the group then stays out of the file).
    static func isAllNull(_ object: JSONObject) -> Bool {
        object.values.allSatisfy { value in
            if value is NSNull { return true }
            if let array = value as? [Any] { return array.isEmpty }
            if let nested = value as? JSONObject { return isAllNull(nested) }
            return false
        }
    }
}
