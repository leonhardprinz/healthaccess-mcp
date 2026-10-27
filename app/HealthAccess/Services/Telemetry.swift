import Foundation
import PostHog

/// Opt-in usage statistics ("Usage statistics" in Settings). Initialised only while the toggle is on and
/// `TelemetryConfig.plist` is bundled. Events carry counts, durations, trigger names, a method name, a client kind and error codes.
/// Never health values, file names or folder paths: the event helpers take only numbers and enum strings.
@MainActor
final class Telemetry {
    static let shared = Telemetry()

    enum Event {
        case appOpened
        case exportCompleted(workoutCount: Int, durationMs: Int, trigger: String)
        case exportFailed(domain: String, code: Int)
        case planScheduled
        case planPutOnWatch(method: String)
        case setupMessageCopied
        case aiConnected(client: AIClientKind)
    }

    /// The only thing `ai_connected` says about a client: one of a fixed list, never the raw name, machine, file or version.
    enum AIClientKind: String {
        case claudeCode = "claude-code", claudeDesktop = "claude-desktop", cursor, codex, lmStudio = "lm-studio", goose, other

        /// From the MCP host's own `clientInfo.name` ("claude-code", "claude-ai", "cursor-vscode", "codex-mcp-client", …).
        init(clientName: String) {
            let n = clientName.lowercased().filter { $0.isLetter || $0.isNumber }
            if n.contains("claudecode") { self = .claudeCode }
            else if n.contains("claude") { self = .claudeDesktop }
            else if n.contains("cursor") { self = .cursor }
            else if n.contains("codex") { self = .codex }
            else if n.contains("lmstudio") { self = .lmStudio }
            else if n.contains("goose") { self = .goose }
            else { self = .other }
        }
    }

    struct Config {
        let host: String
        let token: String
    }

    let config: Config?
    private(set) var isRunning = false

    /// Everything else the SDK adds ($locale, $timezone, $screen_*, $network_*, $device_*, …) is dropped before sending.
    static let allowedProperties: Set<String> = [
        "workout_count", "duration_ms", "trigger", "error_domain", "code", "method", "client",
        "$app_version", "$app_build", "$os_name", "$os_version", "$lib", "$lib_version", "$device_type",
        "distinct_id", "$session_id", "$process_person_profile", "$is_identified", "$geoip_disable", "$anon_distinct_id",
    ]

    var isAvailable: Bool { config != nil }

    /// Host name shown in "What left this phone", e.g. "eu.i.posthog.com".
    var hostName: String? {
        guard let host = config?.host else { return nil }
        return URL(string: host)?.host ?? host
    }

    private init() {
        config = Self.loadConfig()
    }

    private static func loadConfig() -> Config? {
        guard let url = Bundle.main.url(forResource: "TelemetryConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let host = dict["PostHogHost"] as? String,
              let token = dict["PostHogProjectToken"] as? String,
              !host.isEmpty, !token.isEmpty, !token.hasPrefix("phc_your")
        else { return nil }
        return Config(host: host, token: token)
    }

    func start(installID: String) {
        guard !isRunning, let config else { return }
        let c = PostHogConfig(projectToken: config.token, host: config.host)
        c.captureApplicationLifecycleEvents = false
        c.captureScreenViews = false
        c.enableSwizzling = false
        c.sessionReplay = false
        c.preloadFeatureFlags = false
        c.sendFeatureFlagEvent = false
        c.surveys = false
        c.errorTrackingConfig.autoCapture = false
        c.personProfiles = .never
        c.setDefaultPersonProperties = false
        c.disableGeoIp = true
        c.getAnonymousId = { _ in UUID(uuidString: installID) ?? UUID() }
        // The SDK attaches device/locale/network context by default; keep only what the contract allows.
        c.setBeforeSend { event in
            event.properties = event.properties.filter { Self.allowedProperties.contains($0.key) }
            return event
        }
        PostHogSDK.shared.setup(c)
        PostHogSDK.shared.optIn()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        PostHogSDK.shared.optOut()
        PostHogSDK.shared.close()
        isRunning = false
    }

    func capture(_ event: Event) {
        guard isRunning else { return }
        let name: String
        var properties: [String: Any] = [:]
        switch event {
        case .appOpened:
            name = "app_opened"
        case let .exportCompleted(workoutCount, durationMs, trigger):
            name = "export_completed"
            properties = ["workout_count": workoutCount, "duration_ms": durationMs, "trigger": trigger]
        case let .exportFailed(domain, code):
            name = "export_failed"
            properties = ["error_domain": domain, "code": code]
        case .planScheduled:
            name = "plan_scheduled"
        case let .planPutOnWatch(method):
            name = "plan_put_on_watch"
            properties = ["method": method]
        case .setupMessageCopied:
            name = "setup_message_copied"
        case let .aiConnected(client):
            name = "ai_connected"
            properties = ["client": client.rawValue]
        }
        PostHogSDK.shared.capture(name, properties: properties.isEmpty ? nil : properties)
        NetworkLedger.shared.record(host: hostName ?? "posthog", event: name)
    }

    func flush() {
        if isRunning { PostHogSDK.shared.flush() }
    }
}
