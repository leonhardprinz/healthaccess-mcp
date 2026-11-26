import Foundation

/// A file in the Health Access folder on the phone, as the mirror sees it.
struct LocalFile: Sendable, Equatable {
    let path: String
    let size: Int
    let modified: Date

    /// Changes when the file does. Size and the second it was written are enough: the app writes whole files.
    var sig: String { "\(size)-\(Int(modified.timeIntervalSince1970))" }
}

/// What the mirror remembers between runs, per drive. Lives in the app's own storage, not in the folder.
struct CloudState: Codable, Sendable, Equatable {
    struct FileState: Codable, Sendable, Equatable {
        /// The local file's `sig` at the upload. `nil`: known on the drive, content not compared yet.
        var sig: String?
        var ref: RemoteRef
    }

    /// Local path → what is on the drive for it.
    var files: [String: FileState] = [:]
    /// Files that exist only on the drive: the guide for the AI and the plan inbox.
    var cloudOnly: [String: FileState] = [:]
    var folders: [String: String] = [:]
    /// The drive was looked through once for files from an earlier install.
    var adopted = false
    /// The inbox as it was when last read.
    var inboxRev: String?
    var lastRun: Date?
    var uploadedTotal = 0
    var pulledTotal = 0
}

/// The decisions of the mirror, without any network or disk: what to upload, what to fetch, what a plan is called.
enum CloudPlanner {
    static let guidePath = "README.md"
    /// Where the guide goes when the folder has a `README.md` of its own, which is then uploaded as it is.
    static let guidePathBesideOwn = "README-health-access.md"
    static let inboxPath = "plans/inbox.json"
    /// Written last in every run, so they never describe files that are not uploaded yet for long.
    static let lastFiles: Set<String> = ["index.json", "briefing.md", "catalog.json", "profile.json"]
    static let maxPlanBytes = 256 * 1024

    /// Files that are new or changed since their last upload: newest first, the overview files at the end.
    static func uploads(local: [LocalFile], state: [String: CloudState.FileState]) -> (main: [LocalFile], last: [LocalFile]) {
        let changed = local.filter { state[$0.path]?.sig != $0.sig }
        let main = changed.filter { !lastFiles.contains($0.path) }.sorted { ($0.modified, $0.path) > ($1.modified, $1.path) }
        let last = changed.filter { lastFiles.contains($0.path) }.sorted { $0.path < $1.path }
        return (main, last)
    }

    /// Plan status files the app removed again (Undo). Nothing else is ever deleted on the drive: a file missing
    /// on the phone may only be waiting in iCloud.
    static func removedStatusFiles(local: Set<String>, state: [String: CloudState.FileState]) -> [String] {
        state.keys.filter { $0.hasPrefix("plans/") && $0.hasSuffix(".status.json") && !local.contains($0) }.sorted()
    }

    /// Plan files in the drive's `plans` folder that did not come from this phone.
    static func newPlans(remote: [RemoteEntry], knownIDs: Set<String>) -> [RemoteEntry] {
        remote.filter { entry in
            !entry.isFolder && entry.size <= maxPlanBytes && !knownIDs.contains(entry.ref.id)
                && isPlanName(entry.name) && entry.name != "inbox.json"
        }.sorted { $0.name < $1.name }
    }

    /// A name the app accepts for a file it writes into `plans/`: no path parts, nothing hidden, `.json`, not a status file.
    static func isPlanName(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), !name.hasSuffix(".status.json"), !name.hasPrefix("."), name.count <= 140 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.: ".unicodeScalars.contains($0) }
    }

    /// The plans in the inbox: one plan object, or a list of them. Each gets a file name from its own `id`, or
    /// from its content when it has none, so reading the same inbox twice writes nothing twice.
    static func inboxPlans(_ data: Data) -> [(name: String, data: Data)] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let objects = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        var out: [(String, Data)] = []
        for object in objects where !object.isEmpty {
            guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
                  body.count <= maxPlanBytes else { continue }
            var name = "inbox-\(body.sha256Hex.prefix(10)).json"
            if let id = object["id"] as? String, isPlanName(id + ".json") { name = id + ".json" }
            if !out.contains(where: { $0.0 == name }) { out.append((name, body)) }
        }
        return out
    }
}

