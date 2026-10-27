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

    static func scan(folder: FolderStore) throws -> Scan {
        var scan = Scan()
        var all: [IndexEntry] = []
        for name in try folder.list("workouts") {
            let path = "workouts/\(name)"
            do {
                guard let data = try folder.read(path) else { continue }
                let light = try HealthAccessJSON.decode(Light.self, from: data)
                all.append(IndexEntry(id: light.id, file: path, activity: light.activity, start: light.start, durationS: light.durationS,
                                      distanceM: light.distanceM, avgHr: light.avgHr, effort: light.effort, planName: light.planRef?.name,
                                      source: light.source))
                if let source = light.effortSource { scan.effortSources[light.id] = source }
            } catch {
                scan.skipped.append(name)
            }
        }
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
        doc.workouts = Dedupe.apply(doc.workouts).kept
        return doc
    }
}
