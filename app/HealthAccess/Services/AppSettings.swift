import Foundation
import Observation

/// What "Put on Watch" does (Settings → Sessions).
enum PutOnWatchMode: String, CaseIterable, Identifiable {
    case nextDay, planTime, preview
    var id: String { rawValue }

    func title(hour: Int, minute: Int) -> String {
        switch self {
        case .nextDay: return String(format: "Schedule for next day at %02d:%02d", hour, minute)
        case .planTime: return "Schedule for the plan's time"
        case .preview: return "Preview sheet"
        }
    }

    func short(hour: Int, minute: Int) -> String {
        switch self {
        case .nextDay: return String(format: "Next day %02d:%02d", hour, minute)
        case .planTime: return "Plan's time"
        case .preview: return "Preview sheet"
        }
    }
}

/// UserDefaults-backed settings. Observable so SwiftUI updates; blobs (anchors, pending lists) are plain computed properties.
/// Keys are `healthaccess.<name>`; values stored under the pre-rename alias keys `tide.<name>` are moved once by `migrateLegacyKeys()`.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Prefix of every UserDefaults key the app owns.
    nonisolated static let keyPrefix = "healthaccess."
    /// Prefix used before the rename (alias); migrated, never written.
    nonisolated private static let legacyKeyPrefix = "tide."  // alias
    /// Every key name the app has ever stored, so the migration can move them one by one.
    nonisolated private static let keyNames = [
        "zoneBounds", "telemetryEnabled", "onboardingDone", "backfillDays", "planInstallMode", "previewShownOnce",
        "lastSync", "lastSyncSummary", "lastObserverFire", "lastBGTaskRun", "healthAuthRequested", "notificationsRequested",
        "backgroundDeliveryEnabled", "exportedTotal", "installID", "workoutAnchor", "anchorStart", "recoveryPending",
        "folderBookmark",
    ]

    nonisolated static func key(_ name: String) -> String { keyPrefix + name }

    /// One-time migration of the pre-rename keys: for every known name, read the old key when the new one is absent,
    /// write it under the new key, and remove the old key. Idempotent; call before anything reads settings.
    nonisolated static func migrateLegacyKeys(_ defaults: UserDefaults = .standard) {
        for name in keyNames {
            let old = legacyKeyPrefix + name
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: key(name)) == nil { defaults.set(value, forKey: key(name)) }
            defaults.removeObject(forKey: old)
        }
    }

    @ObservationIgnored private let d = UserDefaults.standard

    var telemetryEnabled: Bool { didSet { d.set(telemetryEnabled, forKey: Self.key("telemetryEnabled")) } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: Self.key("onboardingDone")) } }
    var backfillDays: Int { didSet { d.set(backfillDays, forKey: Self.key("backfillDays")) } }
    var putOnWatchMode: PutOnWatchMode { didSet { d.set(putOnWatchMode.rawValue, forKey: Self.key("putOnWatchMode")) } }
    var putOnWatchHour: Int { didSet { d.set(putOnWatchHour, forKey: Self.key("putOnWatchHour")) } }
    var putOnWatchMinute: Int { didSet { d.set(putOnWatchMinute, forKey: Self.key("putOnWatchMinute")) } }
    var lastSync: Date? { didSet { d.set(lastSync, forKey: Self.key("lastSync")) } }
    var lastSyncSummary: String { didSet { d.set(lastSyncSummary, forKey: Self.key("lastSyncSummary")) } }
    var lastObserverFire: Date? { didSet { d.set(lastObserverFire, forKey: Self.key("lastObserverFire")) } }
    var lastBGTaskRun: Date? { didSet { d.set(lastBGTaskRun, forKey: Self.key("lastBGTaskRun")) } }
    var healthAuthRequested: Bool { didSet { d.set(healthAuthRequested, forKey: Self.key("healthAuthRequested")) } }
    var notificationsRequested: Bool { didSet { d.set(notificationsRequested, forKey: Self.key("notificationsRequested")) } }
    var backgroundDeliveryEnabled: Bool { didSet { d.set(backgroundDeliveryEnabled, forKey: Self.key("backgroundDeliveryEnabled")) } }
    var exportedTotal: Int { didSet { d.set(exportedTotal, forKey: Self.key("exportedTotal")) } }
    /// Health was locked when the last wake came in; the files get written on the next unlock.
    var deferredSync: Bool { didSet { d.set(deferredSync, forKey: Self.key("deferredSync")) } }
    /// The cycle group of the day files and the reproductive category types in the Health request. On by default.
    var includeReproductive: Bool { didSet { d.set(includeReproductive, forKey: Self.key("includeReproductive")) } }
    /// The voltage series next to each ECG file. Off by default (large).
    var includeECGVoltage: Bool { didSet { d.set(includeECGVoltage, forKey: Self.key("includeECGVoltage")) } }
    var lastCatalogAt: Date? { didSet { d.set(lastCatalogAt, forKey: Self.key("lastCatalogAt")) } }
    /// When the folder was last picked, so onboarding can show the "Folder: … Set …" line again after a relaunch.
    var folderSetAt: Date? { didSet { d.set(folderSetAt, forKey: Self.key("folderSetAt")) } }
    /// Cache of the App Store entitlement that removes the support card; `SupportStore` keeps it true.
    var supportCardRemoved: Bool { didSet { d.set(supportCardRemoved, forKey: Self.key("supportCardRemoved")) } }
    /// Plans tab: new plans go onto the Watch without a tap, at the plan's time. Off by default; turned on with a confirmation.
    var autoPutOnWatch: Bool { didSet { d.set(autoPutOnWatch, forKey: Self.key("autoPutOnWatch")) } }
    /// Anonymous, per-install id used as the usage-statistics distinct id. Never tied to a person.
    let installID: String

    /// The names the UI uses (the stored keys keep their v0.2 names so settings survive the update).
    var usageStatisticsEnabled: Bool { telemetryEnabled }
    var sessionFilesWritten: Int { exportedTotal }

    private init() {
        Self.migrateLegacyKeys(d)
        telemetryEnabled = d.bool(forKey: Self.key("telemetryEnabled"))
        onboardingDone = d.bool(forKey: Self.key("onboardingDone"))
        backfillDays = d.object(forKey: Self.key("backfillDays")) as? Int ?? 60
        if let raw = d.string(forKey: Self.key("putOnWatchMode")), let mode = PutOnWatchMode(rawValue: raw) {
            putOnWatchMode = mode
        } else if d.string(forKey: Self.key("planInstallMode")) == "preview" {
            putOnWatchMode = .preview   // v0.2 setting carried over once
        } else {
            putOnWatchMode = .nextDay
        }
        putOnWatchHour = d.object(forKey: Self.key("putOnWatchHour")) as? Int ?? 10
        putOnWatchMinute = d.object(forKey: Self.key("putOnWatchMinute")) as? Int ?? 0
        lastSync = d.object(forKey: Self.key("lastSync")) as? Date
        lastSyncSummary = d.string(forKey: Self.key("lastSyncSummary")) ?? "never"
        lastObserverFire = d.object(forKey: Self.key("lastObserverFire")) as? Date
        lastBGTaskRun = d.object(forKey: Self.key("lastBGTaskRun")) as? Date
        healthAuthRequested = d.bool(forKey: Self.key("healthAuthRequested"))
        notificationsRequested = d.bool(forKey: Self.key("notificationsRequested"))
        backgroundDeliveryEnabled = d.bool(forKey: Self.key("backgroundDeliveryEnabled"))
        exportedTotal = d.integer(forKey: Self.key("exportedTotal"))
        deferredSync = d.bool(forKey: Self.key("deferredSync"))
        includeReproductive = d.object(forKey: Self.key("includeReproductive")) as? Bool ?? true
        includeECGVoltage = d.bool(forKey: Self.key("includeECGVoltage"))
        lastCatalogAt = d.object(forKey: Self.key("lastCatalogAt")) as? Date
        folderSetAt = d.object(forKey: Self.key("folderSetAt")) as? Date
        supportCardRemoved = d.bool(forKey: Self.key("supportCardRemoved"))
        autoPutOnWatch = d.bool(forKey: Self.key("autoPutOnWatch"))
        if let id = d.string(forKey: Self.key("installID")) {
            installID = id
        } else {
            let id = UUID().uuidString
            d.set(id, forKey: Self.key("installID"))
            installID = id
        }
    }

    // MARK: blobs (not observed)

    /// Persisted HKQueryAnchor for the workout anchored query.
    var workoutAnchor: Data? {
        get { d.data(forKey: Self.key("workoutAnchor")) }
        set { d.set(newValue, forKey: Self.key("workoutAnchor")) }
    }

    /// Lower bound of the anchored query's predicate; fixed when the anchor was first created.
    var anchorStart: Date? {
        get { d.object(forKey: Self.key("anchorStart")) as? Date }
        set { d.set(newValue, forKey: Self.key("anchorStart")) }
    }

    /// Workouts exported before their 2-minute recovery window had elapsed: workout id → workout end. Patched on a later run.
    var recoveryPending: [String: Date] {
        get {
            guard let data = d.data(forKey: Self.key("recoveryPending")),
                  let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
            return dict.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            let dict = newValue.mapValues { $0.timeIntervalSince1970 }
            d.set(try? JSONEncoder().encode(dict), forKey: Self.key("recoveryPending"))
        }
    }

    /// Plans the user has already been told about (card shown or notification posted), so a wake never repeats itself.
    var announcedPlanIDs: Set<String> {
        get { Set(d.stringArray(forKey: Self.key("announcedPlanIDs")) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Self.key("announcedPlanIDs")) }
    }

    /// Handshake ids already reported as `ai_connected`, so each AI client is counted once per install.
    var announcedClientIDs: Set<String> {
        get { Set(d.stringArray(forKey: Self.key("announcedClientIDs")) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Self.key("announcedClientIDs")) }
    }

    /// The Apple effort rating last copied per workout id (kept for the days the app re-checks ratings).
    var appleEffortSeen: [String: Int] {
        get { (d.dictionary(forKey: Self.key("appleEffortSeen")) as? [String: Int]) ?? [:] }
        set { d.set(newValue, forKey: Self.key("appleEffortSeen")) }
    }

    /// Runs in which a queued day could not be written, per day number; after three the day is given up.
    var dayFailures: [String: Int] {
        get { (d.dictionary(forKey: Self.key("dayFailures")) as? [String: Int]) ?? [:] }
        set { d.set(newValue, forKey: Self.key("dayFailures")) }
    }

    func resetAnchor() {
        workoutAnchor = nil
        anchorStart = nil
    }

    // MARK: day queue and history (not observed; AppModel.backlog is what the UI watches)

    private func dayRanges(_ name: String) -> DayRanges {
        guard let data = d.data(forKey: Self.key(name)), let stored = try? JSONDecoder().decode([[Int]].self, from: data) else { return DayRanges() }
        return DayRanges(stored: stored)
    }

    private func setDayRanges(_ ranges: DayRanges, _ name: String) {
        if ranges.isEmpty {
            d.removeObject(forKey: Self.key(name))
        } else {
            d.set(try? JSONEncoder().encode(ranges.stored), forKey: Self.key(name))
        }
    }

    /// Day files still to write since the last sync (a gap after the app was closed, or the first run's window).
    var pendingDays: DayRanges {
        get { dayRanges("pendingDays") }
        set { setDayRanges(newValue, "pendingDays") }
    }

    /// Older day files the user asked for with "Import older data".
    var historyDays: DayRanges {
        get { dayRanges("historyDays") }
        set { setDayRanges(newValue, "historyDays") }
    }

    /// The local day (day number) of the last sync that wrote day files. Days since then are queued on the next sync.
    var lastDaySync: Int? {
        get { d.object(forKey: Self.key("lastDaySync")) as? Int }
        set { d.set(newValue, forKey: Self.key("lastDaySync")) }
    }

    /// The earliest day ever queued. A history request extends it backwards.
    var dayCoverageStart: Int? {
        get { d.object(forKey: Self.key("dayCoverageStart")) as? Int }
        set { d.set(newValue, forKey: Self.key("dayCoverageStart")) }
    }

    /// How far back the user asked to import (nil: never asked).
    var historyStart: Date? {
        get { d.object(forKey: Self.key("historyStart")) as? Date }
        set { d.set(newValue, forKey: Self.key("historyStart")) }
    }

    /// Every workout that started at or after this moment is written. Moves backwards while the import runs.
    var historyWorkoutCursor: Date? {
        get { d.object(forKey: Self.key("historyWorkoutCursor")) as? Date }
        set { d.set(newValue, forKey: Self.key("historyWorkoutCursor")) }
    }

    var historyPaused: Bool {
        get { d.bool(forKey: Self.key("historyPaused")) }
        set { d.set(newValue, forKey: Self.key("historyPaused")) }
    }

    var historyFinishedAt: Date? {
        get { d.object(forKey: Self.key("historyFinishedAt")) as? Date }
        set { d.set(newValue, forKey: Self.key("historyFinishedAt")) }
    }

    /// Session and day files the history import has written so far (for the History screen).
    var historyWorkoutsWritten: Int {
        get { d.integer(forKey: Self.key("historyWorkoutsWritten")) }
        set { d.set(newValue, forKey: Self.key("historyWorkoutsWritten")) }
    }

    var historyDaysWritten: Int {
        get { d.integer(forKey: Self.key("historyDaysWritten")) }
        set { d.set(newValue, forKey: Self.key("historyDaysWritten")) }
    }

    /// A different folder starts empty: forget which days and which older workouts were written.
    func resetDayState() {
        for name in ["pendingDays", "historyDays", "lastDaySync", "dayCoverageStart", "historyStart", "historyWorkoutCursor",
                     "historyPaused", "historyFinishedAt", "historyWorkoutsWritten", "historyDaysWritten", "dayFailures"] {
            d.removeObject(forKey: Self.key(name))
        }
    }
}