enum CloudScanner {
    struct Scan: Sendable {
        var files: [LocalFile] = []
        /// Files of an iCloud Drive folder that iOS moved off the phone to save space. They cannot be read until
        /// iOS has fetched them again.
        var inICloud: [String] = []
    }

    /// Every file in the folder that belongs on the drive. Left out: hidden files, the handshake files of MCP
    /// servers, and anything too large to read. iCloud's placeholders are reported apart.
    static func scan(_ folder: FolderStore) throws -> [LocalFile] { try survey(folder).files }

    static func survey(_ folder: FolderStore) throws -> Scan {
        try folder.withAccess { root in
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return Scan() }
            let base = root.standardizedFileURL.path
            var scan = Scan()
            for case let url as URL in walker {
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(base + "/") else { continue }
                var path = String(full.dropFirst(base.count + 1))
                let name = url.lastPathComponent
                if name.hasPrefix(".") {
                    // ".2026-11-18.json.icloud" stands for "2026-11-18.json".
                    if name.hasSuffix(".icloud"), name.count > 8 {
                        path = CloudPath.join(CloudPath.split(path).directory, String(name.dropFirst().dropLast(".icloud".count)))
                        if !skipped(path) { scan.inICloud.append(path) }
                    } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.fileSize, let modified = values.contentModificationDate, size <= FolderStore.maxReadBytes else { continue }
                if skipped(path) { continue }
                scan.files.append(LocalFile(path: path, size: size, modified: modified))
            }
            return scan
        }
    }

    private static func skipped(_ path: String) -> Bool {
        path.hasPrefix("mcp/") || path == CloudPlanner.inboxPath || path == CloudPlanner.guidePathBesideOwn
    }

    /// Asks iOS to bring placeholder files back onto the phone. They are uploaded by the run after they arrive.
    static func fetch(_ paths: [String], in folder: FolderStore) {
        _ = try? folder.withAccess { root in
            for path in paths {
                if let url = try? FolderStore.inside(root, path) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            }
        }
    }

    static func file(_ path: String, in folder: FolderStore) -> LocalFile? {
        try? folder.withAccess { root in
            let url = try FolderStore.inside(root, path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate else { throw HealthAccessError("no attributes") }
            return LocalFile(path: path, size: size, modified: modified)
        }
    }
}

/// Keeps one drive in step with the folder on the phone: uploads what is new or changed, and brings back
/// the workout plans an AI left on the drive. The folder on the phone stays the original; the drive is a copy.
actor CloudMirror {
    struct Summary: Sendable, Equatable {
        var uploaded = 0
        var unchanged = 0
        var pulled = 0
        var removed = 0
        var failed = 0
        /// Files still waiting when the time for this run was over.
        var remaining = 0
        /// Files that are in iCloud only and were asked back; they go up once the phone has them.
        var inICloud = 0
        var firstFailure: String?
    }

    struct Progress: Sendable, Equatable {
        let done: Int
        let total: Int
    }

    enum Mode: Sendable { case full, plansOnly }

    private enum Outcome: Sendable {
        case uploaded(LocalFile, RemoteRef)
        case same(LocalFile, RemoteRef)
        case gone(String)
        case failed(String, String)
    }

    let kind: CloudKind
    private let drive: any CloudDrive
    private let stateURL: URL?
    private(set) var state: CloudState
    /// Set when the drive was disconnected: a run that is still winding down must not write its state back.
    private var retired = false

    func retire() { retired = true }

    init(kind: CloudKind, drive: any CloudDrive, state: CloudState = CloudState(), stateURL: URL? = nil) {
        self.kind = kind
        self.drive = drive
        self.state = state
        self.stateURL = stateURL
    }

    static func stateURL(_ kind: CloudKind) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cloud", isDirectory: true)
        return base.appendingPathComponent("\(kind.rawValue).json")
    }

