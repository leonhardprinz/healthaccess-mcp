import Foundation

/// The user-picked export folder, kept as a security-scoped bookmark (works on a free personal team, no iCloud entitlement).
/// All paths are relative to the folder root: `workouts/…`, `vitals/…`, `plans/…`, `index.json`.
struct FolderStore: Sendable {
    let root: URL
    private static let bookmarkKey = AppSettings.key("folderBookmark")  // migrated from the pre-rename key by AppSettings

    static func save(_ url: URL) throws -> FolderStore {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return FolderStore(root: url)
    }

    static func restore() -> (store: FolderStore, stale: Bool)? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (FolderStore(root: url), stale)
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }

    /// Largest file the app reads from the folder.
    static let maxReadBytes = 64 * 1024 * 1024

    /// A path inside the folder: relative, no `..`, no NUL. Index rows and plan files are
    /// written by other programs, so every relative path is checked before it is used.
    static func inside(_ root: URL, _ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              !parts.contains(where: { $0 == ".." }) else {
            throw HealthAccessError("refused a path outside the folder")
        }
        return root.appendingPathComponent(relativePath)
    }

    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return try body(root)
    }

    /// Atomic, file-coordinated write; creates intermediate directories.
    func write(_ data: Data, to relativePath: String) throws {
        try withAccess { root in
            let dest = try Self.inside(root, relativePath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }
    }

    /// Coordinated read; `nil` when the file does not exist. Triggers the download of an iCloud placeholder.
    func read(_ relativePath: String) throws -> Data? {
        try withAccess { root in
            let url = try Self.inside(root, relativePath)
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
                guard fm.fileExists(atPath: placeholder.path) else { return nil }
                try? fm.startDownloadingUbiquitousItem(at: url)
            }
            var coordinationError: NSError?
            var readError: Error?
            var result: Data?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true else { throw HealthAccessError("not a regular file") }
                    guard (values.fileSize ?? 0) <= Self.maxReadBytes else { throw HealthAccessError("file too large") }
                    result = try Data(contentsOf: url)
                } catch { readError = error }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            return result
        }
    }

    func exists(_ relativePath: String) -> Bool {
        (try? withAccess { FileManager.default.fileExists(atPath: try Self.inside($0, relativePath).path) }) ?? false
    }

    /// File names (not paths) in a sub-directory with the given suffix, sorted. iCloud placeholders are reported under their real name.
    func list(_ relativeDirectory: String, suffix: String = ".json") throws -> [String] {
        try withAccess { root in
            let dir = try Self.inside(root, relativeDirectory)
            guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
            var names = Set<String>()
            for raw in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                var name = raw
                if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                }
                if name.hasSuffix(suffix) && !name.hasPrefix(".") { names.insert(name) }
            }
            return names.sorted()
        }
    }

    func modificationDate(_ relativePath: String) -> Date? {
        try? withAccess { root in
            try Self.inside(root, relativePath).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    /// Removes one file. Used for exactly one thing: Undo of a plan status the app itself wrote seconds earlier.
    func remove(_ relativePath: String) throws {
        try withAccess { root in
            let url = try Self.inside(root, relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var coordinationError: NSError?
            var removeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
                do { try FileManager.default.removeItem(at: url) } catch { removeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let removeError { throw removeError }
        }
    }

    /// A temporary copy outside the security scope, for the share sheet.
    func temporaryCopy(of relativePath: String) throws -> URL {
        guard let data = try read(relativePath) else { throw HealthAccessError("file is missing: \(relativePath)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((relativePath as NSString).lastPathComponent)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: where the folder lives

    /// The folder's own name, e.g. "Health Access". The only name the UI uses for it.
    var displayName: String { root.lastPathComponent }

    /// The storage provider, read from the bookmark URL when the path reveals it. Never assumed.
    var provider: StorageProvider? { StorageProvider.detect(root) }

    /// Where the same folder usually is on a Mac, known only for iCloud Drive.
    var macPathHint: String? {
        guard case .iCloudDrive = provider else { return nil }
        let path = root.path
        guard let range = path.range(of: "com~apple~CloudDocs/") else { return nil }
        let relative = String(path[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "~/Library/Mobile Documents/com~apple~CloudDocs/" + relative
    }

    /// "Health Access (iCloud Drive)" or just the name when the provider is unknown.
    var displayNameWithProvider: String {
        if let provider { return "\(displayName) (\(provider.name))" }
        return displayName
    }

    /// Short, human path: "iCloud Drive › Documents › Health Access".
    var displayPath: String {
        let path = root.path
        if let range = path.range(of: "com~apple~CloudDocs/") {
            return "iCloud Drive › " + path[range.upperBound...].split(separator: "/").joined(separator: " › ")
        }
        if let range = path.range(of: "/File Provider Storage/") {
            return path[range.upperBound...].split(separator: "/").joined(separator: " › ")
        }
        return root.pathComponents.suffix(3).joined(separator: " › ")
    }
}

/// What the Files app calls the place a folder lives. Detected from the resolved bookmark URL only.
enum StorageProvider: Sendable, Equatable {
    case iCloudDrive
    case onMyiPhone
    case smb
    case named(String)   // an iCloud app container or a provider whose name the path reveals

    var name: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .onMyiPhone: return "On My iPhone"
        case .smb: return "SMB server"
        case .named(let name): return name
        }
    }

    static func detect(_ url: URL) -> StorageProvider? {
        let path = url.path
        if path.contains("Mobile Documents/com~apple~CloudDocs") { return .iCloudDrive }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return .iCloudDrive }
        if let range = path.range(of: "Mobile Documents/") {
            // e.g. "iCloud~com~getdropbox~Dropbox" → "Dropbox"
            let container = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            if let last = container.split(separator: "~").last, !last.isEmpty { return .named(String(last)) }
        }
        if path.contains("/LiveFiles/com.apple.filesystems.smbclientd/") { return .smb }
        if path.contains("/LiveFiles/com.apple.filesystems.userfsd/") { return .named("External drive") }
        if path.contains("/Containers/Data/Application/") && path.contains("/Documents") { return .onMyiPhone }
        return nil
    }
}
