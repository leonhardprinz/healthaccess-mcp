import Foundation
import UserNotifications

/// Local notifications only (free team: no push), all about plans: one appeared while the app was not in front, or, in
/// automatic mode, it went onto the Watch (or could not). Rating is the Watch's job; Apple exports that rating.
enum Notifier {
    static let planCategory = "HEALTHACCESS_PLAN"

    /// Must run at launch, before any notification is posted or acted on.
    static func registerCategories() {
        let plan = UNNotificationCategory(identifier: planCategory, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([plan])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// "Your AI wrote S27" when a plan file appears while the app is not in front.
    static func postPlanPrompt(planID: String, name: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Your AI wrote \(oneLine(name, max: 40))"
        content.body = "Open to put it on your Watch."
        content.sound = .default
        content.categoryIdentifier = planCategory
        content.threadIdentifier = "healthaccess.plan"
        content.userInfo = ["plan_id": planID]
        let request = UNNotificationRequest(identifier: "plan-\(planID)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Automatic mode: "S27 is on your Watch" with the day and time, or why it could not get there.
    static func postPlanScheduled(planID: String, name: String, at date: Date) async {
        await post(planID: planID, title: "\(oneLine(name, max: 40)) is on your Watch", body: "Scheduled for \(Format.dayTime(date)). Workout app → Scheduled.")
    }

    static func postPlanFailed(planID: String, name: String, error: String) async {
        await post(planID: planID, title: "Could not put \(oneLine(name, max: 40)) on your Watch", body: oneLine(error, max: 200))
    }

    private static func post(planID: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = planCategory
        content.threadIdentifier = "healthaccess.plan"
        content.userInfo = ["plan_id": planID]
        let request = UNNotificationRequest(identifier: "plan-\(planID)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func clearPlanPrompt(planID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["plan-\(planID)"])
    }

    /// Rating prompts posted by builds before 0.3.1 are taken down once.
    static func clearLegacyRatingPrompts() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix("rate-") }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}
