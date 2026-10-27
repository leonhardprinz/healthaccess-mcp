import BackgroundTasks
import Foundation

/// BGAppRefreshTask fallback for when HealthKit's observer did not wake us. Identifier is declared in Info.plist.
enum BackgroundRefresh {
    static let identifier = "com.healthaccessmcp.app.export"
    static let interval: TimeInterval = 3 * 3600

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let completion = OneShot { task.setTaskCompleted(success: $0) }
        let work = Task { @MainActor in
            let ok = await AppModel.shared.backgroundRefresh()
            schedule()
            completion.fire(ok)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in AppModel.shared.log("bg refresh expired before finishing", .refresh) }
            completion.fire(false)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Task { @MainActor in AppModel.shared.log("bg refresh submit failed: \(error.localizedDescription)", .error) }
        }
    }
}

/// Calls its action at most once (BGTask completion must not be reported twice).
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let action: (Bool) -> Void

    init(_ action: @escaping (Bool) -> Void) { self.action = action }

    func fire(_ ok: Bool) {
        lock.lock()
        let already = done
        done = true
        lock.unlock()
        if !already { action(ok) }
    }
}
