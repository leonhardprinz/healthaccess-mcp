import Foundation
import UIKit

/// Cloud upload: the app uploads the folder to Google Drive, OneDrive or Dropbox itself, because the folder
/// picker cannot reach them, and brings back the plans an AI left there.
extension AppModel {
    func requestCloudConnect(_ kind: CloudKind) {
        let reach = kind.folderOnly
            ? "The app can reach only that one folder there."
            : "\(kind.name) has no permission for one folder only. The sign-in covers your whole \(kind.name), but the app uses only its own folder."
        confirmation = Confirmation(
            title: "Upload a copy to \(kind.name)",
            detail: "You sign in on \(kind.name)'s own page. The app then makes a new folder, Health Access, \(kind.newFolderWhere). You can move it there later. After every sync, this phone uploads the files of your Health data folder straight into it. Nothing goes to us. \(reach)",
            confirmTitle: "Sign in") { [weak self] in
                await self?.connectCloud(kind, fields: nil)
            }
    }

    /// A WebDAV server or an S3 storage: what the user typed is tried first, then kept in the keychain.
    func requestCloudConnect(_ kind: CloudKind, fields: [String: String]) {
        confirmation = Confirmation(
            title: "Upload a copy to your \(kind.name)",
            detail: (kind == .s3 ? "The app puts the files under the folder you set in your bucket." : "The app makes a new folder, Health Access, \(kind.newFolderWhere).")
                + " After every sync, this phone uploads the files of your Health data folder straight there. Nothing goes to us. The password or key stays in this phone's keychain.",
            confirmTitle: "Connect") { [weak self] in
                await self?.connectCloud(kind, fields: fields)
            }
    }

    private func connectCloud(_ kind: CloudKind, fields: [String: String]?) async {
        let key = "cloud:\(kind.rawValue)"
        do {
            if let fields { try await cloud.connect(kind, fields: fields) } else { try await cloud.connect(kind) }
            UserDefaults.standard.removeObject(forKey: Self.expiredNoticeKey(kind))
            NetworkLedger.shared.record(host: cloud.host(kind), event: "signed in")
            log("\(kind.name) connected", .cloud)
            results[key] = ActionResult(kind: .done, text: "Connected. The first upload has started.", at: Date())
            kickCloud()
        } catch CloudError.cancelled {
            results[key] = nil
        } catch {
            log("\(kind.name) sign-in failed: \(error.localizedDescription)", .cloud)
            results[key] = ActionResult(kind: .failed, text: error.localizedDescription, at: Date())
        }
    }

    func requestCloudDisconnect(_ kind: CloudKind) {
        confirmation = Confirmation(
            title: "Disconnect \(kind.name)",
            detail: "The upload stops, and the app removes the sign-in from this phone. The files already in your \(kind.name) stay there until you delete them there.",
            confirmTitle: "Disconnect") { [weak self] in
                guard let self else { return }
                self.cloudTask?.cancel()
                self.cloud.disconnect(kind)
                self.log("\(kind.name) disconnected", .cloud)
                self.results["cloud:\(kind.rawValue)"] = ActionResult(kind: .done, text: "Disconnected. Your files in \(kind.name) are still there.", at: Date())
            }
    }

    /// A drive that is named but not ready: one tap, one confirmation, one event to the developer.
    func requestDriveInterest(_ kind: CloudKind) {
        let key = "interest:\(kind.rawValue)"
        guard let config = Telemetry.shared.config, !DriveInterest.wasSent(kind) else { return }
        let host = Telemetry.shared.hostName ?? "PostHog"
        confirmation = Confirmation(
            title: "Ask for \(kind.name)",
            detail: "This sends one message to \(host). It says that someone wants \(kind.name), with the app version and a random install id. It has nothing about you and no health data. You find it under What left this phone.",
            confirmTitle: "Send") { [weak self] in
                guard let self else { return }
                guard let request = DriveInterest.request(host: config.host, token: config.token, installID: self.settings.installID, drive: kind,
                                                          version: HealthAccessJSON.appVersion, build: HealthAccessJSON.appBuild),
                      await DriveInterest.send(request) else {
                    self.results[key] = ActionResult(kind: .failed, text: "Could not send it. Try again when you are online.", at: Date())
                    return
                }
                UserDefaults.standard.set(true, forKey: DriveInterest.key(kind))
                NetworkLedger.shared.record(host: host, event: "\(DriveInterest.event) (\(kind.rawValue))")
                self.log("asked for \(kind.name)", .cloud)
                self.results[key] = ActionResult(kind: .done, text: "Sent. Thank you, that helps to decide what comes next.", at: Date())
            }
    }

