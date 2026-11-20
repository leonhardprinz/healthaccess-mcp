import AppIntents

/// "Sync Health data" in the Shortcuts app: the same sync as opening the app, without opening it. Made for automations,
/// such as "When Sleep Focus turns off", so last night's sleep is in the folder at a known moment.
struct SyncHealthDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Health data"
    static let description = IntentDescription("Writes new workouts and today's and yesterday's health data, last night's sleep included, into your Health Access folder.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await AppModel.shared.syncFromShortcut()
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Puts the action in Shortcuts and Spotlight without any setup.
struct HealthAccessShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncHealthDataIntent(),
                    phrases: ["Sync \(.applicationName)", "Sync my health data with \(.applicationName)"],
                    shortTitle: "Sync Health data",
                    systemImageName: "arrow.triangle.2.circlepath")
    }
}