    static func loadState(_ url: URL) -> CloudState {
        (try? JSONDecoder().decode(CloudState.self, from: Data(contentsOf: url))) ?? CloudState()
    }

    private func save() {
        guard let stateURL, !retired else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func remotePath(_ path: String) -> String {
        let (directory, name) = CloudPath.split(path)
        return CloudPath.join(directory, drive.remoteName(name))
    }

    /// One run. `deadline` bounds the uploads when iOS gave the app only a moment; what is left goes next time.
    func run(folder: FolderStore, mode: Mode, deadline: Date? = nil,
             progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async throws -> Summary {
        var summary = Summary()
        defer {
            state.lastRun = Date()
            save()
        }
        let survey = try CloudScanner.survey(folder)
        var local = survey.files
        if !survey.inICloud.isEmpty {
            summary.inICloud = survey.inICloud.count
            if mode == .full { CloudScanner.fetch(Array(survey.inICloud.prefix(200)), in: folder) }
        }
        if !state.adopted { try await adopt(local) }

        summary.pulled = try await pullPlans(into: folder)
        state.pulledTotal += summary.pulled
        if mode == .plansOnly { return summary }
        if summary.pulled > 0 { local = try CloudScanner.scan(folder) }

        try await writeGuide(ownReadme: local.contains { $0.path == CloudPlanner.guidePath })

        let queue = CloudPlanner.uploads(local: local, state: state.files)
        let total = queue.main.count + queue.last.count
        var done = 0
        await progress(Progress(done: 0, total: total))

        func apply(_ outcome: Outcome) {
            switch outcome {
            case .uploaded(let file, let ref):
                state.files[file.path] = .init(sig: file.sig, ref: ref)
                state.uploadedTotal += 1
                summary.uploaded += 1
            case .same(let file, let ref):
                state.files[file.path] = .init(sig: file.sig, ref: ref)
                summary.unchanged += 1
            case .gone:
                break
            case .failed(_, let text):
                summary.failed += 1
                if summary.firstFailure == nil { summary.firstFailure = text }
            }
        }

        var waiting = queue.main[...]
        let drive = self.drive
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var running = 0
            func inTime() -> Bool { deadline.map { Date() < $0 } ?? true }
            while running < kind.parallelUploads, inTime(), let file = waiting.popFirst() {
                let known = state.files[file.path]
                let target = remotePath(file.path)
                group.addTask { try await Self.upload(file, to: target, known: known, drive: drive, folder: folder) }
                running += 1
            }
            while let outcome = try await group.next() {
                running -= 1
                apply(outcome)
                done += 1
                if done % 25 == 0 { save() }
                await progress(Progress(done: done, total: total))
                if inTime(), let file = waiting.popFirst() {
                    let known = state.files[file.path]
                    let target = remotePath(file.path)
                    group.addTask { try await Self.upload(file, to: target, known: known, drive: drive, folder: folder) }
                    running += 1
                }
            }
        }
        summary.remaining = waiting.count

        for file in queue.last {
            apply(try await Self.upload(file, to: remotePath(file.path), known: state.files[file.path], drive: drive, folder: folder))
            done += 1
            await progress(Progress(done: done, total: total))
        }

        for path in CloudPlanner.removedStatusFiles(local: Set(local.map(\.path)), state: state.files) {
            if let known = state.files[path] {
                try await drive.delete(known.ref)
                state.files[path] = nil
                summary.removed += 1
            }
        }
        state.folders = await drive.folderCache()
        return summary
    }

    /// Reads one file and sends it. A problem with this one file is reported and the run goes on; a lost
    /// connection or a sign-in that ran out ends the run.
    private static func upload(_ file: LocalFile, to target: String, known: CloudState.FileState?,
                               drive: any CloudDrive, folder: FolderStore) async throws -> Outcome {
        do {
            guard let data = try folder.read(file.path) else { return .gone(file.path) }
            if let known, known.sig == nil, let rev = drive.rev(of: data), !rev.isEmpty, rev == known.ref.rev {
                return .same(file, known.ref)
            }
            return .uploaded(file, try await drive.put(data, at: target, known: known?.ref))
        } catch let error as CloudError where error.endsRun {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(file.path, "\(file.path): \(error.localizedDescription)")
        }
    }

    /// After a reinstall or a reconnect the drive already holds the files. Finding them by name avoids a second
    /// copy of each (Google Drive allows two files of one name) and lets unchanged ones be skipped.
    private func adopt(_ local: [LocalFile]) async throws {
        var byDirectory: [String: [LocalFile]] = [:]
        for file in local { byDirectory[CloudPath.split(file.path).directory, default: []].append(file) }
        for (directory, files) in byDirectory.sorted(by: { $0.key < $1.key }) {
            let remote = try await drive.list(directory)
            guard !remote.isEmpty else { continue }
            var byName: [String: RemoteEntry] = [:]
            for entry in remote where !entry.isFolder && byName[entry.name] == nil { byName[entry.name] = entry }
            for file in files where state.files[file.path] == nil {
                if let entry = byName[drive.remoteName(CloudPath.split(file.path).name)] {
                    state.files[file.path] = .init(sig: nil, ref: entry.ref)
                }
            }
        }
        state.adopted = true
        save()
    }

    /// The way back: plan files someone else put into the drive's `plans` folder, and the plans in the inbox.
    /// Each becomes a file in `plans/` on the phone, where the app finds it like any other plan.
    private func pullPlans(into folder: FolderStore) async throws -> Int {
        let remote = try await drive.list("plans")
        var pulled = 0
        var known = Set(state.files.values.map(\.ref.id))
        known.formUnion(state.cloudOnly.values.map(\.ref.id))

        for entry in CloudPlanner.newPlans(remote: remote, knownIDs: known) {
            let path = "plans/\(entry.name)"
            if !folder.exists(path) {
                let data = try await drive.get(entry.ref)
                guard data.count <= CloudPlanner.maxPlanBytes else { continue }
                try folder.write(data, to: path)
                pulled += 1
            }
            // Either way the phone's file and the drive's file are now the same plan: nothing to upload for it.
            state.files[path] = .init(sig: CloudScanner.file(path, in: folder)?.sig, ref: entry.ref)
        }

        // The inbox: a file this app made, which an AI that cannot make files here can still edit.
        let inbox = remote.first { $0.name == "inbox.json" && !$0.isFolder }
        if let inbox {
            let seen = state.cloudOnly[CloudPlanner.inboxPath]
            if seen?.ref.id != inbox.ref.id || state.inboxRev != inbox.ref.rev {
                if inbox.size <= CloudPlanner.maxPlanBytes * 8 {
                    for plan in CloudPlanner.inboxPlans(try await drive.get(inbox.ref)) where !folder.exists("plans/\(plan.name)") {
                        try folder.write(plan.data, to: "plans/\(plan.name)")
                        pulled += 1
                    }
                }
                state.cloudOnly[CloudPlanner.inboxPath] = .init(sig: nil, ref: inbox.ref)
                state.inboxRev = inbox.ref.rev
            }
        } else {
            let ref = try await drive.put(Data("[]\n".utf8), at: CloudPlanner.inboxPath, known: nil)
            state.cloudOnly[CloudPlanner.inboxPath] = .init(sig: nil, ref: ref)
            state.inboxRev = ref.rev
        }
        return pulled
    }

    /// `README.md` on the drive tells an AI that reads the drive directly what the files are and how to send a plan.
    private func writeGuide(ownReadme: Bool) async throws {
        let path = ownReadme ? CloudPlanner.guidePathBesideOwn : CloudPlanner.guidePath
        let text = Data(PlanGuide.text(for: kind).utf8)
        let sig = String(text.sha256Hex.prefix(16))
        let seen = state.cloudOnly[path]
        guard seen?.sig != sig else { return }
        let ref = try await drive.put(text, at: path, known: seen?.ref)
        state.cloudOnly[path] = .init(sig: sig, ref: ref)
        // The guide moved aside for the folder's own README.md: that file now owns the name.
        if ownReadme { state.cloudOnly[CloudPlanner.guidePath] = nil }
    }
}
