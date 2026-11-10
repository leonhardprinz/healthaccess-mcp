import Foundation

/// The contract's dedupe rule, applied to every list the app draws: same `start` (±2 s) and the same `source` are one
/// workout, the longer one stays. Rows without a source (an index written by someone else) fall back to the activity.
/// Nothing is ever deleted: the loser stays on disk and out of the list.
enum Dedupe {
    static let tolerance: TimeInterval = 2

    static func sameWorkout(_ a: IndexEntry, _ b: IndexEntry) -> Bool {
        guard abs(a.start.timeIntervalSince(b.start)) <= tolerance else { return false }
        if let sa = a.source, let sb = b.source { return sa == sb }
        return a.activity == b.activity
    }

    /// Newest first. `dropped` lists the files hidden by the rule.
    static func apply(_ entries: [IndexEntry]) -> (kept: [IndexEntry], dropped: [String]) {
        var kept: [IndexEntry] = []
        var dropped: [String] = []
        for entry in entries.sorted(by: { $0.start < $1.start }) {
            if let i = kept.lastIndex(where: { sameWorkout($0, entry) }) {
                if entry.durationS > kept[i].durationS {
                    dropped.append(kept[i].file)
                    kept[i] = entry
                } else {
                    dropped.append(entry.file)
                }
            } else {
                kept.append(entry)
            }
        }
        return (kept.reversed(), dropped)
    }
}

/// Rebuilds `index.json` from `workouts/*.json` (newest first, no series) through the dedupe rule.
enum IndexBuilder {
    struct Light: Decodable {
        let id: String
        let activity: String
        let source: String
        let start: Date
        let durationS: Int
        let distanceM: Double?
        let avgHr: Int?
        let effort: Int?
        let effortSource: String?
        let planRef: PlanRef?

        enum CodingKeys: String, CodingKey {
            case id, activity, source, start, effort
            case durationS = "duration_s"
            case distanceM = "distance_m"
            case avgHr = "avg_hr"
            case effortSource = "effort_source"
            case planRef = "plan_ref"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            activity = try c.decode(String.self, forKey: .activity)
            source = try c.decode(String.self, forKey: .source)
            start = try c.decode(Date.self, forKey: .start)
            durationS = min(max(try c.decode(Int.self, forKey: .durationS), 0), 31_536_000)
            distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
            avgHr = try c.decodeIfPresent(Int.self, forKey: .avgHr)
            if let value = try? c.decodeIfPresent(Int.self, forKey: .effort) {
                effort = (1...10).contains(value) ? value : nil
            } else {
                effort = try c.decodeIfPresent(Double.self, forKey: .effort).flatMap(score1to10)
            }
            effortSource = try c.decodeIfPresent(String.self, forKey: .effortSource)
            planRef = try c.decodeIfPresent(PlanRef.self, forKey: .planRef)
        }
    }

    struct Scan: Sendable {
        var entries: [IndexEntry] = []
        var skipped: [String] = []   // unreadable files (old schema, corrupt, not downloaded)
        var dropped: [String] = []   // dedupe losers, kept on disk but not listed
        /// workout id → `effort_source` for every listed file that has one.
        var effortSources: [String: String] = [:]
    }

    /// What the last scan read from each session file, kept in the app's own storage. A folder with years of sessions
    /// is then listed without opening every file on every sync: a file is read again only when its date changed.
    struct Cache: Codable {
        struct Row: Codable {
            /// Seconds since 1970 with the fraction kept (the JSON date format drops it).
            var modified: Double?
            var entry: IndexEntry
            var effortSource: String?
        }
        var root: String
        var rows: [String: Row] = [:]

        static var fileURL: URL {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            return dir.appendingPathComponent("index-cache.json")
        }

        static func load(root: String) -> Cache {
            guard let data = try? Data(contentsOf: fileURL), let cache = try? HealthAccessJSON.decode(Cache.self, from: data),
                  cache.root == root else { return Cache(root: root) }
            return cache
        }

        func save() {
            guard let data = try? HealthAccessJSON.encode(self) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    static func scan(folder: FolderStore) throws -> Scan {
        var scan = Scan()
        var all: [IndexEntry] = []
        let cache = Cache.load(root: folder.root.path)
        var next = Cache(root: folder.root.path)
        var changed = false
        let dates = folder.modificationDates("workouts")
        for name in try folder.list("workouts") where !name.hasSuffix(".route.json") {   // route sidecars are not sessions
            let path = "workouts/\(name)"
            let modified = dates[name]?.timeIntervalSince1970
            // Unchanged since the last scan, or not downloaded right now (no date): what we read last time still holds.
            if let row = cache.rows[name], row.entry.file == path, modified == nil || row.modified == modified {
                all.append(row.entry)
                if let source = row.effortSource { scan.effortSources[row.entry.id] = source }
                next.rows[name] = row
                continue
            }
            changed = true
            do {
                guard let data = try folder.read(path) else { continue }
                let light = try HealthAccessJSON.decode(Light.self, from: data)
                let entry = IndexEntry(id: light.id, file: path, activity: light.activity, start: light.start, durationS: light.durationS,
                                       distanceM: light.distanceM, avgHr: light.avgHr, effort: light.effort, planName: light.planRef?.name,
                                       source: light.source)
                all.append(entry)
                if let source = light.effortSource { scan.effortSources[light.id] = source }
                // The date from before the read: a write that lands in between is seen as a change next time.
                next.rows[name] = Cache.Row(modified: modified, entry: entry, effortSource: light.effortSource)
            } catch {
                scan.skipped.append(name)
            }
        }
        if changed || next.rows.count != cache.rows.count { next.save() }
        let result = Dedupe.apply(all)
        scan.entries = result.kept
        scan.dropped = result.dropped
        return scan
    }

    /// Scans and writes `index.json`.
    @discardableResult
    static func rebuild(folder: FolderStore) throws -> (doc: IndexDoc, scan: Scan) {
        let scan = try scan(folder: folder)
        let doc = IndexDoc(updated: Date(), workouts: scan.entries)
        try folder.write(try HealthAccessJSON.encode(doc), to: "index.json")
        return (doc, scan)
    }

    /// Loads `index.json` and passes it through the rule again, in case another writer left duplicates in it.
    static func load(folder: FolderStore) throws -> IndexDoc? {
        guard let data = try folder.read("index.json") else { return nil }
        var doc = try HealthAccessJSON.decode(IndexDoc.self, from: data)
        // index.json can be written by another program: keep its durations in the range the session files are held to.
        for i in doc.workouts.indices { doc.workouts[i].durationS = min(max(doc.workouts[i].durationS, 0), 31_536_000) }
        doc.workouts = Dedupe.apply(doc.workouts).kept
        return doc
    }
}
