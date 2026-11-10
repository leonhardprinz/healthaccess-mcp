import Foundation
import HealthKit
import UIKit

/// The backlog: day files and workouts older than what a normal sync writes.
///
/// Two sources feed it. A sync queues the days between the last sync and today (the app was closed, the phone was
/// off, or it is the first run and the window is `backfillDays`). "Import older data" queues everything further back
/// that the user asked for. Both are written newest first while the app is open, in small steps that can stop at any
/// point and carry on later; nothing here runs unless the phone is unlocked, because iOS locks Health with the phone.
extension AppModel {
    /// What the UI shows while the backlog is written.
    struct Backlog: Equatable {
        var running = false
        var daysLeft = 0
        var workoutsLeft = 0
        /// Why the last run stopped early, when it did.
        var note: String?
        /// Bumped whenever the stored history state changes, so views that read it redraw.
        var revision = 0
    }

    enum DayQueue { case pending, history }

    /// How far back "Import older data" goes.
    enum HistorySpan: String, CaseIterable, Identifiable {
        case year, threeYears, everything
        var id: String { rawValue }

        var title: String {
            switch self {
            case .year: return "The last 12 months"
            case .threeYears: return "The last 3 years"
            case .everything: return "Everything Health has"
            }
        }
    }

    // MARK: state the views read

    /// An import was asked for and is not finished (it may be paused).
    var historyUnderWay: Bool { settings.historyStart != nil && settings.historyFinishedAt == nil }

    /// An import that should be running whenever the app is open.
    var historyActive: Bool { historyUnderWay && !settings.historyPaused }

    private var historyWorkoutsPending: Bool {
        guard let start = settings.historyStart, let cursor = settings.historyWorkoutCursor else { return false }
        return cursor > start
    }

    var hasBacklog: Bool {
        !settings.pendingDays.isEmpty || (historyActive && (!settings.historyDays.isEmpty || historyWorkoutsPending))
    }

    /// "212 workouts and 1,430 days to go"
    var backlogLine: String {
        var parts: [String] = []
        if backlog.workoutsLeft > 0 { parts.append("\(backlog.workoutsLeft.formatted()) workout\(backlog.workoutsLeft == 1 ? "" : "s")") }
        if backlog.daysLeft > 0 { parts.append("\(backlog.daysLeft.formatted()) day\(backlog.daysLeft == 1 ? "" : "s")") }
        return parts.isEmpty ? "Almost done." : parts.joined(separator: " and ") + " to go"
    }

    private func refreshBacklogCounts() {
        backlog.daysLeft = settings.pendingDays.count + (historyActive ? settings.historyDays.count : 0)
        if !historyActive || !historyWorkoutsPending { backlog.workoutsLeft = 0 }
    }

    // MARK: queueing

    /// Called by every sync. Today and yesterday are written by the sync itself; this queues the days before them
    /// back to the last sync, or back to the first run's window.
    func queueDaysSinceLastSync(today: Int) {
        let from = settings.lastDaySync ?? (today - settings.backfillDays)
        if settings.dayCoverageStart == nil { settings.dayCoverageStart = min(from, today) }
        guard from <= today - 2 else { return }
        var queue = settings.pendingDays
        queue.insert(from...(today - 2))
        settings.pendingDays = queue
    }

    /// Looks at Health first, so the sheet can say how much there is, then asks.
    func requestHistory(_ span: HistorySpan) async {
        guard folder != nil, settings.lastSync != nil else { return }
        let now = Date()
        let start: Date
        switch span {
        case .year: start = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now.addingTimeInterval(-365 * 86_400)
        case .threeYears: start = Calendar.current.date(byAdding: .year, value: -3, to: now) ?? now.addingTimeInterval(-3 * 365 * 86_400)
        case .everything:
            let ranges = await lifetimeTypes()
            start = ranges.values.map(\.lowerBound).min() ?? now
        }
        let today = DayRanges.number(of: now)
        let startDay = DayRanges.number(of: max(start, HealthService.historyFloor))
        let coverage = settings.dayCoverageStart ?? (today - settings.backfillDays)
        let newDays = max(0, coverage - startDay)
        let upper = settings.historyWorkoutCursor ?? settings.anchorStart ?? now
        let from = DayRanges.date(startDay).addingTimeInterval(-12 * 3600)
        let workouts = (try? await health.workouts(from: from, before: upper).count) ?? 0
        guard newDays > 0 || workouts > 0 else {
            results["history"] = ActionResult(kind: .done, text: "Nothing older to import: your folder already goes back as far as that.", at: Date())
            return
        }
        confirmation = Confirmation(
            title: "Import data since \(Format.date(from))",
            detail: "About \(workouts.formatted()) workout\(workouts == 1 ? "" : "s") and up to \(newDays.formatted()) day\(newDays == 1 ? "" : "s"), newest first. Keep the app open and the phone unlocked while it runs; it carries on where it stopped if you leave. You can pause it at any time.",
            confirmTitle: "Import") { [weak self] in
                guard let self else { return }
                if startDay < coverage {
                    var queue = self.settings.historyDays
                    queue.insert(startDay...(coverage - 1))
                    self.settings.historyDays = queue
                    self.settings.dayCoverageStart = startDay
                }
                self.settings.historyWorkoutCursor = upper
                self.settings.historyStart = min(self.settings.historyStart ?? from, from)
                self.settings.historyPaused = false
                self.settings.historyFinishedAt = nil
                self.results["history"] = nil
                self.backlog.revision += 1
                self.log("history import asked: back to \(DayRanges.string(startDay)), \(workouts) workout(s), \(newDays) day(s)", .sync)
                self.kickBacklog()
            }
    }

