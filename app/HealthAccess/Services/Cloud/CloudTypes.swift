import CryptoKit
import Foundation

/// The cloud drives the app can upload a copy of the folder to, itself, after a sign-in.
/// The iOS folder picker cannot reach them: these storage apps do not let other apps open their folders.
enum CloudKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case google, onedrive, dropbox, box, pcloud, webdav, s3

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google Drive"
        case .onedrive: return "OneDrive"
        case .dropbox: return "Dropbox"
        case .box: return "Box"
        case .pcloud: return "pCloud"
        case .webdav: return "WebDAV server"
        case .s3: return "S3 storage"
        }
    }

    /// One line under the name in Settings: what this entry covers.
    var covers: String? {
        switch self {
        case .webdav: return "Nextcloud, ownCloud, a NAS, Koofr and others"
        case .s3: return "Amazon S3, Cloudflare R2, Backblaze B2, MinIO and others"
        default: return nil
        }
    }

    /// Where the copy shows up in that drive.
    var place: String {
        switch self {
        case .google: return "My Drive › Health Access"
        case .onedrive: return "Apps › Health Access"
        case .dropbox: return "Apps › Health Access"
        case .box: return "All Files › Health Access"
        case .pcloud: return "the app's own folder in your pCloud"
        case .webdav: return "a Health Access folder on your server"
        case .s3: return "your bucket, under the prefix you set"
        }
    }

    /// Host shown in "What left this phone". A server of the user's own is named by the mirror from its address.
    var host: String {
        switch self {
        case .google: return "googleapis.com"
        case .onedrive: return "graph.microsoft.com"
        case .dropbox: return "dropboxapi.com"
        case .box: return "api.box.com"
        case .pcloud: return "pcloud.com"
        case .webdav: return "your WebDAV server"
        case .s3: return "your S3 storage"
        }
    }

    /// How the user connects: a sign-in on the drive's own page, or an address and a password typed into the app.
    enum Access: Sendable { case signIn, form }
    var access: Access { self == .webdav || self == .s3 ? .form : .signIn }

    /// Whether the app is limited to one folder there. Box has no such permission: an app sees the whole account.
    var folderOnly: Bool { self != .box }

    /// Whether the app can see a file that someone else put into its folder. OneDrive and Dropbox give an app
    /// its own folder with everything in it. Google's `drive.file` access shows an app only the files it created
    /// itself, so there a plan comes back through `plans/inbox.json`, a file the app made and the AI edits.
    var seesForeignFiles: Bool { self != .google }

    /// Uploads at once. Dropbox locks the whole folder for each write, so more than two only collide.
    var parallelUploads: Int { [.dropbox, .pcloud, .webdav].contains(self) ? 2 : 4 }
}

/// The client ids of the sign-ins, from `CloudConfig.plist` (not in the repository; see the example file).
/// A drive that needs a sign-in and has no id is not offered anywhere in the app. WebDAV and S3 need none.
struct CloudConfig: Sendable {
    let ids: [CloudKind: String]
    /// Box gives no sign-in without a client secret, also to an app.
    let secrets: [CloudKind: String]

    static let shared = CloudConfig(bundle: .main)

    init(ids: [CloudKind: String], secrets: [CloudKind: String] = [:]) {
        self.ids = ids
        self.secrets = secrets
    }

