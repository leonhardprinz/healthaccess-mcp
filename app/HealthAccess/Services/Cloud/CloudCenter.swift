import Foundation
import Observation

/// The cloud drives the user connected, and what their mirrors are doing. The UI reads `status`; the model
/// asks for runs. Whether a drive is on is a setting; the sign-in itself is in the keychain.
@MainActor
@Observable
final class CloudCenter {
    struct Status: Equatable {
        var connected = false
        /// The drive refused the stored sign-in. The upload stops until the user connects again.
        var needsSignIn = false
        var busy = false
        var progress: CloudMirror.Progress?
        var lastRun: Date?
        var lastError: String?
        /// Files of the folder that are on the drive.
        var files = 0
        /// Files that did not fit into the last run.
        var waiting = 0
        /// Files that are in iCloud only right now.
        var inICloud = 0
    }

    let config: CloudConfig
    private(set) var status: [CloudKind: Status] = [:]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let session = CloudHTTP.makeSession()
    @ObservationIgnored private var tokens: [CloudKind: TokenSource] = [:]
    @ObservationIgnored private var mirrors: [CloudKind: CloudMirror] = [:]

    init(config: CloudConfig = .shared) {
        self.config = config
        for kind in CloudKind.allCases {
            var entry = Status()
            let on = defaults.bool(forKey: Self.key(kind))
            if on, config.offers(kind), CloudKeychain.load(kind) != nil {
                entry.connected = true
                let state = CloudMirror.loadState(CloudMirror.stateURL(kind))
                entry.lastRun = state.lastRun
                entry.files = state.files.count
            } else if !on {
                // The keychain outlives a deleted app. A sign-in without the setting is from an earlier install.
                CloudKeychain.delete(kind)
            }
            status[kind] = entry
        }
    }

    private static func key(_ kind: CloudKind) -> String { AppSettings.key("cloud.\(kind.rawValue)") }

    /// The drives this build can offer.
    var kinds: [CloudKind] { config.kinds }
    var connected: [CloudKind] { kinds.filter { status[$0]?.connected == true && status[$0]?.needsSignIn == false } }
    var isUploading: Bool { status.values.contains(where: \.busy) }
    /// Drives whose sign-in ran out: the upload stands still until the user connects again.
    var needingSignIn: [CloudKind] { kinds.filter { status[$0]?.needsSignIn == true } }
    /// Files left over from the last runs, over all drives.
    var waiting: Int { connected.reduce(0) { $0 + (status[$1]?.waiting ?? 0) } }

    /// "Wi-Fi only": nothing is uploaded over mobile data. Low Data Mode always holds uploads back.
    var wifiOnly: Bool {
        get { access(keyPath: \.wifiOnly); return defaults.bool(forKey: CloudHTTP.wifiOnlyKey) }
        set { withMutation(keyPath: \.wifiOnly) { defaults.set(newValue, forKey: CloudHTTP.wifiOnlyKey) } }
    }

    func state(_ kind: CloudKind) -> Status { status[kind] ?? Status() }

    private func oauth(_ kind: CloudKind) throws -> OAuthConfig {
        guard config.offers(kind), let id = config.ids[kind] else { throw CloudError.notConfigured }
        return OAuthConfig.make(kind, clientID: id, secret: config.secrets[kind])
    }

    private func tokenSource(_ kind: CloudKind) throws -> TokenSource {
        if let source = tokens[kind] { return source }
        let source = TokenSource(config: try oauth(kind), session: session)
        tokens[kind] = source
        return source
    }

