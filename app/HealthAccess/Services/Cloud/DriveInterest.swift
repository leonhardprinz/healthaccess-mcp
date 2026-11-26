import Foundation

/// "I want this drive": one event, sent only when the user taps and confirms. It tells the developer that
/// someone asked for a drive the app cannot upload to yet. It carries the drive's name, the app version and
/// the random install id; nothing about the person and no health data. It does not switch usage statistics on.
enum DriveInterest {
    static let event = "drive_interest"

    static func key(_ kind: CloudKind) -> String { AppSettings.key("cloud.interest.\(kind.rawValue)") }

    static func wasSent(_ kind: CloudKind) -> Bool { UserDefaults.standard.bool(forKey: key(kind)) }

    /// The one request: PostHog's capture endpoint, with the same project the opt-in usage statistics use.
    static func request(host: String, token: String, installID: String, drive: CloudKind, version: String, build: String) -> URLRequest? {
        var base = host
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/i/v0/e/"), url.scheme == "https" else { return nil }
        let body: [String: Any] = [
            "api_key": token,
            "event": event,
            "distinct_id": installID,
            "properties": [
                "drive": drive.rawValue,
                "$app_version": version,
                "$app_build": build,
                "$lib": "healthaccess-ios",
                "$process_person_profile": false,
                "$geoip_disable": true,
            ] as [String: Any],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 20
        return request
    }

    static func send(_ request: URLRequest, session: URLSession = .shared) async -> Bool {
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
