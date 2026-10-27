import Foundation

/// The tag in square brackets at the start of every Sync log line. These words are user-visible.
enum LogTag: String {
    case launch, sync, observer, refresh, plan, rating, ui, error, health, folder, vitals, usage, briefing
}

/// Append-only text log in Application Support, so wakes while the app was closed can be verified after the fact.
actor DiskLog {
    static let shared = DiskLog()

    let fileURL: URL
    private var lines: [String] = []
    private var loaded = false
    private var appendsSinceRewrite = 0
    private let maxLines = 3000

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("HealthAccess", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("healthaccess-log.txt")
        Self.migrateLegacyLog(base: base, to: fileURL)
    }

    /// Before the rename the log lived at `Application Support/Tide/tide-log.txt` (alias location). Move it once, so the
    /// history survives; the old directory is removed when that leaves it empty.
    private static func migrateLegacyLog(base: URL, to current: URL) {
        let fm = FileManager.default
        let legacyDir = base.appendingPathComponent("Tide", isDirectory: true)  // alias: pre-rename directory
        let legacy = legacyDir.appendingPathComponent("tide-log.txt")  // alias: pre-rename file name
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
        if let rest = try? fm.contentsOfDirectory(atPath: legacyDir.path), rest.isEmpty {
            try? fm.removeItem(at: legacyDir)
        }
    }

    func load() -> [String] {
        if !loaded {
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            loaded = true
        }
        return lines
    }

    @discardableResult
    func append(_ line: String) -> [String] {
        _ = load()
        let clean = line.replacingOccurrences(of: "\n", with: " ")
        lines.append(clean)
        appendsSinceRewrite += 1
        if lines.count > maxLines || appendsSinceRewrite >= 500 {
            lines = Array(lines.suffix(maxLines))
            rewrite()
            appendsSinceRewrite = 0
            return lines
        }
        if FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((clean + "\n").utf8))
            } catch {
                rewrite()
            }
        } else {
            rewrite()
        }
        return lines
    }

    func clear() {
        lines = []
        loaded = true
        rewrite()
    }

    private func rewrite() {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