    /// The drive for a kind, from what is stored for it (or from `fields`, to try them before they are stored).
    private func drive(_ kind: CloudKind, folders: [String: String], fields: [String: String]? = nil) throws -> any CloudDrive {
        func secrets() throws -> [String: String] {
            guard let found = fields ?? CloudSecrets.load(kind) else { throw CloudError.notConnected }
            return found
        }
        switch kind {
        case .google: return GoogleDrive(http: CloudHTTP(session: session, tokens: try tokenSource(kind)), folders: folders)
        case .onedrive: return OneDrive(http: CloudHTTP(session: session, tokens: try tokenSource(kind)))
        case .dropbox: return Dropbox(http: CloudHTTP(session: session, tokens: try tokenSource(kind)))
        case .box: return BoxDrive(http: CloudHTTP(session: session, tokens: try tokenSource(kind)), folders: folders)
        case .pcloud:
            let stored = try secrets()
            guard let token = stored["token"], let host = stored["host"] else { throw CloudError.notConnected }
            return PCloudDrive(http: CloudHTTP(session: session, tokens: StaticBearer(token: token)), host: host)
        case .webdav:
            let stored = try secrets()
            let base = try WebDAVDrive.validate(stored["address"] ?? "")
            let user = (stored["user"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty, let password = stored["password"], !password.isEmpty else { throw CloudError.unexpected("Enter a user name and a password.") }
            return WebDAVDrive(http: CloudHTTP(session: session, tokens: BasicAuth(user: user, password: password)), base: base)
        case .s3:
            let target = try S3Target.make(try secrets())
            let signer = S3Signer(accessKey: target.accessKey, secretKey: target.secretKey, region: target.region)
            return S3Drive(http: CloudHTTP(session: session, tokens: signer), target: target)
        }
    }

    private func mirror(_ kind: CloudKind) throws -> CloudMirror {
        if let mirror = mirrors[kind] { return mirror }
        let url = CloudMirror.stateURL(kind)
        let state = CloudMirror.loadState(url)
        let mirror = CloudMirror(kind: kind, drive: try drive(kind, folders: state.folders), state: state, stateURL: url)
        mirrors[kind] = mirror
        return mirror
    }

    /// A new connection starts from nothing: it may be another account or another server, and what the last one
    /// held says nothing about this one. Files already there are found again by name.
    private func forget(_ kind: CloudKind) {
        if let old = mirrors[kind] { Task { await old.retire() } }
        mirrors[kind] = nil
        tokens[kind] = nil
        try? FileManager.default.removeItem(at: CloudMirror.stateURL(kind))
    }

    private func markConnected(_ kind: CloudKind) {
        defaults.set(true, forKey: Self.key(kind))
        var entry = state(kind)
        entry.connected = true
        entry.needsSignIn = false
        entry.lastError = nil
        status[kind] = entry
    }

    /// Opens the drive's sign-in. Returns when the long-lived sign-in is in the keychain.
    func connect(_ kind: CloudKind) async throws {
        let first = try await OAuthFlow.signIn(try oauth(kind), session: session)
        forget(kind)
        if kind != .pcloud { try await tokenSource(kind).adopt(first) }
        markConnected(kind)
    }

    /// A server or a storage the user typed in. The address, name and keys are tried with one harmless call
    /// (list the folder) before anything is stored.
    func connect(_ kind: CloudKind, fields: [String: String]) async throws {
        guard kind.access == .form else { throw CloudError.notConfigured }
        do {
            _ = try await drive(kind, folders: [:], fields: fields).list("")
        } catch CloudError.signInExpired {
            throw CloudError.unexpected("The server did not accept that user name and password.")
        } catch CloudError.http(403, _) {
            throw CloudError.unexpected(kind == .s3 ? "The storage did not accept that key for this bucket." : "The server does not allow that folder for this name.")
        } catch CloudError.http(404, _) where kind == .s3 {
            throw CloudError.unexpected("There is no such bucket at that address.")
        }
        CloudKeychain.save(try CloudSecrets.encode(fields), for: kind)
        forget(kind)
        markConnected(kind)
    }

    /// What the user typed, without the secrets: for the row that says where the copy goes.
    func place(_ kind: CloudKind) -> String {
        guard kind.access == .form, let stored = CloudSecrets.load(kind) else { return kind.place }
        switch kind {
        case .webdav:
            let host = URL(string: stored["address"] ?? "")?.host ?? "your server"
            return "Health Access on \(host)"
        case .s3:
            let prefix = (stored["prefix"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "bucket \(stored["bucket"] ?? "")" + (prefix.isEmpty ? "" : ", under \(prefix)")
        default: return kind.place
        }
    }

    /// The host an upload went to, for "What left this phone".
    func host(_ kind: CloudKind) -> String {
        guard kind.access == .form, let stored = CloudSecrets.load(kind) else { return kind.host }
        if kind == .webdav { return URL(string: stored["address"] ?? "")?.host ?? kind.host }
        let endpoint = stored["endpoint"] ?? ""
        if endpoint.isEmpty { return "amazonaws.com" }
        return URL(string: endpoint.contains("://") ? endpoint : "https://" + endpoint)?.host ?? kind.host
    }

    /// Stops the upload and forgets the sign-in and what was uploaded. The files on the drive stay; they are the user's.
    func disconnect(_ kind: CloudKind) {
        CloudKeychain.delete(kind)
        defaults.set(false, forKey: Self.key(kind))
        forget(kind)
        status[kind] = Status()
    }

    /// One run of one drive. `nil` when that drive is already running.
    func run(_ kind: CloudKind, folder: FolderStore, mode: CloudMirror.Mode, deadline: Date?) async -> Result<CloudMirror.Summary, Error>? {
        guard state(kind).connected, !state(kind).busy else { return nil }
        status[kind]?.busy = true
        defer {
            status[kind]?.busy = false
            status[kind]?.progress = nil
        }
        do {
            let mirror = try mirror(kind)
            let summary = try await mirror.run(folder: folder, mode: mode, deadline: deadline) { [weak self] progress in
                await MainActor.run { self?.status[kind]?.progress = progress }
            }
            let state = await mirror.state
            status[kind]?.lastRun = state.lastRun
            status[kind]?.files = state.files.count
            status[kind]?.needsSignIn = false
            status[kind]?.inICloud = summary.inICloud
            if mode == .full {
                status[kind]?.waiting = summary.remaining
                status[kind]?.lastError = summary.firstFailure
            }
            return .success(summary)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            if (error as? CloudError) == .signInExpired { status[kind]?.needsSignIn = true }
            status[kind]?.lastError = error.localizedDescription
            return .failure(error)
        }
    }
}