    /// Starts an upload run in the front, where it may take as long as it needs. Does nothing while one runs.
    func kickCloud() {
        guard cloudTask == nil, !cloud.connected.isEmpty, folder != nil else { return }
        cloudTask = Task { [weak self] in
            await self?.runCloud(.full, deadline: nil)
            self?.cloudTask = nil
        }
    }

    /// After a sync. Woken in the background the app has seconds, so the upload gets a deadline and is awaited
    /// before iOS is told the wake is done; in the front it runs on its own.
    func cloudAfterSync() async {
        guard !cloud.connected.isEmpty else { return }
        if UIApplication.shared.applicationState == .background {
            // Leave iOS a margin: an app that overruns its background time is woken less often afterwards.
            let left = UIApplication.shared.backgroundTimeRemaining
            await runCloud(.full, deadline: Date().addingTimeInterval(max(3, min(15, left - 8))))
        } else {
            kickCloud()
        }
    }

    /// Runs every connected drive, one after the other. New plans from a drive are scanned and, with Automatic on,
    /// put on the Watch like any other plan.
    func runCloud(_ mode: CloudMirror.Mode, deadline: Date?) async {
        guard let folder else { return }
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "cloud") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        var pulled = 0
        for kind in cloud.connected {
            guard let result = await cloud.run(kind, folder: folder, mode: mode, deadline: deadline) else { continue }
            switch result {
            case .success(let summary):
                pulled += summary.pulled
                if summary.uploaded + summary.pulled + summary.removed + summary.failed > 0 {
                    var parts: [String] = []
                    if summary.uploaded > 0 { parts.append("\(summary.uploaded) file\(summary.uploaded == 1 ? "" : "s") uploaded") }
                    if summary.pulled > 0 { parts.append("\(summary.pulled) plan\(summary.pulled == 1 ? "" : "s") received") }
                    if summary.removed > 0 { parts.append("\(summary.removed) removed") }
                    if summary.failed > 0 { parts.append("\(summary.failed) failed") }
                    if summary.remaining > 0 { parts.append("\(summary.remaining) waiting") }
                    let line = parts.joined(separator: ", ")
                    NetworkLedger.shared.record(host: cloud.host(kind), event: line)
                    log("\(kind.name): \(line)", .cloud)
                    if let failure = summary.firstFailure { log("\(kind.name): \(failure)", .error) }
                }
            case .failure(let error):
                if !(error is CancellationError) { log("\(kind.name): \(error.localizedDescription)", .cloud) }
                if (error as? CloudError) == .signInExpired { await noticeExpiredSignIn(kind) }
            }
        }
        // What did not fit goes on when iOS has time for it, also with the app closed.
        if cloud.waiting > 0 { CloudBackground.schedule() }
        if pulled > 0 {
            rescanPlans()
            await autoPutOnWatchIfOn()
        }
    }

    static func expiredNoticeKey(_ kind: CloudKind) -> String { AppSettings.key("cloud.expiredNoticed.\(kind.rawValue)") }

    /// A sign-in that ran out stops the upload without a sound. Say it once, where the user will see it.
    private func noticeExpiredSignIn(_ kind: CloudKind) async {
        let key = Self.expiredNoticeKey(kind)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if UIApplication.shared.applicationState != .active { await Notifier.postCloudSignIn(drive: kind.name) }
    }
}

import BackgroundTasks

/// The first upload of a long history takes longer than a wake in the background lasts. iOS gives an app minutes
/// for a processing task when the phone is idle; what was left over goes up then, with the app closed.
enum CloudBackground {
    static let identifier = "com.healthaccessmcp.app.cloud"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let completion = OneShot { task.setTaskCompleted(success: $0) }
            let work = Task { @MainActor in
                AppModel.shared.log("cloud upload continues in the background", .cloud)
                await AppModel.shared.runCloud(.full, deadline: nil)
                completion.fire(AppModel.shared.cloud.waiting == 0)
            }
            task.expirationHandler = {
                work.cancel()
                completion.fire(false)
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