    func pauseHistory() {
        guard historyActive else { return }
        settings.historyPaused = true
        backlogTask?.cancel()
        backlog.revision += 1
        log("history import paused", .sync)
    }

    func resumeHistory() {
        guard historyUnderWay else { return }
        settings.historyPaused = false
        backlog.note = nil
        backlog.revision += 1
        log("history import resumed", .sync)
        kickBacklog()
    }

    // MARK: running

    /// Starts writing the backlog when there is one, the app is in front and nothing is writing it already.
    func kickBacklog() {
        guard backlogTask == nil, folder != nil, !folderStale, settings.onboardingDone, settings.healthAuthRequested else { return }
        guard hasBacklog, UIApplication.shared.applicationState != .background else {
            refreshBacklogCounts()
            return
        }
        backlogTask = Task { [weak self] in
            await self?.drainBacklog()
            guard let self else { return }
            let cancelled = Task.isCancelled
            self.backlogTask = nil
            // A pause cancels the run; the gap days are not part of what was paused.
            if cancelled, !self.settings.pendingDays.isEmpty { self.kickBacklog() }
        }
    }

    private func drainBacklog() async {
        guard let folder else { return }
        let root = folder.root.path
        let historic = historyActive
        backlog.running = true
        backlog.note = nil
        refreshBacklogCounts()
        if historic { UIApplication.shared.isIdleTimerDisabled = true }
        defer {
            if historic { UIApplication.shared.isIdleTimerDisabled = false }
            backlog.running = false
            refreshBacklogCounts()
        }
        // Stops between two files: on a pause, when the app leaves the screen, the phone locks or the folder changes.
        let alive: @MainActor () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.folder?.root.path == root else { return false }
            return UIApplication.shared.applicationState != .background && UIApplication.shared.isProtectedDataAvailable
        }
        let started = Date()
        var days = 0
        var workouts = 0
        do {
            days += await drainDays(.pending, folder: folder, alive: alive)
            if historyActive, alive() {
                workouts = try await drainHistoryWorkouts(folder: folder, alive: alive)
            }
            if historyActive, alive() {
                days += await drainDays(.history, folder: folder, alive: alive)
            }
        } catch {
            let ns = error as NSError
            if ns.domain == HKError.errorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue {
                backlog.note = "Paused while the phone was locked. It carries on when you open the app."
            } else if error is CancellationError {
                // a pause or a new folder; nothing to say
            } else {
                backlog.note = "Stopped: \(error.localizedDescription). It tries again the next time you open the app."
                log("backlog stopped: \(error.localizedDescription) [\(ns.domain) \(ns.code)]", .error)
            }
        }
        if days > 0 || workouts > 0 {
            rebuildIndex(folder)
            writeBriefing()
            log("backlog: \(workouts) older session(s) and \(days) day file(s) written in \(Int(Date().timeIntervalSince(started))) s", .sync)
        }
        if historyActive, settings.historyDays.isEmpty, !historyWorkoutsPending {
            settings.historyFinishedAt = Date()
            backlog.revision += 1
            log("history import done: \(settings.historyWorkoutsWritten) session(s) and \(settings.historyDaysWritten) day file(s) back to \(settings.historyStart.map(Format.date) ?? "the start")", .sync)
        }
    }

    /// First and last sample per type over all of Health, read once and kept for six hours.
    func lifetimeTypes() async -> [String: ClosedRange<Date>] {
        if let cached = lifetimeRanges, Date().timeIntervalSince(cached.at) < 6 * 3600 { return cached.ranges }
        let started = Date()
        let ranges = await health.lifetimeRanges(includeReproductive: settings.includeReproductive)
        lifetimeRanges = (Date(), ranges)
        log("history: \(ranges.count) Health types have data, the oldest from \(ranges.values.map(\.lowerBound).min().map(Format.date) ?? "nowhere") · \(Int(started.distance(to: Date()) * 1000)) ms", .sync)
        return ranges
    }

    /// The types that can have a value on a day: those whose first-to-last span touches it (a day and a half of slack
    /// on both sides, for sleep that started the evening before and for time zones).
    nonisolated static func types(on day: Int, in ranges: [String: ClosedRange<Date>]) -> Set<String> {
        let noon = DayRanges.date(day)
        let from = noon.addingTimeInterval(-36 * 3600)
        let to = noon.addingTimeInterval(36 * 3600)
        var names = Set<String>()
        for (name, range) in ranges where range.lowerBound <= to && range.upperBound >= from { names.insert(name) }
        return names
    }

    /// Writes queued day files newest first, four at a time, until the queue is empty, `alive` says stop or the
    /// deadline passes. A day stays queued until its file is written (or known to be empty). Returns the files written.
    @discardableResult
    func drainDays(_ which: DayQueue, folder: FolderStore, deadline: Date? = nil, insideSync: Bool = false, alive: @MainActor () -> Bool) async -> Int {
        var written = 0
        let recentTypes = CatalogBuilder.typesWithData(folder: folder)
        let includeReproductive = settings.includeReproductive
        let health = self.health
        let today = DayRanges.number(of: Date())
        while alive(), deadline.map({ Date() < $0 }) ?? true {
            let batch = (which == .pending ? settings.pendingDays : settings.historyDays).newest(4)
            guard !batch.isEmpty else { break }
            if isSyncing && !insideSync {   // let a sync that just started finish first
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            // The catalog knows the last 90 days; older days go by the all-time ranges instead.
            var jobs: [(day: Int, types: Set<String>?)] = []
            for day in batch {
                if day >= today - (CatalogBuilder.windowDays - 5) {
                    jobs.append((day, recentTypes))
                } else if insideSync && lifetimeRanges == nil {
                    continue   // reading all of Health's ranges does not fit a background wake; the open app does it
                } else {
                    jobs.append((day, Self.types(on: day, in: await lifetimeTypes())))
                }
            }
            guard !jobs.isEmpty else { break }
            let withVitals = which == .pending
            let outcomes = await withTaskGroup(of: (Int, Result<DayExporter.Outcome, Error>).self) { group -> [(Int, Result<DayExporter.Outcome, Error>)] in
                for job in jobs {
                    group.addTask {
                        if let types = job.types, types.isEmpty { return (job.day, .success(.empty)) }  // Health has nothing that old
                        let date = DayRanges.date(job.day)
                        do {
                            let exporter = DayExporter(health: health, typesWithData: job.types, includeReproductive: includeReproductive)
                            let outcome = try await exporter.exportDay(date, folder: folder)
                            if withVitals { _ = await VitalsExporter(health: health).export(days: [date], folder: folder) { _ in } }
                            return (job.day, .success(outcome))
                        } catch {
                            return (job.day, .failure(error))
                        }
                    }
                }
                var all: [(Int, Result<DayExporter.Outcome, Error>)] = []
                for await item in group { all.append(item) }
                return all
            }
            var queue = which == .pending ? settings.pendingDays : settings.historyDays
            var locked = false
            var stopped: String?
            for (day, result) in outcomes {
                switch result {
                case .success(let outcome):
                    queue.remove(day)
                    if outcome == .written {
                        written += 1
                        if which == .history { settings.historyDaysWritten += 1 }
                    }
                case .failure(let error):
                    let ns = error as NSError
                    if ns.domain == HKError.errorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue {
                        locked = true   // stays queued
                    } else if error is CancellationError || Task.isCancelled {
                        continue        // paused in the middle: stays queued
                    } else {
                        // Most likely the folder: storage full, a server that is away, a file not downloaded. The day
                        // stays queued and this run stops; only a day that fails in three runs is given up.
                        var failures = settings.dayFailures
                        let count = (failures[String(day)] ?? 0) + 1
                        if count >= 3 {
                            failures[String(day)] = nil
                            queue.remove(day)
                            log("day \(DayRanges.string(day)) given up after three tries: \(error.localizedDescription)", .error)
                        } else {
                            failures[String(day)] = count
                            stopped = "Stopped: \(error.localizedDescription). It tries again the next time you open the app."
                            log("day \(DayRanges.string(day)) failed, will try again: \(error.localizedDescription)", .error)
                        }
                        settings.dayFailures = failures
                    }
                }
            }
            if which == .pending { settings.pendingDays = queue } else { settings.historyDays = queue }
            refreshBacklogCounts()
            if locked {
                backlog.note = "Paused while the phone was locked. It carries on when you open the app."
                break
            }
            if let stopped {
                backlog.note = stopped
                break
            }
        }
        return written
    }

    /// Writes the workouts between the import's start and the sync's own window, newest first, three at a time.
    /// The cursor moves back with every session written, so a stop loses nothing. Returns the files written.
    private func drainHistoryWorkouts(folder: FolderStore, alive: @MainActor () -> Bool) async throws -> Int {
        guard let start = settings.historyStart, let cursor = settings.historyWorkoutCursor, cursor > start else { return 0 }
        // One millisecond past the cursor: a second workout with the very same start is seen again, and skipped by its file.
        let all = try await health.workouts(from: start, before: cursor.addingTimeInterval(0.001))
        backlog.workoutsLeft = all.count
        // Session files only: a route sidecar left behind by an interrupted write must not count as "already there".
        var existing = Set(try folder.list("workouts").filter { !$0.hasSuffix(".route.json") }.compactMap(Self.uuid8(ofFile:)))
        let exporter = WorkoutExporter(health: health, healthaccessVersion: HealthAccessJSON.appVersion)
        let lookup = PlanInstaller.installed(from: plans)
        var written = 0
        var sinceIndex = 0
        var index = 0
        while index < all.count {
            guard alive() else { return written }
            if isSyncing {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            let chunk = Array(all[index..<min(index + 3, all.count)])
            let todo = chunk.filter { !existing.contains(String($0.uuid.uuidString.prefix(8))) }
            let health = self.health
            let built = await withTaskGroup(of: (UUID, Result<WorkoutExporter.Built, Error>).self) { group -> [UUID: Result<WorkoutExporter.Built, Error>] in
                for workout in todo {
                    group.addTask {
                        do {
                            let item = try await exporter.build(for: workout, plans: lookup)
                            // A session read while the phone was locking, or while a pause came in, may be half empty:
                            // do not keep it. Session files are never overwritten, so it would stay that way.
                            try await health.probe()
                            try Task.checkCancellation()
                            return (workout.uuid, .success(item))
                        } catch {
                            return (workout.uuid, .failure(error))
                        }
                    }
                }
                var out: [UUID: Result<WorkoutExporter.Built, Error>] = [:]
                for await (id, item) in group { out[id] = item }
                return out
            }
            guard alive() else { return written }
            for workout in chunk {
                switch built[workout.uuid] {
                case .success(let item):
                    _ = try Self.writeWorkout(item, folder: folder)
                    existing.insert(String(workout.uuid.uuidString.prefix(8)))
                    written += 1
                    sinceIndex += 1
                    settings.historyWorkoutsWritten += 1
                    settings.exportedTotal += 1
                case .failure(let error):
                    let ns = error as NSError
                    if error is CancellationError || (ns.domain == HKError.errorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue) {
                        throw error   // stop here; the cursor has not passed this session
                    }
                    // One session Health cannot give us must not block the years behind it.
                    log("older session \(workout.uuid.uuidString.prefix(8)) of \(Format.date(workout.startDate)) skipped: \(error.localizedDescription)", .error)
                case nil:
                    break   // its file is already there
                }
                settings.historyWorkoutCursor = workout.startDate
            }
            index += chunk.count
            backlog.workoutsLeft = all.count - index
            if sinceIndex >= 150 {
                rebuildIndex(folder)   // the list in the app and index.json grow while the import runs
                sinceIndex = 0
            }
        }
        settings.historyWorkoutCursor = start
        backlog.workoutsLeft = 0
        return written
    }

    /// "2026-10-23_1039_PoolSwim_CB7E8310.json" and its ".route.json" → "CB7E8310".
    nonisolated static func uuid8(ofFile name: String) -> String? {
        var stem = name
        if stem.hasSuffix(".json") { stem = String(stem.dropLast(5)) }
        if stem.hasSuffix(".route") { stem = String(stem.dropLast(6)) }
        guard let token = stem.split(separator: "_").last, token.count == 8 else { return nil }
        return String(token)
    }
}
