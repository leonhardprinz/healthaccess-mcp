import UIKit
import UserNotifications

/// Launch-time registration has to happen before the app finishes launching, including launches by HealthKit's observer
/// and BGTaskScheduler while the app is closed. A SwiftUI `.task` on a view is too late for those.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppSettings.migrateLegacyKeys()
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
        Notifier.clearLegacyRatingPrompts()
        BackgroundRefresh.register()
        AppModel.shared.bootstrap(launchedInBackground: application.applicationState == .background)
        Task { await AppModel.shared.appDidLaunch() }
        return true
    }

    /// A plan notification opens the app on the Import tab.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let planID = response.notification.request.content.userInfo["plan_id"] as? String {
            AppModel.shared.log("opened from the notification for plan \(planID)", .ui)
            AppModel.shared.selectedTab = .plans
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