    init(bundle: Bundle) {
        var ids: [CloudKind: String] = [:]
        var secrets: [CloudKind: String] = [:]
        if let url = bundle.url(forResource: "CloudConfig", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            func value(_ key: String) -> String? {
                guard let value = (dict[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty, !value.hasPrefix("your-") else { return nil }
                return value
            }
            let keys: [CloudKind: String] = [.google: "GoogleClientID", .onedrive: "MicrosoftClientID", .dropbox: "DropboxAppKey",
                                             .box: "BoxClientID", .pcloud: "PCloudClientID"]
            for (kind, key) in keys { ids[kind] = value(key) }
            secrets[.box] = value("BoxClientSecret")
        }
        self.ids = ids
        self.secrets = secrets
    }

    func offers(_ kind: CloudKind) -> Bool {
        switch kind {
        case .webdav, .s3: return true
        case .box: return ids[kind] != nil && secrets[kind] != nil
        default: return ids[kind] != nil
        }
    }

    var kinds: [CloudKind] { CloudKind.allCases.filter(offers) }
}

/// A file as the drive knows it: its id there, and a value that changes when its content changes.
struct RemoteRef: Codable, Sendable, Equatable {
    var id: String
    var rev: String
}

struct RemoteEntry: Sendable, Equatable {
    let name: String
    let ref: RemoteRef
    let size: Int
    let isFolder: Bool
}

enum CloudError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case notConnected
    /// The drive refused the stored sign-in (revoked, or unused for too long). The user signs in again.
    case signInExpired
    case cancelled
    case offline
    /// The drive keeps answering "slow down". The run stops and goes on with the next sync.
    case slowDown
    /// The phone is on mobile data or in Low Data Mode, and the upload waits for Wi-Fi.
    case waitingForWiFi
    /// The server cannot be reached the way it was entered: no such address, no trusted certificate, no local network access.
    case unreachable(String)
    case http(Int, String)
    case unexpected(String)

    /// Whether trying the next file makes no sense: the whole run stops with this error.
    var endsRun: Bool {
        switch self {
        case .http, .unexpected, .cancelled: return false
        default: return true
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "This build has no sign-in for that drive."
        case .notConnected: return "Not connected."
        case .signInExpired: return "The sign-in ran out. Connect again."
        case .cancelled: return "Sign-in cancelled."
        case .offline: return "No connection. The upload runs again on the next sync."
        case .slowDown: return "The drive asked to slow down. The upload goes on with the next sync."
        case .waitingForWiFi: return "Waiting for Wi-Fi."
        case .unreachable(let text): return text
        case .http(let status, let text): return "The drive answered \(status)\(text.isEmpty ? "" : ": \(text)")"
        case .unexpected(let text): return text
        }
    }
}

/// What every drive can do for the mirror. Paths are relative to the Health Access folder, with `/` between parts.
protocol CloudDrive: Actor {
    /// Creates the file or replaces its content. `known` is what the last upload of this path returned.
    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef
    /// The files and folders directly inside a directory ("" is the top). A directory that is not there is empty.
    func list(_ directory: String) async throws -> [RemoteEntry]
    func get(_ ref: RemoteRef) async throws -> Data
    func delete(_ ref: RemoteRef) async throws
    /// Ids the drive needs again next time (Google's folder ids). Saved with the mirror's state.
    func folderCache() -> [String: String]
    /// The name a local file gets on this drive. OneDrive refuses some characters that plan names carry.
    nonisolated func remoteName(_ localName: String) -> String
    /// The value `RemoteRef.rev` would have for this content, when the drive's rev is a plain hash of it.
    nonisolated func rev(of data: Data) -> String?
}

extension CloudDrive {
    nonisolated func remoteName(_ localName: String) -> String { CloudPath.safeName(localName) }
    nonisolated func rev(of data: Data) -> String? { nil }
}

enum CloudPath {
    /// A name every drive and every computer that syncs it accepts. Plan files carry a time with colons, which
    /// OneDrive refuses and which breaks the Windows sync of Dropbox, Box, pCloud and Nextcloud.
    static func safeName(_ name: String) -> String {
        String(name.map { "\"*:<>?\\|".contains($0) ? "_" : $0 })
    }

    static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "json": return "application/json"
        case "md": return "text/markdown"
        case "gpx": return "application/gpx+xml"
        case "txt", "csv": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// A path segment for a URL: everything outside letters, digits and `-._~` is percent-encoded.
    static func encodeSegment(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    static func encode(_ path: String) -> String {
        path.split(separator: "/").map { encodeSegment(String($0)) }.joined(separator: "/")
    }
}

extension Data {
    var md5Hex: String { Insecure.MD5.hash(data: self).map { String(format: "%02x", $0) }.joined() }
    var sha1Hex: String { Insecure.SHA1.hash(data: self).map { String(format: "%02x", $0) }.joined() }
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
