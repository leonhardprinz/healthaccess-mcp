import Foundation
import HealthKit
import Observation
import StoreKit
import SwiftUI
import UIKit
import UserNotifications
import WorkoutKit

/// The one object the UI talks to. Owns the folder, the sync runs, plans, the briefing and the log.
/// Every user action goes through a `Confirmation` (one sentence, Confirm/Cancel), then shows an `ActionResult`
/// in the row it came from, with Undo for 10 seconds where undoing is possible.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings.shared
    /// The support card on the Export tab and Restore purchases in Settings.
    let support = SupportStore(settings: AppSettings.shared)
    @ObservationIgnored private let health = HealthService.shared

    // MARK: folder and files
    var folder: FolderStore?
    var folderStale = false
    var index: IndexDoc?
    var indexScan: IndexBuilder.Scan?
    /// workout id → `effort_source`, from the last scan of the files.
    var effortSources: [String: String] = [:]
    var dayFiles = 0
    var plans: [PlanItem] = []
    var clients: [ClientInfo] = []
    var logLines: [String] = []

    // MARK: state
    var isSyncing = false
    var syncError: String?
    var lastError: String?
    var healthStatus = HealthStatus.notRequested
    var notificationStatus = UNAuthorizationStatus.notDetermined
    var workoutKitStatus = "unknown"
    /// Set after a setup-message copy; shows "Waiting for your AI to connect…" until a client file appears.
    var waitingForClient = false

    // MARK: presentation
    enum Tab: Hashable { case export, plans, settings }
    /// Export (Home) or Plans. A plan notification switches to Plans.
    var selectedTab = Tab.export
    var confirmation: Confirmation?
    var shareItems: ShareItems?
    var previewing: PreviewSession?
    var showPreview = false
    /// Per row: what the last confirmed action did ("On your Watch for Sat 26 Oct 10:00. Workout app → Scheduled.").
    var results: [String: ActionResult] = [:]
    var undo: UndoToken?

    @ObservationIgnored private var launched = false
    @ObservationIgnored private var rerunRequested: Trigger?
    @ObservationIgnored private var followUp: (@MainActor () -> Void)?
    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private var autoRunning = false
    /// When plans/ was last read.
    var lastPlanCheck: Date?

    enum HealthStatus { case unavailable, notRequested, requested }

    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let confirmTitle: String
        let action: @MainActor () async -> Void
    }

    struct ActionResult: Equatable {
        enum Kind { case done, failed }
        let kind: Kind
        let text: String
        let at: Date
    }

    struct UndoToken {
        let key: String
        let until: Date
        let perform: @MainActor () async -> Void
    }

    struct ShareItems: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    struct PreviewSession {
        let item: PlanItem
        let plan: WorkoutPlan
    }

    /// One day file, as text for the Days screen.
    struct DaySummary: Identifiable, Hashable {
        let id: String      // yyyy-MM-dd
        let line: String
        let groups: [String]
    }

    /// done: all written, nothing to do (green check). working: a sync runs. waiting: iOS has to unlock first.
    /// failed: the last sync broke (Try again). needs: something only you can fix (orange, with its one button).
    enum StatusKind { case done, working, waiting, failed, needs }
    enum StatusAction { case pickFolder, allowHealth, allowNotifications, openSystemSettings, syncNow }

    struct StatusLine {
        let kind: StatusKind
        let title: String
        let detail: String
        var action: (title: String, kind: StatusAction)? = nil
    }

    enum Trigger: String {
        case manual, observer, bgtask, foreground
        var tag: LogTag {
            switch self {
            case .manual, .foreground: return .sync
            case .observer: return .observer
            case .bgtask: return .refresh
            }
        }
        var label: String {
            switch self {
            case .manual: return "pull"
            case .observer: return "wake"
            case .bgtask: return "refresh"
            case .foreground: return "open"
            }
        }
    }

    private init() {}

    // MARK: - derived

    var sessionCount: Int { index?.workouts.count ?? 0 }
    var usageStatisticsAvailable: Bool { Telemetry.shared.isAvailable }
    var usageStatisticsHost: String { Telemetry.shared.hostName ?? "PostHog" }

    /// "14 files · 13 listed · 1 duplicate hidden by the dedupe rule"
    var sessionFilesLine: String {
        guard let scan = indexScan else { return "\(sessionCount) listed" }
        let files = scan.entries.count + scan.dropped.count + scan.skipped.count
        var parts = ["\(files) file\(files == 1 ? "" : "s")", "\(scan.entries.count) listed"]
        if !scan.dropped.isEmpty { parts.append("\(scan.dropped.count) duplicate\(scan.dropped.count == 1 ? "" : "s") hidden by the dedupe rule") }
        if !scan.skipped.isEmpty { parts.append("\(scan.skipped.count) unreadable") }
        return parts.joined(separator: " · ")
    }

    /// The rows a human has to act on: plans without a status (or whose last attempt failed), plus the rows that just
    /// collapsed into a result during this visit.
    var needsYou: [PlanItem] {
        plans.filter { $0.state == .pending || $0.state == .failed || results["plan:\($0.id)"] != nil }
    }

    /// Plans on the Watch whose time is still ahead (or less than two hours ago).
    var plansOnWatch: [PlanItem] {
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        return plans.filter { $0.state == .scheduled && ($0.status?.scheduledFor ?? .distantFuture) >= cutoff && results["plan:\($0.id)"] == nil }
            .sorted { ($0.status?.scheduledFor ?? .distantFuture) < ($1.status?.scheduledFor ?? .distantFuture) }
    }

    /// Plans whose time has passed, and plans removed from the Watch.
    var plansEarlier: [PlanItem] {
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        return plans.filter {
            results["plan:\($0.id)"] == nil &&
            (($0.state == .scheduled && ($0.status?.scheduledFor ?? .distantFuture) < cutoff) || $0.state == .cancelled)
        }
    }

    var plansInvalid: [PlanItem] { plans.filter { $0.state == .invalid } }

    /// The most recently seen AI, when one was seen within 7 days.
    var connectedClient: ClientInfo? {
        clients.first { $0.isConnected() }
    }

    var status: StatusLine {
        if folder == nil || folderStale {
            return StatusLine(kind: .needs, title: "Folder missing",
                              detail: folderStale ? "The saved folder moved or is gone. Pick it again." : "Pick a folder your AI can reach from your computer.",
                              action: ("Pick folder", .pickFolder))
        }
        if healthStatus == .notRequested {
            return StatusLine(kind: .needs, title: "Needs Health access", detail: "Read only. You choose the types.", action: ("Allow Health access", .allowHealth))
        }
        if healthStatus == .unavailable {
            return StatusLine(kind: .failed, title: "No Health on this device", detail: "Health Access needs an iPhone with the Health app.")
        }
        if notificationStatus == .notDetermined {
            return StatusLine(kind: .needs, title: "Notifications off", detail: "Needed for one thing: telling you when your AI wrote a plan.", action: ("Allow notifications", .allowNotifications))
        }
        if notificationStatus == .denied {
            return StatusLine(kind: .needs, title: "Notifications off", detail: "Turn them on in Settings to hear when your AI wrote a plan.", action: ("Open Settings", .openSystemSettings))
        }
        if isSyncing {
            return StatusLine(kind: .working,
                              title: settings.lastSync == nil ? "Writing your last \(settings.backfillDays) days" : "Syncing",
                              detail: "Reading Health, writing files.")
        }
        if settings.deferredSync {
            return StatusLine(kind: .waiting, title: "Waiting for unlock", detail: "Health is locked. Files are written when you unlock.")
        }
        if let syncError {
            return StatusLine(kind: .failed, title: "Sync failed", detail: syncError, action: ("Try again", .syncNow))
        }
        return StatusLine(kind: .done, title: "Up to date",
                          detail: "\(sessionCount) workout\(sessionCount == 1 ? "" : "s") · synced \(settings.lastSync.map { Format.ago($0) } ?? "never")")
    }

    private var lastCheckLine: String {
        settings.lastSync.map { "last check \(Format.ago($0))" } ?? "no check yet"
    }

    // MARK: - lifecycle

    /// Synchronous part of launch: restore the folder and register the observer query before anything else happens.
    func bootstrap(launchedInBackground: Bool) {
        restoreFolder()
        log("launch v\(HealthAccessJSON.appVersion) (\(HealthAccessJSON.appBuild))\(launchedInBackground ? " while closed" : "")", .launch)
        unlockObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let model = AppModel.shared
                guard model.settings.deferredSync else { return }
                model.log("phone unlocked, writing the files now", .observer)
                await model.runSync(trigger: .observer)
            }
        }
        guard HealthService.isAvailable else { return }
        health.startObserving { [weak self] error in
            await self?.observerFired(error)
        }
    }

    func appDidLaunch() async {
        guard !launched else { return }
        launched = true
        logLines = await DiskLog.shared.load()
        if settings.telemetryEnabled {
            Telemetry.shared.start(installID: settings.installID)
            Telemetry.shared.capture(.appOpened)
        }
        support.start()
        await enableBackgroundDelivery()
        BackgroundRefresh.schedule()
        reloadIndex()
        rescanPlans()
        rescanClients()
        await refreshStatuses()
        await autoPutOnWatchIfOn()
        await syncIfDue(trigger: .foreground)
    }

    func scenePhaseChanged(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            guard launched else { return }
            reloadIndex()
            rescanPlans()
            rescanClients()
            await refreshStatuses()
            await autoPutOnWatchIfOn()
            await syncIfDue(trigger: .foreground)
        case .background:
            results = [:]
            undo = nil
            BackgroundRefresh.schedule()
            Telemetry.shared.flush()
        default:
            break
        }
    }

    /// Runs a sync when the app comes to the front after a deferred wake or when the last check is older than 15 minutes.
    private func syncIfDue(trigger: Trigger) async {
        guard settings.onboardingDone, folder != nil, settings.healthAuthRequested, !isSyncing else { return }
        let stale = settings.lastSync.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
        guard settings.deferredSync || stale else { return }
        await runSync(trigger: trigger)
    }

    private func observerFired(_ error: Error?) async {
        if let error {
            log("observer error: \(error.localizedDescription)", .observer)
            return
        }
        settings.lastObserverFire = Date()
        let state = UIApplication.shared.applicationState == .background ? "while closed" : "in front"
        log("observer fired (\(state))", .observer)
        await runSync(trigger: .observer)
    }

    func backgroundRefresh() async -> Bool {
        log("refresh task fired", .refresh)
        return await runSync(trigger: .bgtask)
    }

    // MARK: - folder

    private func restoreFolder() {
        guard let restored = FolderStore.restore() else { folder = nil; return }
        folder = restored.store
        folderStale = restored.stale
        if restored.stale { log("folder bookmark is stale, pick the folder again in Settings", .folder) }
    }

    /// The folder line after a relaunch, when this launch has no fresh result: "Folder: … Set Sat 25 Oct 11:21."
    var storedFolderResult: ActionResult? {
        guard let folder else { return nil }
        let when = settings.folderSetAt.map { " Set \(Format.dayTime($0))." } ?? ""
        return ActionResult(kind: .done, text: "Folder: \(folder.displayNameWithProvider).\(when)", at: settings.folderSetAt ?? .distantPast)
    }

    /// Picker result → one sentence → Confirm. Nothing is written before the user confirms.
    func requestFolder(_ url: URL, key: String = "folder") {
        let name = url.lastPathComponent
        let old = folder == nil ? "" : " The old folder is left as it is."
        confirmation = Confirmation(
            title: "Use \(name) as your Health data folder",
            detail: "Your workouts and daily health data are written there, and your AI writes workout plans into its plans folder.\(old)",
            confirmTitle: "Use folder") { [weak self] in
                guard let self else { return }
                if self.setFolder(url) {
                    self.results[key] = ActionResult(kind: .done, text: "Folder: \(self.folder?.displayNameWithProvider ?? name). Set \(Format.clock(Date())).", at: Date())
                } else {
                    self.results[key] = ActionResult(kind: .failed, text: self.lastError ?? "Could not keep the folder.", at: Date())
                }
            }
    }

    @discardableResult
    private func setFolder(_ url: URL) -> Bool {
        do {
            let store = try FolderStore.save(url)
            folder = store
            folderStale = false
            settings.folderSetAt = Date()
            syncError = nil
            settings.lastCatalogAt = nil
            log("folder set: \(store.displayPath)", .folder)
            reloadIndex()
            rescanPlans()
            rescanClients()
            return true
        } catch {
            fail("folder bookmark failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens the folder in the Files app (the `shareddocuments` scheme is the Files app's own door).
    func openInFiles(subfolder: String? = nil) {
        guard let folder else { return }
        var target = folder.root
        if let subfolder {
            let sub = folder.root.appendingPathComponent(subfolder, isDirectory: true)
            if FileManager.default.fileExists(atPath: sub.path) { target = sub }
        }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        let filesApp = URL(string: "shareddocuments://")
        guard let url = components?.url else {
            if let filesApp { UIApplication.shared.open(filesApp) }
            return
        }
        log("open in Files", .ui)
        UIApplication.shared.open(url) { ok in
            if !ok, let filesApp { UIApplication.shared.open(filesApp) }
        }
    }

    // MARK: - permissions and status

    func requestHealthAccess() async {
        guard HealthService.isAvailable else {
            healthStatus = .unavailable
            return
        }
        do {
            try await health.requestAuthorization(includeReproductive: settings.includeReproductive)
            settings.healthAuthRequested = true
            log("health access requested for \(health.readTypes(includeReproductive: settings.includeReproductive).count) types", .health)
            await enableBackgroundDelivery()
        } catch {
            fail("health access failed: \(error.localizedDescription)")
        }
        await refreshStatuses()
    }

    private func enableBackgroundDelivery() async {
        guard HealthService.isAvailable else { return }
        do {
            try await health.enableBackgroundDelivery()
            settings.backgroundDeliveryEnabled = true
            log("wake on new workouts enabled", .health)
        } catch {
            settings.backgroundDeliveryEnabled = false
            fail("wake on new workouts failed: \(error.localizedDescription)")
        }
    }

    func requestNotifications() async {
        let granted = await Notifier.requestAuthorization()
        settings.notificationsRequested = true
        log("notifications \(granted ? "allowed" : "denied")", .ui)
        await refreshStatuses()
    }

    func refreshStatuses() async {
        if !HealthService.isAvailable {
            healthStatus = .unavailable
        } else {
            healthStatus = settings.healthAuthRequested ? .requested : .notRequested
        }
        notificationStatus = await Notifier.authorizationStatus()
        if PlanInstaller.isSupported {
            workoutKitStatus = await PlanInstaller.currentAuthorizationDescription()
        } else {
            workoutKitStatus = "unsupported (no paired Watch?)"
        }
    }

    // MARK: - sync

    @discardableResult
    func runSync(trigger: Trigger) async -> Bool {
        let tag = trigger.tag
        if isSyncing {
            rerunRequested = trigger
            log("sync already running, queued another run", tag)
            return true
        }
        isSyncing = true
        defer { isSyncing = false }
        let started = Date()
        if trigger == .bgtask { settings.lastBGTaskRun = started }
        guard let folder else {
            log("sync skipped: no folder chosen", tag)
            return false
        }
        log("sync start (\(trigger.label))", tag)
        var newCount = 0
        do {
            let anchor = settings.workoutAnchor.flatMap(HealthService.unarchive)
            if anchor == nil && settings.anchorStart == nil {
                settings.anchorStart = Calendar.current.date(byAdding: .day, value: -settings.backfillDays, to: started)
            }
            let delta = try await health.newWorkouts(anchor: anchor, since: settings.anchorStart)
            if delta.deleted > 0 { log("\(delta.deleted) workout(s) deleted in Health; files are kept", tag) }
            log("\(delta.added.count) workout(s) new since last check", tag)

            rescanPlans()
            await autoPutOnWatchIfOn()
            let lookup = PlanInstaller.installed(from: plans)
            let exporter = WorkoutExporter(health: health, healthaccessVersion: HealthAccessJSON.appVersion)
            let existing = try folder.list("workouts")

            for workout in delta.added.sorted(by: { $0.startDate < $1.startDate }) {
                let uuid8 = String(workout.uuid.uuidString.prefix(8))
                if existing.contains(where: { $0.hasSuffix("_\(uuid8).json") }) { continue } // never overwrite: ratings live there
                let built = try await exporter.build(for: workout, plans: lookup)
                var doc = built.doc
                let name = WorkoutExporter.fileName(for: doc)
                if let route = built.route {
                    let routeFile = "workouts/\(WorkoutExporter.routeFileName(for: name))"
                    var out = try JSONSerialization.data(withJSONObject: route, options: [.withoutEscapingSlashes])
                    out.append(0x0A)
                    try folder.write(out, to: routeFile)
                    doc.routeFile = routeFile
                }
                try folder.write(try HealthAccessJSON.encode(doc), to: "workouts/\(name)")
                newCount += 1
                log("wrote \(name)\(doc.effort.map { ", Apple effort \($0)" } ?? "")\(built.route == nil ? "" : " + route")", tag)
                if started.timeIntervalSince(workout.endDate) < WorkoutExporter.recoveryWindow {
                    var pending = settings.recoveryPending
                    pending[doc.id] = workout.endDate
                    settings.recoveryPending = pending
                }
            }
            settings.workoutAnchor = HealthService.archive(delta.anchor)

            await patchLateHeartRate(exporter: exporter, folder: folder, tag: tag)
            await recheckAppleEffort(folder: folder, tag: tag)

            // The catalog first when it is due, so the day files only query types that have data.
            if settings.lastCatalogAt.map({ started.timeIntervalSince($0) > 24 * 3600 }) ?? true {
                await writeCatalog(folder: folder, tag: tag)
            }
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: started) ?? started
            let vitalsWritten = await VitalsExporter(health: health).export(days: [yesterday, started], folder: folder) { [weak self] message in
                await self?.log(message, .vitals)
            }
            let daysWritten = await dayExporter(folder: folder).export(days: [yesterday, started], folder: folder) { [weak self] message in
                await self?.log(message, .vitals)
            }
            if (try? ProfileExporter.export(health: health, folder: folder)) == true { log("profile.json written", tag) }
            let ecg = await ECGExporter(health: health).export(folder: folder, includeVoltage: settings.includeECGVoltage) { [weak self] message in
                await self?.log(message, .error)
            }
            if ecg.written > 0 { log("ecg: \(ecg.written) file(s), \(ecg.voltages) voltage file(s)", tag) }

            rebuildIndex(folder, tag: tag)
            rescanClients()

            settings.exportedTotal += newCount
            let ms = Int(started.distance(to: Date()) * 1000)
            settings.lastSync = Date()
            settings.deferredSync = false
            syncError = nil
            settings.lastSyncSummary = "\(newCount) new session\(newCount == 1 ? "" : "s"), \(daysWritten) day file\(daysWritten == 1 ? "" : "s"), \(vitalsWritten) vitals · \(trigger.label) · \(ms) ms"
            log("sync done: \(settings.lastSyncSummary)", tag)
            Telemetry.shared.capture(.exportCompleted(workoutCount: newCount, durationMs: ms, trigger: trigger.rawValue))
            rescanPlans()
            writeBriefing()
            BackgroundRefresh.schedule()
            if let queued = rerunRequested {
                rerunRequested = nil
                Task { await self.runSync(trigger: queued) }
            }
            return true
        } catch {
            let ns = error as NSError
            if ns.domain == HKError.errorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue {
                settings.deferredSync = true
                log("Health is locked; will write files when the phone is unlocked", tag)
                return false
            }
            syncError = error.localizedDescription
            fail("sync failed (\(trigger.label)): \(error.localizedDescription) [\(ns.domain) \(ns.code)]")
            Telemetry.shared.capture(.exportFailed(domain: ns.domain, code: ns.code))
            return false
        }
    }

    private func dayExporter(folder: FolderStore) -> DayExporter {
        DayExporter(health: health, typesWithData: CatalogBuilder.typesWithData(folder: folder), includeReproductive: settings.includeReproductive)
    }

    /// catalog.json: every type the SDK knows, with 90-day counts. Once a day, or on request.
    private func writeCatalog(folder: FolderStore, tag: LogTag) async {
        let started = Date()
        let catalog = await CatalogBuilder(health: health).build(includeReproductive: settings.includeReproductive, appVersion: HealthAccessJSON.appVersion)
        do {
            try folder.write(try JSONBuilder.data(catalog), to: CatalogBuilder.file)
            settings.lastCatalogAt = Date()
            let ms = Int(started.distance(to: Date()) * 1000)
            log("catalog: \(CatalogBuilder.countWithData(catalog)) types with data of \((catalog["types"] as? JSONObject)?.count ?? 0) · \(ms) ms", tag)
        } catch {
            log("catalog failed: \(error.localizedDescription)", .error)
        }
    }

    /// Workouts written within 2½ minutes of their end miss the recovery samples; fill them in once they exist.
    private func patchLateHeartRate(exporter: WorkoutExporter, folder: FolderStore, tag: LogTag) async {
        var pending = settings.recoveryPending
        guard !pending.isEmpty else { return }
        let now = Date()
        let due = pending.filter { now.timeIntervalSince($0.value) >= WorkoutExporter.recoveryWindow }
        guard !due.isEmpty else { return }
        do {
            let workouts = try await health.workouts(ids: Set(due.keys.compactMap(UUID.init(uuidString:))))
            let names = try folder.list("workouts")
            for workout in workouts {
                let id = workout.uuid.uuidString
                let uuid8 = String(id.prefix(8))
                guard let name = names.first(where: { $0.hasSuffix("_\(uuid8).json") && !$0.hasSuffix(".route.json") }) else {
                    pending[id] = nil
                    continue
                }
                let late = try await exporter.lateHeartRate(for: workout)
                try RatingStore.saveLateHeartRate(recovery: late.recovery, maxHr: late.maxHr, file: "workouts/\(name)", folder: folder)
                log("patched recovery HR into \(name)", tag)
                pending[id] = nil
            }
            for (id, end) in pending where now.timeIntervalSince(end) > 24 * 3600 { pending[id] = nil }
            settings.recoveryPending = pending
        } catch {
            log("recovery HR patch failed: \(error.localizedDescription)", .error)
        }
    }

    /// The athlete rates on the Watch, often minutes after the session ends and after the observer already woke us.
    /// Re-read Apple's Effort samples for the sessions of the last 3 days and patch the files when they changed.
    private func recheckAppleEffort(folder: FolderStore, tag: LogTag) async {
        guard #available(iOS 18.0, *), let entries = index?.workouts else { return }
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        let recent = entries.filter { $0.start > cutoff }
        guard !recent.isEmpty else { return }
        do {
            let workouts = try await health.workouts(ids: Set(recent.compactMap { UUID(uuidString: $0.id) }))
            for workout in workouts {
                guard let entry = recent.first(where: { $0.id == workout.uuid.uuidString }) else { continue }
                let scores = try await health.effortScores(for: workout)
                guard scores.effort != nil || scores.estimated != nil else { continue }
                if try RatingStore.applyAppleEffort(effort: scores.effort, estimated: scores.estimated, file: entry.file, folder: folder) {
                    log("Apple effort \(scores.effort.map(String.init) ?? "estimate") for \(fileName(entry.file))", tag)
                }
            }
        } catch {
            log("effort check failed: \(error.localizedDescription)", .error)
        }
    }

    func requestResync() {
        let days = settings.backfillDays
        confirmation = Confirmation(
            title: "Write the last \(days) days again",
            detail: "Every session since then is read from Health once more. Files that already exist are kept, so ratings survive.",
            confirmTitle: "Write again") { [weak self] in
                guard let self else { return }
                self.settings.resetAnchor()
                self.log("check anchor reset; reading the last \(days) days again (existing files are kept)", .sync)
                await self.runSync(trigger: .manual)
                self.results["resync"] = ActionResult(kind: self.syncError == nil ? .done : .failed,
                                                      text: self.syncError.map { "Could not write files: \($0)" } ?? "Done. \(self.settings.lastSyncSummary).", at: Date())
            }
    }

    func requestDaysBackfill(days: Int = 30) {
        confirmation = Confirmation(
            title: "Write the last \(days) days",
            detail: "One day file per day in days/ (and the vitals file of the last release). Days without values get no file; days that already match are left alone.",
            confirmTitle: "Write days") { [weak self] in
                guard let self, let folder = self.folder else { return }
                let today = Date()
                let dates = (0..<days).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
                let vitals = await VitalsExporter(health: self.health).export(days: dates, folder: folder) { [weak self] message in
                    await self?.log(message, .vitals)
                }
                let written = await self.dayExporter(folder: folder).export(days: dates, folder: folder) { [weak self] message in
                    await self?.log(message, .vitals)
                }
                self.log("days: \(written) day file(s) and \(vitals) vitals file(s) written for the last \(days) days", .vitals)
                self.reloadIndex()
                self.writeBriefing()
                self.results["days"] = ActionResult(kind: .done, text: "\(written) day file\(written == 1 ? "" : "s") written. \(Format.clock(Date())).", at: Date())
            }
    }

    func requestCatalog() {
        confirmation = Confirmation(
            title: "Write the catalog again",
            detail: "Counts the last 90 days of every Health type this build knows (\(HealthTypes.all.count) plus the special ones) and writes catalog.json. Takes a moment.",
            confirmTitle: "Write catalog") { [weak self] in
                guard let self, let folder = self.folder else { return }
                await self.writeCatalog(folder: folder, tag: .sync)
                let count = CatalogBuilder.typesWithData(folder: folder)?.count ?? 0
                self.results["catalog"] = ActionResult(kind: .done, text: "catalog.json written: \(count) types with data. \(Format.clock(Date())).", at: Date())
            }
    }

    // MARK: - index, days, briefing

    func reloadIndex() {
        guard let folder else {
            index = nil
            dayFiles = 0
            return
        }
        do {
            index = try IndexBuilder.load(folder: folder)
        } catch {
            fail("index.json unreadable: \(error.localizedDescription)")
        }
        dayFiles = Self.countDayFiles(folder)
        Task.detached(priority: .utility) { [folder] in
            guard let scan = try? IndexBuilder.scan(folder: folder) else { return }
            await MainActor.run {
                let model = AppModel.shared
                model.effortSources = scan.effortSources
                model.indexScan = scan
            }
        }
    }

    private static func countDayFiles(_ folder: FolderStore) -> Int {
        let days = (try? folder.list("days").count) ?? 0
        return days > 0 ? days : ((try? folder.list("vitals").count) ?? 0)
    }

    private func rebuildIndex(_ folder: FolderStore, tag: LogTag = .sync) {
        do {
            let rebuilt = try IndexBuilder.rebuild(folder: folder)
            index = rebuilt.doc
            indexScan = rebuilt.scan
            effortSources = rebuilt.scan.effortSources
            dayFiles = Self.countDayFiles(folder)
            if !rebuilt.scan.skipped.isEmpty { log("index: \(rebuilt.scan.skipped.count) unreadable file(s) skipped", tag) }
            if !rebuilt.scan.dropped.isEmpty {
                log("index: \(rebuilt.scan.entries.count) sessions listed, \(rebuilt.scan.dropped.count) duplicate(s) hidden by the dedupe rule (files stay)", tag)
            }
        } catch {
            fail("index rebuild failed: \(error.localizedDescription)")
        }
    }

    /// briefing.md: after every sync and after every plan status change.
    func writeBriefing() {
        guard let folder else { return }
        do {
            try Briefing.write(folder: folder, entries: index?.workouts ?? [], effortSources: effortSources, plans: plans)
        } catch {
            log("briefing failed: \(error.localizedDescription)", .briefing)
        }
    }

    func loadWorkout(_ entry: IndexEntry) -> WorkoutDoc? {
        guard let folder else { return nil }
        do {
            guard let data = try folder.read(entry.file) else { throw HealthAccessError("file is missing") }
            return try HealthAccessJSON.decode(WorkoutDoc.self, from: data)
        } catch {
            fail("cannot read \(entry.file): \(error.localizedDescription)")
            return nil
        }
    }

    /// The day files as text, newest first; the vitals files of the last release when there are no day files yet.
    func loadDays() -> [DaySummary] {
        guard let folder else { return [] }
        if let names = try? folder.list("days"), !names.isEmpty {
            return names.sorted(by: >).compactMap { name -> DaySummary? in
                guard let data = try? folder.read("days/\(name)"), let object = try? JSONBuilder.object(data) else { return nil }
                return Self.summary(of: object, date: String(name.dropLast(".json".count)))
            }
        }
        return Briefing.loadVitals(folder: folder, days: 3650).reversed().map { v in
            var parts: [String] = []
            if let s = v.steps { parts.append("\(s) steps") }
            if let r = v.restingHr { parts.append("resting \(r) bpm") }
            if let h = v.hrvSdnnMs { parts.append(String(format: "HRV %.0f ms", h)) }
            if let s = v.sleepS { parts.append("sleep \(Format.hours(s))") }
            if let m = v.bodyMassKg { parts.append(String(format: "%.1f kg", m)) }
            return DaySummary(id: v.date, line: parts.isEmpty ? "no values" : parts.joined(separator: " · "), groups: ["vitals"])
        }
    }

    private static func summary(of object: JSONObject, date: String) -> DaySummary {
        let known = ["activity", "heart", "respiratory", "sleep", "body", "blood", "mobility", "hearing", "nutrition", "mind",
                     "symptoms", "cycle", "medications", "hygiene", "uv", "wheelchair", "audiogram", "vision"]
        let groups = known.filter { object[$0] != nil }
        var parts: [String] = []
        if let activity = object["activity"] as? JSONObject, let steps = activity["steps"] as? NSNumber { parts.append("\(steps.intValue) steps") }
        if let heart = object["heart"] as? JSONObject {
            if let r = heart["resting_hr"] as? NSNumber { parts.append("resting \(r.intValue) bpm") }
            if let h = heart["hrv_sdnn_ms"] as? NSNumber { parts.append(String(format: "HRV %.0f ms", h.doubleValue)) }
        }
        if let sleep = object["sleep"] as? JSONObject, let s = sleep["asleep_s"] as? NSNumber { parts.append("sleep \(Format.hours(s.intValue))") }
        if let body = object["body"] as? JSONObject, let m = body["mass_kg"] as? NSNumber { parts.append(String(format: "%.1f kg", m.doubleValue)) }
        var line = parts.joined(separator: " · ")
        if !groups.isEmpty { line += (line.isEmpty ? "" : " · ") + "groups: " + groups.joined(separator: ", ") }
        return DaySummary(id: date, line: line.isEmpty ? "no values" : line, groups: groups)
    }

    func shareSession(_ entry: IndexEntry) {
        guard let folder else { return }
        do {
            shareItems = ShareItems(items: [try folder.temporaryCopy(of: entry.file)])
        } catch {
            fail("cannot share \(entry.file): \(error.localizedDescription)")
        }
    }

    // MARK: - plans

    /// Plans come from `plans/` inside the chosen folder. Checked on launch, on return to the front, after each sync and
    /// on every wake; a plan that appears while the app is not in front gets a notification, once.
    func rescanPlans() {
        guard let folder else { plans = []; return }
        do {
            let items = try PlanInstaller.scan(folder: folder)
            var announced = settings.announcedPlanIDs
            let inFront = UIApplication.shared.applicationState == .active
            for item in items where !announced.contains(item.id) {
                announced.insert(item.id)
                switch item.state {
                case .pending:
                    log("plan found: \(item.name)", .plan)
                    if !inFront && !settings.autoPutOnWatch { Task { await Notifier.postPlanPrompt(planID: item.id, name: item.name) } }
                case .invalid:
                    log("plan \(item.id) is invalid: \(item.parseError ?? "unknown error")", .plan)
                default:
                    break
                }
            }
            if announced != settings.announcedPlanIDs { settings.announcedPlanIDs = announced }
            plans = items
            lastPlanCheck = Date()
        } catch {
            fail("plan scan failed: \(error.localizedDescription)")
        }
    }

    /// The MCP's handshake files: who connected, from where, when. Read on launch, on return to the front, after syncs.
    func rescanClients() {
        guard let folder else { clients = []; return }
        let before = clients.map(\.id)
        clients = ClientStore.scan(folder: folder)
        for client in clients where !before.contains(client.id) { log("AI client seen: \(client.name)", .ui) }
        if waitingForClient, connectedClient != nil { waitingForClient = false }
        announceClients()
    }

    /// `ai_connected` once per handshake id, only while usage statistics run. An id joins the announced set only when
    /// the event was sent, so switching statistics on later still counts a client that connected before.
    private func announceClients() {
        guard Telemetry.shared.isRunning else { return }
        var announced = settings.announcedClientIDs
        let fresh = clients.filter { $0.isConnected() && !announced.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for client in fresh {
            Telemetry.shared.capture(.aiConnected(client: .init(clientName: client.name)))
            announced.insert(client.id)
        }
        settings.announcedClientIDs = announced
    }

    /// When a plan goes onto the Watch: the plan's own `scheduled_for` while it is still ahead, else the next morning.
    struct PlanTiming {
        enum Source { case plan, noTime, passed }
        let date: Date
        let source: Source

        /// "For Wed 28 Oct 10:00, the time in the plan."
        var sentence: String {
            switch source {
            case .plan: return "For \(Format.dayTime(date)), the time in the plan."
            case .noTime: return "For \(Format.dayTime(date)), the next morning: the plan has no time."
            case .passed: return "For \(Format.dayTime(date)), the next morning: the plan's time has passed."
            }
        }
    }

    func planTiming(for doc: PlanDoc) -> PlanTiming {
        let now = Date()
        if let at = doc.scheduledFor, at > now.addingTimeInterval(60) { return PlanTiming(date: at, source: .plan) }
        let calendar = Calendar.current
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let morning = calendar.date(bySettingHour: settings.putOnWatchHour, minute: settings.putOnWatchMinute, second: 0, of: tomorrow) ?? tomorrow
        return PlanTiming(date: morning, source: doc.scheduledFor == nil ? .noTime : .passed)
    }

    func requestPutOnWatch(_ item: PlanItem) {
        guard let doc = item.doc else { return }
        let timing = planTiming(for: doc)
        confirmation = Confirmation(
            title: "Put \(doc.name) on your Watch for \(Format.dayTime(timing.date))",
            detail: "This schedules the workout in the Watch's Workout app, under Scheduled, and writes plans/\(item.id).status.json. \(timing.source == .plan ? "The time comes from the plan." : "The plan has no time ahead, so it goes to the next morning.")",
            confirmTitle: "Put on Watch") { [weak self] in
                await self?.putOnWatch(item, at: timing.date)
            }
    }

    /// Plans tab "Check now": read plans/ again, put new plans on the Watch when automatic is on, say what changed.
    func checkPlansNow() async {
        let before = Set(plans.map(\.id))
        rescanPlans()
        await autoPutOnWatchIfOn()
        let new = plans.filter { !before.contains($0.id) }.count
        let waiting = plans.filter { $0.state == .pending }.count
        var text = "Checked \(Format.clock(Date())). "
        text += new == 0 ? "No new plans." : "\(new) new plan\(new == 1 ? "" : "s")."
        if waiting > 0 && !settings.autoPutOnWatch { text += " \(waiting) waiting for Put on Watch." }
        results["plansCheck"] = ActionResult(kind: .done, text: text, at: Date())
        log("plans checked: \(new) new", .plan)
    }

    /// Plans tab switch. On needs a confirmation (and WorkoutKit permission); off takes effect at once.
    func requestAutoPutOnWatch(_ on: Bool) {
        guard on else {
            settings.autoPutOnWatch = false
            results["auto"] = ActionResult(kind: .done, text: "Off. New plans wait for your tap.", at: Date())
            log("automatic Put on Watch off", .plan)
            return
        }
        confirmation = Confirmation(
            title: "Put new plans on your Watch automatically",
            detail: "Every new plan your AI writes goes into the Watch's Workout app for the time in the plan, or the next morning at 10:00 when it has none. It happens the next time Health Access runs or iOS wakes it, usually within a few hours, and you get a notification for each one. Remove from Watch takes one off again. Plans already waiting are included.",
            confirmTitle: "Turn on") { [weak self] in
                guard let self else { return }
                let auth = await PlanInstaller.authorize()
                guard auth.authorized else {
                    self.results["auto"] = ActionResult(kind: .failed, text: "Not turned on: WorkoutKit permission is \(auth.description).", at: Date())
                    return
                }
                self.settings.autoPutOnWatch = true
                self.log("automatic Put on Watch on", .plan)
                self.results["auto"] = ActionResult(kind: .done, text: "On since \(Format.clock(Date())). New plans go onto your Watch by themselves.", at: Date())
                await self.autoPutOnWatchIfOn()
            }
    }

    /// Automatic mode: every pending plan goes onto the Watch at its time. Runs on launch, on return to the front and in
    /// every sync (observer wakes and background refresh included). Failed plans are left for a tap.
    func autoPutOnWatchIfOn() async {
        guard settings.autoPutOnWatch, !autoRunning, folder != nil else { return }
        autoRunning = true
        defer { autoRunning = false }
        let inFront = UIApplication.shared.applicationState == .active
        for item in plans where item.state == .pending {
            guard let doc = item.doc else { continue }
            let timing = planTiming(for: doc)
            let key = "plan:\(item.id)"
            if await scheduleDirect(item, at: timing.date) != nil {
                log("plan \(doc.name) put on the Watch automatically", .plan)
                Telemetry.shared.capture(.planPutOnWatch(method: "auto"))
                if inFront {
                    results[key] = ActionResult(kind: .done, text: "On your Watch for \(Format.dayTime(timing.date)), automatically.", at: Date())
                } else {
                    await Notifier.postPlanScheduled(planID: item.id, name: doc.name, at: timing.date)
                }
            } else if !inFront {
                await Notifier.postPlanFailed(planID: item.id, name: doc.name, error: lastError ?? "WorkoutKit refused it.")
            } else {
                results[key] = ActionResult(kind: .failed, text: lastError ?? "Could not put \(doc.name) on your Watch.", at: Date())
            }
        }
    }

    /// Takes a scheduled plan off the Watch and marks its status cancelled. The plan file stays; Put on Watch brings it back.
    func requestRemoveFromWatch(_ item: PlanItem) {
        guard let doc = item.doc, let status = item.status else { return }
        let when = status.scheduledFor.map { " for \(Format.dayTime($0))" } ?? ""
        confirmation = Confirmation(
            title: "Remove \(doc.name) from your Watch",
            detail: "This takes the workout\(when) out of the Watch's Workout app and marks plans/\(item.id).status.json as cancelled. The plan file stays; Put on Watch puts it back.",
            confirmTitle: "Remove") { [weak self] in
                guard let self, let folder = self.folder else { return }
                let key = "plan:\(item.id)"
                var removed = false
                if let id = status.workoutkitId { removed = await PlanInstaller.removeScheduled(id: id) }
                let cancelled = PlanStatus(planId: doc.id, state: "cancelled", at: Date(), error: nil, method: status.method,
                                           workoutkitId: status.workoutkitId, scheduledFor: status.scheduledFor)
                do {
                    try PlanInstaller.writeStatus(cancelled, for: item, folder: folder)
                    self.log("plan \(doc.name) removed from the Watch\(removed ? "" : " (it was no longer scheduled there)")", .plan)
                    self.results[key] = ActionResult(kind: .done, text: removed ? "Removed from your Watch." : "Marked cancelled. It was no longer scheduled on the Watch.", at: Date())
                } catch {
                    self.fail("status write failed: \(error.localizedDescription)")
                    self.results[key] = ActionResult(kind: .failed, text: error.localizedDescription, at: Date())
                }
                self.rescanPlans()
                self.writeBriefing()
            }
    }

    private func putOnWatch(_ item: PlanItem, at date: Date) async {
        guard let doc = item.doc else { return }
        let key = "plan:\(item.id)"
        Telemetry.shared.capture(.planPutOnWatch(method: "schedule"))
        guard let plan = await scheduleDirect(item, at: date) else {
            results[key] = ActionResult(kind: .failed, text: lastError ?? "Could not put \(doc.name) on your Watch.", at: Date())
            return
        }
        results[key] = ActionResult(kind: .done, text: "On your Watch for \(Format.dayTime(date)). Workout app → Scheduled.", at: Date())
        offerUndo(key: key) { [weak self] in
            guard let self else { return }
            await PlanInstaller.remove(plan, at: date)
            await self.undoStatus(item, key: key)
        }
    }

    /// Builds the WorkoutKit plan and schedules it on the Watch at `date`. Writes the status file either way.
    private func scheduleDirect(_ item: PlanItem, at date: Date) async -> WorkoutPlan? {
        guard let folder, let doc = item.doc else { return nil }
        var built: PlanInstaller.Built?
        do {
            let b = try PlanInstaller.build(doc)
            built = b
            for warning in b.warnings { log("plan \(doc.name): \(warning)", .plan) }
            if let message = await PlanInstaller.schedule(b.plan, at: date) { throw HealthAccessError(message) }
            let status = PlanStatus(planId: doc.id, state: "scheduled", at: Date(), error: nil, method: "schedule",
                                    workoutkitId: b.plan.id.uuidString, scheduledFor: date)
            try PlanInstaller.writeStatus(status, for: item, folder: folder)
            Notifier.clearPlanPrompt(planID: item.id)
            log("plan \(doc.name) on the Watch for \(Format.dayTime(date))", .plan)
            Telemetry.shared.capture(.planScheduled)
            rescanPlans()
            writeBriefing()
            return b.plan
        } catch {
            let status = PlanStatus(planId: doc.id, state: "failed", at: Date(), error: error.localizedDescription, method: "schedule",
                                    workoutkitId: built?.plan.id.uuidString, scheduledFor: date)
            try? PlanInstaller.writeStatus(status, for: item, folder: folder)
            fail("plan \(doc.name) failed: \(error.localizedDescription)")
            rescanPlans()
            return nil
        }
    }

    /// Apple's preview sheet. It does not report back, so the status is written as "added via preview, unconfirmed".
    func requestPreview(_ item: PlanItem) {
        guard let doc = item.doc else { return }
        confirmation = Confirmation(
            title: "Open Apple's preview of \(doc.name)",
            detail: "Add to Watch there puts the workout in the Workout app without a date. Apple does not report back, so when the preview closes Health Access writes plans/\(item.id).status.json as added via preview, unconfirmed.",
            confirmTitle: "Open preview") { [weak self] in
                guard let self else { return }
                Telemetry.shared.capture(.planPutOnWatch(method: "preview"))
                if await self.preparePreview(item) {
                    self.followUp = { [weak self] in self?.showPreview = true }
                } else {
                    self.results["plan:\(item.id)"] = ActionResult(kind: .failed, text: self.lastError ?? "Could not build the preview.", at: Date())
                }
            }
    }

    private func preparePreview(_ item: PlanItem) async -> Bool {
        guard let folder, let doc = item.doc else { return false }
        do {
            guard PlanInstaller.isSupported else { throw HealthAccessError("WorkoutKit is not supported on this iPhone (is a Watch paired?)") }
            let auth = await PlanInstaller.authorize()
            guard auth.authorized else { throw HealthAccessError("WorkoutKit authorization is \(auth.description)") }
            let built = try PlanInstaller.build(doc)
            for warning in built.warnings { log("plan \(doc.name): \(warning)", .plan) }
            previewing = PreviewSession(item: item, plan: built.plan)
            log("plan \(doc.name) preview opened", .plan)
            return true
        } catch {
            let status = PlanStatus(planId: doc.id, state: "failed", at: Date(), error: error.localizedDescription, method: "preview",
                                    workoutkitId: nil, scheduledFor: doc.scheduledFor)
            try? PlanInstaller.writeStatus(status, for: item, folder: folder)
            fail("plan \(doc.name) failed: \(error.localizedDescription)")
            rescanPlans()
            return false
        }
    }

    /// Apple's preview sheet closed: write `method: preview`, state `scheduled`, say it is unconfirmed, offer Undo.
    func previewClosed() async {
        guard let session = previewing else { return }
        previewing = nil
        guard let folder, let doc = session.item.doc else { return }
        let key = "plan:\(session.item.id)"
        let status = PlanStatus(planId: doc.id, state: "scheduled", at: Date(), error: nil, method: "preview",
                                workoutkitId: session.plan.id.uuidString, scheduledFor: doc.scheduledFor)
        do {
            try PlanInstaller.writeStatus(status, for: session.item, folder: folder)
            Notifier.clearPlanPrompt(planID: session.item.id)
            log("plan \(doc.name) added via preview (unconfirmed)", .plan)
            Telemetry.shared.capture(.planScheduled)
            results[key] = ActionResult(kind: .done, text: "Added via preview (unconfirmed). Check the Workout app on your Watch.", at: Date())
            offerUndo(key: key) { [weak self] in await self?.undoStatus(session.item, key: key) }
        } catch {
            fail("status write failed: \(error.localizedDescription)")
            results[key] = ActionResult(kind: .failed, text: error.localizedDescription, at: Date())
        }
        rescanPlans()
        writeBriefing()
    }

    /// Undo of a status the app itself wrote seconds ago: the file goes away, the row comes back.
    private func undoStatus(_ item: PlanItem, key: String) async {
        guard let folder else { return }
        do {
            try folder.remove(item.statusFile)
            log("undo: status for \(item.name) removed", .plan)
        } catch {
            fail("undo failed: \(error.localizedDescription)")
        }
        results[key] = nil
        rescanPlans()
        writeBriefing()
    }

    // MARK: - your AI

    func requestSetupCopy(key: String = "setup") {
        let message = SetupMessage.text(for: folder)
        let name = folder?.displayName ?? "your folder"
        confirmation = Confirmation(
            title: "Copy the setup message",
            detail: "It asks your AI to register the Health Access MCP (\(SetupMessage.command)), which finds your folder on its own; the folder's name (\(name)) is in it as a hint. No health data. Copy puts it on the clipboard and then opens the share sheet, in case AirDrop to your computer is easier than pasting.",
            confirmTitle: "Copy") { [weak self] in
                guard let self else { return }
                UIPasteboard.general.string = message
                self.results[key] = ActionResult(kind: .done, text: "Setup message copied. Paste it to your AI on your computer.", at: Date())
                self.waitingForClient = true
                Telemetry.shared.capture(.setupMessageCopied)
                self.log("setup message copied", .ui)
                self.followUp = { [weak self] in self?.shareItems = ShareItems(items: [message]) }
            }
    }

    // MARK: - support card

    /// The App Store's own sheet is the confirmation here; the row then shows what happened.
    func buySupport(_ product: Product, purchase: PurchaseAction) async {
        log("support: \(product.id) tapped", .ui)
        do {
            switch try await support.complete(try await purchase(product)) {
            case .cardRemoved:
                results["support"] = ActionResult(kind: .done, text: "Thank you. This card is gone from the next launch.", at: Date())
                log("support: card removed", .ui)
            case .coffee:
                results["support"] = ActionResult(kind: .done, text: "Thank you for the coffee.", at: Date())
                log("support: coffee", .ui)
            case .pending:
                results["support"] = ActionResult(kind: .done, text: "Waiting for approval. The App Store finishes it on its own.", at: Date())
                log("support: pending approval", .ui)
            case .cancelled:
                log("support: cancelled", .ui)
            }
        } catch {
            results["support"] = ActionResult(kind: .failed, text: error.localizedDescription, at: Date())
            fail("support purchase failed: \(error.localizedDescription)")
        }
    }

    func restoreSupport() async {
        log("support: restore", .ui)
        let removed = await support.restore()
        results["restore"] = ActionResult(kind: .done,
                                          text: removed ? "Restored. The support card stays removed." : "Nothing to restore on this Apple Account.",
                                          at: Date())
    }

    // MARK: - settings

    func requestUsageStatistics(_ on: Bool) {
        guard on else {
            setTelemetry(false)
            return
        }
        let host = Telemetry.shared.hostName ?? "PostHog"
        confirmation = Confirmation(
            title: "Send usage statistics",
            detail: "Which features you use and whether they worked go to \(host) under a random install id. Never a health value, never a file name, never a folder path.",
            confirmTitle: "Send") { [weak self] in
                self?.setTelemetry(true)
            }
    }

    private func setTelemetry(_ on: Bool) {
        settings.telemetryEnabled = on
        if on {
            Telemetry.shared.start(installID: settings.installID)
            log("usage statistics switched on", .usage)
            announceClients()
        } else {
            Telemetry.shared.stop()
            log("usage statistics switched off", .usage)
        }
    }

    /// The cycle group and the reproductive types. Switching it on asks Health for the added types.
    func setIncludeReproductive(_ on: Bool) {
        settings.includeReproductive = on
        settings.lastCatalogAt = nil
        log("reproductive health data \(on ? "included" : "left out")", .health)
        if on, settings.healthAuthRequested {
            Task { await requestHealthAccess() }
        }
    }

    func setIncludeECGVoltage(_ on: Bool) {
        settings.includeECGVoltage = on
        log("ECG voltage \(on ? "included" : "left out")", .health)
    }

    func clearLog() async {
        await DiskLog.shared.clear()
        logLines = []
    }

    // MARK: - confirmations and undo

    /// Runs after the confirmation sheet is gone: the share sheet after a copy, the preview after its confirmation.
    func confirmationDismissed() {
        let next = followUp
        followUp = nil
        next?()
    }

    func offerUndo(key: String, _ perform: @escaping @MainActor () async -> Void) {
        undoTimer?.cancel()
        undo = UndoToken(key: key, until: Date().addingTimeInterval(10), perform: perform)
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func performUndo() async {
        guard let token = undo else { return }
        undoTimer?.cancel()
        undo = nil
        await token.perform()
        log("undo: \(token.key)", .ui)
    }

    // MARK: - log

    func log(_ text: String, _ tag: LogTag) {
        let line = "\(Format.logStamp(Date())) [\(tag.rawValue)] \(text)"
        Task { logLines = await DiskLog.shared.append(line) }
    }

    private func fail(_ text: String) {
        lastError = text
        log(text, .error)
    }

    private func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
}
