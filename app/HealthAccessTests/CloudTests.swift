import XCTest
@testable import HealthAccess

// MARK: - helpers

/// A drive in memory. Paths are the keys; ids are "id-<n>"; the rev is the MD5 of the content, as on Google Drive.
actor FakeDrive: CloudDrive {
    struct Stored { var id: String; var data: Data }
    var files: [String: Stored] = [:]
    var puts: [String] = []
    var deletes: [String] = []
    var lists = 0
    var failPaths: Set<String> = []
    var offline = false
    var hashRev = true
    private var counter = 0
    let forbidColon: Bool

    init(forbidColon: Bool = false) { self.forbidColon = forbidColon }

    nonisolated func remoteName(_ localName: String) -> String { CloudPath.safeName(localName) }
    nonisolated func rev(of data: Data) -> String? { data.md5Hex }
    func folderCache() -> [String: String] { ["": "root-id"] }

    func setOffline(_ value: Bool) { offline = value }
    func fail(_ path: String) { failPaths.insert(path) }
    func resetLog() { puts = []; deletes = []; lists = 0 }

    /// What another app (an AI's connector) would do: a new file, or an edit of an existing one.
    func plant(_ path: String, _ text: String) {
        counter += 1
        if var existing = files[path] { existing.data = Data(text.utf8); files[path] = existing } else { files[path] = Stored(id: "id-\(counter)", data: Data(text.utf8)) }
    }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        if offline { throw CloudError.offline }
        if failPaths.contains(path) { throw CloudError.http(400, "bad name") }
        puts.append(path)
        counter += 1
        let id = files[path]?.id ?? "id-\(counter)"
        files[path] = Stored(id: id, data: data)
        return RemoteRef(id: id, rev: data.md5Hex)
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        if offline { throw CloudError.offline }
        lists += 1
        return files.compactMap { path, stored in
            let (dir, name) = CloudPath.split(path)
            guard dir == directory else { return nil }
            return RemoteEntry(name: name, ref: RemoteRef(id: stored.id, rev: stored.data.md5Hex), size: stored.data.count, isFolder: false)
        }
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        guard let stored = files.values.first(where: { $0.id == ref.id }) else { throw CloudError.http(404, "") }
        return stored.data
    }

    func delete(_ ref: RemoteRef) async throws {
        if let path = files.first(where: { $0.value.id == ref.id })?.key {
            files[path] = nil
            deletes.append(path)
        }
    }
}

final class StubProtocol: URLProtocol {
    struct Answer { var status = 200; var headers: [String: String] = [:]; var body = Data() }
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Answer)?
    nonisolated(unsafe) static var seen: [(request: URLRequest, body: Data)] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset(_ handler: @escaping (URLRequest, Data) -> Answer) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        seen = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.seen.append((request, body))
        let answer = Self.handler?(request, body) ?? Answer(status: 500)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

func stubHTTP() -> CloudHTTP {
    var http = CloudHTTP(session: StubProtocol.session(), tokens: TokenSource(fixed: "test-token"))
    http.maxBackoff = 0
    return http
}

final class TempFolder {
    let url: URL
    let store: FolderStore

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ha-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = FolderStore(root: url)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ text: String, age: TimeInterval = 0) {
        try! store.write(Data(text.utf8), to: path)
        if age != 0 {
            try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.appendingPathComponent(path).path)
        }
    }

    func read(_ path: String) -> String? { (try? store.read(path)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } }
}

// MARK: - sign-in

final class OAuthTests: XCTestCase {
    func testPKCEChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsLongEnoughAndURLSafe() {
        let verifier = PKCE.verifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(verifier, PKCE.verifier())
    }

    func testGoogleRedirectIsTheClientIDBackwards() {
        let config = OAuthConfig.make(.google, clientID: "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(config.redirectURI, "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(config.callbackScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(config.scope, "https://www.googleapis.com/auth/drive.file")
    }

    func testRedirectsOfTheOtherTwo() {
        XCTAssertEqual(OAuthConfig.make(.onedrive, clientID: "x", bundleID: "com.healthaccessmcp.app").redirectURI, "msauth.com.healthaccessmcp.app://auth")
        let dropbox = OAuthConfig.make(.dropbox, clientID: "key1")
        XCTAssertEqual(dropbox.redirectURI, "db-key1://2/token")
        XCTAssertEqual(dropbox.callbackScheme, "db-key1")
    }

    func testAuthorizeRequestCarriesPKCEAndOfflineAccess() {
        let url = OAuthConfig.make(.dropbox, clientID: "key1").authorizeRequest(challenge: "CH", state: "ST")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["code_challenge"], "CH")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "ST")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["token_access_type"], "offline")
        XCTAssertEqual(items["client_id"], "key1")
    }

    func testTokenRequestIsAFormWithTheClientID() {
        let request = OAuthConfig.make(.onedrive, clientID: "app 1").tokenRequest(["grant_type": "refresh_token", "refresh_token": "a/b+c"])
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "client_id=app%201&grant_type=refresh_token&refresh_token=a%2Fb%2Bc")
    }

    func testCodeComesOnlyFromAMatchingAnswer() throws {
        XCTAssertEqual(try OAuthFlow.code(from: URL(string: "db-k://2/token?code=abc&state=S1")!, state: "S1"), "abc")
        XCTAssertThrowsError(try OAuthFlow.code(from: URL(string: "db-k://2/token?code=abc&state=other")!, state: "S1"))
        XCTAssertThrowsError(try OAuthFlow.code(from: URL(string: "db-k://2/token?state=S1")!, state: "S1"))
        XCTAssertThrowsError(try OAuthFlow.code(from: URL(string: "db-k://2/token?error=access_denied&state=S1")!, state: "S1")) {
            XCTAssertEqual($0 as? CloudError, .cancelled)
        }
    }

    func testTokenAnswer() throws {
        let parsed = try TokenResponse.parse(json(["access_token": "A", "expires_in": 3599, "refresh_token": "R"]))
        XCTAssertEqual(parsed, TokenResponse(accessToken: "A", expiresIn: 3599, refreshToken: "R"))
        XCTAssertThrowsError(try TokenResponse.parse(json(["error": "invalid_grant"])))
    }

    func testConfigLeavesOutPlaceholders() {
        XCTAssertEqual(CloudConfig(ids: [.google: "x"]).kinds, [.google, .webdav, .s3])
        XCTAssertFalse(CloudConfig(ids: [:]).offers(.dropbox))
    }
}

// MARK: - decisions

final class PlannerTests: XCTestCase {
    private func file(_ path: String, _ size: Int = 10, age: TimeInterval = 0) -> LocalFile {
        LocalFile(path: path, size: size, modified: Date(timeIntervalSince1970: 1_800_000_000 - age))
    }

    func testOnlyNewAndChangedFilesAreUploadedNewestFirstOverviewLast() {
        let a = file("workouts/a.json", age: 300), b = file("workouts/b.json", age: 100), c = file("days/c.json", age: 200)
        let index = file("index.json"), briefing = file("briefing.md")
        let state: [String: CloudState.FileState] = [
            "workouts/a.json": .init(sig: a.sig, ref: RemoteRef(id: "1", rev: "")),               // unchanged
            "days/c.json": .init(sig: "old", ref: RemoteRef(id: "2", rev: "")),                   // changed
        ]
        let queue = CloudPlanner.uploads(local: [index, a, b, c, briefing], state: state)
        XCTAssertEqual(queue.main.map(\.path), ["workouts/b.json", "days/c.json"])
        XCTAssertEqual(queue.last.map(\.path), ["briefing.md", "index.json"])
    }

    func testAFileKnownOnTheDriveButNotComparedIsQueued() {
        let a = file("workouts/a.json")
        let queue = CloudPlanner.uploads(local: [a], state: ["workouts/a.json": .init(sig: nil, ref: RemoteRef(id: "1", rev: "x"))])
        XCTAssertEqual(queue.main, [a])
    }

    func testOnlyStatusFilesAreEverRemoved() {
        let ref = RemoteRef(id: "1", rev: "")
        let state: [String: CloudState.FileState] = [
            "plans/p.status.json": .init(sig: "s", ref: ref), "plans/q.status.json": .init(sig: "s", ref: ref),
            "plans/p.json": .init(sig: "s", ref: ref), "workouts/gone.json": .init(sig: "s", ref: ref),
        ]
        XCTAssertEqual(CloudPlanner.removedStatusFiles(local: ["plans/q.status.json"], state: state), ["plans/p.status.json"])
    }

    func testNewPlansAreFilesTheAppDoesNotKnow() {
        func entry(_ name: String, _ id: String, size: Int = 100, folder: Bool = false) -> RemoteEntry {
            RemoteEntry(name: name, ref: RemoteRef(id: id, rev: "r"), size: size, isFolder: folder)
        }
        let remote = [entry("mine.json", "known"), entry("new.json", "n1"), entry("new.status.json", "n2"), entry("inbox.json", "n3"),
                      entry("README.md", "n4"), entry("big.json", "n5", size: 300_000), entry("sub.json", "n6", folder: true),
                      entry("../evil.json", "n7"), entry(".hidden.json", "n8"), entry("2026-11-16T16:02:07Z-a2.json", "n9")]
        XCTAssertEqual(CloudPlanner.newPlans(remote: remote, knownIDs: ["known"]).map(\.name), ["2026-11-16T16:02:07Z-a2.json", "new.json"])
    }

    func testPlanNames() {
        XCTAssertTrue(CloudPlanner.isPlanName("easy-swim_1.json"))
        XCTAssertFalse(CloudPlanner.isPlanName("a/b.json"))
        XCTAssertFalse(CloudPlanner.isPlanName("a\\b.json"))
        XCTAssertFalse(CloudPlanner.isPlanName("plan.txt"))
        XCTAssertFalse(CloudPlanner.isPlanName(String(repeating: "a", count: 200) + ".json"))
    }

    func testInboxTakesOnePlanOrAList() {
        let one = CloudPlanner.inboxPlans(Data(#"{"id":"easy-swim","name":"Easy"}"#.utf8))
        XCTAssertEqual(one.map(\.name), ["easy-swim.json"])
        let many = CloudPlanner.inboxPlans(Data(#"[{"id":"a","name":"A"},{"name":"no id"},{"id":"a","name":"A again"},{}]"#.utf8))
        XCTAssertEqual(many.count, 2)
        XCTAssertEqual(many[0].name, "a.json")
        XCTAssertTrue(many[1].name.hasPrefix("inbox-") && many[1].name.hasSuffix(".json"))
        // The same content gives the same name, so a second read writes nothing new.
        XCTAssertEqual(many[1].name, CloudPlanner.inboxPlans(Data(#"{"name":"no id"}"#.utf8))[0].name)
    }

    func testInboxIgnoresWhatIsNotAPlan() {
        XCTAssertTrue(CloudPlanner.inboxPlans(Data("[]\n".utf8)).isEmpty)
        XCTAssertTrue(CloudPlanner.inboxPlans(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(CloudPlanner.inboxPlans(Data("[1, 2, \"x\"]".utf8)).isEmpty)
        // An id that is not a safe file name is not used as one.
        XCTAssertTrue(CloudPlanner.inboxPlans(Data(#"{"id":"../../x","name":"N"}"#.utf8))[0].name.hasPrefix("inbox-"))
    }

    func testTheGuidesExamplePlanIsAPlanTheAppAccepts() throws {
        for kind in CloudKind.allCases {
            let text = PlanGuide.text(for: kind)
            let start = try XCTUnwrap(text.range(of: "```json\n")), end = try XCTUnwrap(text.range(of: "\n```", range: start.upperBound..<text.endIndex))
            let plan = try HealthAccessJSON.decode(PlanDoc.self, from: Data(text[start.upperBound..<end.lowerBound].utf8))
            XCTAssertNoThrow(try PlanInstaller.validate(plan))
            XCTAssertTrue(CloudPlanner.isPlanName(plan.id + ".json"))
            XCTAssertTrue(text.contains("plans/inbox.json"))
        }
    }
}

// MARK: - the mirror, against a drive in memory

final class MirrorTests: XCTestCase {
    private func seeded() -> TempFolder {
        let folder = TempFolder()
        folder.write("index.json", "{}")
        folder.write("briefing.md", "# briefing")
        folder.write("workouts/2026-11-18_swim.json", #"{"w":1}"#, age: 100)
        folder.write("days/2026-11-18.json", #"{"d":1}"#, age: 200)
        folder.write("plans/2026-11-16T16:02:07Z-a2.json", #"{"p":1}"#, age: 300)
        folder.write("mcp/clients/abc.json", "{}")
        return folder
    }

    func testFirstRunUploadsEverythingAndTheSecondNothing() async throws {
        let folder = seeded(), drive = FakeDrive()
        let mirror = CloudMirror(kind: .dropbox, drive: drive)
        let first = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(first.uploaded, 5)
        XCTAssertEqual(first.remaining, 0)
        let paths = await Set(drive.files.keys)
        XCTAssertEqual(paths, ["index.json", "briefing.md", "workouts/2026-11-18_swim.json", "days/2026-11-18.json",
                               "plans/2026-11-16T16_02_07Z-a2.json", "plans/inbox.json", "README.md"])
        let order = await drive.puts
        XCTAssertEqual(Array(order.suffix(2)), ["briefing.md", "index.json"], "the overview files go last")

        await drive.resetLog()
        let second = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(second.uploaded, 0)
        let puts = await drive.puts
        XCTAssertEqual(puts, [])
    }

    func testAChangedFileGoesAgain() async throws {
        let folder = seeded(), drive = FakeDrive()
        let mirror = CloudMirror(kind: .dropbox, drive: drive)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        await drive.resetLog()
        folder.write("days/2026-11-18.json", #"{"d":2,"more":true}"#)
        let summary = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.uploaded, 1)
        let stored = await drive.files["days/2026-11-18.json"]?.data
        XCTAssertEqual(stored.map { String(decoding: $0, as: UTF8.self) }, #"{"d":2,"more":true}"#)
    }

    func testAReconnectFindsTheFilesAndSkipsTheUnchangedOnes() async throws {
        let folder = seeded(), drive = FakeDrive()
        _ = try await CloudMirror(kind: .google, drive: drive).run(folder: folder.store, mode: .full)
        let count = await drive.files.count
        await drive.resetLog()
        folder.write("days/2026-11-18.json", "changed while disconnected")
        // A new mirror with empty state: the app was reinstalled, the drive still holds the files.
        let summary = try await CloudMirror(kind: .google, drive: drive).run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.unchanged, 4)
        let after = await drive.files.count
        XCTAssertEqual(after, count, "no second copy of any file")
    }

    func testAPlanSomeoneElsePutOnTheDriveComesToThePhoneOnce() async throws {
        let folder = seeded(), drive = FakeDrive()
        let mirror = CloudMirror(kind: .onedrive, drive: drive)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        await drive.plant("plans/from-ai.json", #"{"id":"from-ai"}"#)
        await drive.resetLog()
        let pull = try await mirror.run(folder: folder.store, mode: .plansOnly)
        XCTAssertEqual(pull.pulled, 1)
        XCTAssertEqual(folder.read("plans/from-ai.json"), #"{"id":"from-ai"}"#)
        let afterPull = await drive.puts
        XCTAssertEqual(afterPull, [], "a plans-only run uploads nothing")
        let next = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(next.pulled, 0)
        XCTAssertEqual(next.uploaded, 0, "the plan is already on the drive")
    }

    func testAPlanInTheInboxBecomesAPlanFileAndIsReadOnce() async throws {
        let folder = seeded(), drive = FakeDrive()
        let mirror = CloudMirror(kind: .google, drive: drive)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        let empty = await drive.files["plans/inbox.json"]?.data
        XCTAssertEqual(empty, Data("[]\n".utf8))
        await drive.plant("plans/inbox.json", #"[{"id":"inbox-plan","name":"From the inbox"}]"#)
        let summary = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.pulled, 1)
        XCTAssertNotNil(folder.read("plans/inbox-plan.json"))
        XCTAssertEqual(summary.uploaded, 1, "the new plan file goes up, so the AI sees it was taken")
        let again = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(again.pulled, 0)
        XCTAssertEqual(again.uploaded, 0)
    }

    func testAStatusFileTheAppRemovedIsRemovedOnTheDriveAndNothingElse() async throws {
        let folder = seeded(), drive = FakeDrive()
        folder.write("plans/p.status.json", #"{"state":"scheduled"}"#)
        let mirror = CloudMirror(kind: .dropbox, drive: drive)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        try folder.store.remove("plans/p.status.json")
        try folder.store.remove("workouts/2026-11-18_swim.json")
        let summary = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.removed, 1)
        let deletes = await drive.deletes
        XCTAssertEqual(deletes, ["plans/p.status.json"])
        let kept = await drive.files["workouts/2026-11-18_swim.json"]
        XCTAssertNotNil(kept, "a workout missing on the phone stays on the drive")
    }

    func testWhenTimeIsUpTheRestWaitsAndTheOverviewStillGoes() async throws {
        let folder = seeded(), drive = FakeDrive()
        let mirror = CloudMirror(kind: .dropbox, drive: drive)
        let summary = try await mirror.run(folder: folder.store, mode: .full, deadline: Date().addingTimeInterval(-1))
        XCTAssertEqual(summary.remaining, 3)
        XCTAssertEqual(summary.uploaded, 2)
        let next = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(next.uploaded, 3)
    }

    func testOneBadFileDoesNotStopTheRun() async throws {
        let folder = seeded(), drive = FakeDrive()
        await drive.fail("days/2026-11-18.json")
        let summary = try await CloudMirror(kind: .dropbox, drive: drive).run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.uploaded, 4)
        XCTAssertTrue(summary.firstFailure?.contains("days/2026-11-18.json") == true)
    }

    func testNoConnectionEndsTheRunWithThatError() async throws {
        let folder = seeded(), drive = FakeDrive()
        await drive.setOffline(true)
        do {
            _ = try await CloudMirror(kind: .dropbox, drive: drive).run(folder: folder.store, mode: .full)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .offline)
        }
    }

    func testEveryDriveGetsNamesWithoutColons() async throws {
        let folder = seeded(), drive = FakeDrive(forbidColon: true)
        let mirror = CloudMirror(kind: .onedrive, drive: drive)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        let paths = await Set(drive.files.keys)
        XCTAssertTrue(paths.contains("plans/2026-11-16T16_02_07Z-a2.json"))
        // Its own renamed plan is not taken for a new one.
        let next = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(next.pulled, 0)
        XCTAssertEqual(next.uploaded, 0)
    }

    func testStateSurvivesARestart() async throws {
        let folder = seeded(), drive = FakeDrive()
        let url = folder.url.deletingLastPathComponent().appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await CloudMirror(kind: .dropbox, drive: drive, stateURL: url).run(folder: folder.store, mode: .full)
        await drive.resetLog()
        let restored = CloudMirror.loadState(url)
        XCTAssertEqual(restored.files.count, 5)
        XCTAssertNotNil(restored.lastRun)
        let summary = try await CloudMirror(kind: .dropbox, drive: drive, state: restored, stateURL: url).run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.uploaded, 0)
        let lists = await drive.lists
        XCTAssertEqual(lists, 1, "only the plans folder is listed once the drive was looked through")
    }

    func testTheScannerLeavesOutHiddenAndHandshakeFiles() throws {
        let folder = seeded()
        folder.write(".workouts.json.icloud", "placeholder")
        folder.write("workouts/.hidden.json", "x")
        let paths = try CloudScanner.scan(folder.store).map(\.path).sorted()
        XCTAssertEqual(paths, ["briefing.md", "days/2026-11-18.json", "index.json", "plans/2026-11-16T16:02:07Z-a2.json", "workouts/2026-11-18_swim.json"])
    }
}

// MARK: - the three drives, against a stubbed network

final class DriveRequestTests: XCTestCase {
    func testGoogleMakesItsFoldersThenUploadsIntoThem() async throws {
        var made: [String] = []
        StubProtocol.reset { request, body in
            let url = request.url!.absoluteString
            if request.httpMethod == "GET" { return .init(body: json(["files": []])) }                      // nothing there yet
            if url.contains("/upload/") { return .init(body: json(["id": "file-1", "md5Checksum": "abc"])) }
            let name = (try! JSONSerialization.jsonObject(with: body) as! [String: Any])["name"] as! String
            made.append(name)
            return .init(body: json(["id": "folder-\(name)"]))
        }
        let drive = GoogleDrive(http: stubHTTP())
        let ref = try await drive.put(Data("{}".utf8), at: "workouts/a.json", known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "file-1", rev: "abc"))
        XCTAssertEqual(made, ["Health Access", "workouts"])
        let upload = StubProtocol.seen.last!
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertTrue(upload.request.url!.absoluteString.contains("uploadType=multipart"))
        let text = String(decoding: upload.body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""parents":["folder-workouts"]"#) && text.contains(#""name":"a.json""#))
        let cache = await drive.folderCache()
        XCTAssertEqual(cache, ["": "folder-Health Access", "workouts": "folder-workouts"])

        // The second file needs no folder calls.
        let before = StubProtocol.seen.count
        _ = try await drive.put(Data("{}".utf8), at: "workouts/b.json", known: nil)
        XCTAssertEqual(StubProtocol.seen.count, before + 1)
    }

    func testGoogleUsesAFolderFromAnEarlierInstall() async throws {
        StubProtocol.reset { request, _ in
            if request.httpMethod == "GET" {
                return .init(body: json(["files": [["id": "old-root", "name": "Health Access", "mimeType": "application/vnd.google-apps.folder"]]]))
            }
            return .init(body: json(["id": "f", "md5Checksum": "m"]))
        }
        let drive = GoogleDrive(http: stubHTTP())
        _ = try await drive.put(Data("x".utf8), at: "index.json", known: nil)
        let cache = await drive.folderCache()
        XCTAssertEqual(cache[""], "old-root")
        XCTAssertFalse(StubProtocol.seen.contains { $0.request.httpMethod == "POST" && !$0.request.url!.absoluteString.contains("/upload/") }, "no new folder")
    }

    func testGoogleReplacesAKnownFileAndMakesItAgainWhenItWasDeleted() async throws {
        StubProtocol.reset { request, _ in
            if request.httpMethod == "PATCH" { return .init(status: 404) }
            if request.httpMethod == "GET" { return .init(body: json(["files": [["id": "root", "name": "Health Access", "mimeType": "application/vnd.google-apps.folder"]]])) }
            return .init(body: json(["id": "new-id", "md5Checksum": "m"]))
        }
        let ref = try await GoogleDrive(http: stubHTTP()).put(Data("x".utf8), at: "index.json", known: RemoteRef(id: "gone", rev: ""))
        XCTAssertEqual(ref.id, "new-id")
        XCTAssertTrue(StubProtocol.seen.first!.request.url!.absoluteString.contains("/files/gone?uploadType=media"))
    }

    func testGoogleListReadsEveryPage() async throws {
        StubProtocol.reset { request, _ in
            let url = request.url!.absoluteString
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            if query.contains("name = 'Health Access'") { return .init(body: json(["files": [["id": "root", "name": "Health Access", "mimeType": "application/vnd.google-apps.folder"]]])) }
            XCTAssertEqual(query, "'root' in parents and trashed = false")
            if url.contains("pageToken=p2") { return .init(body: json(["files": [["id": "2", "name": "b.json", "md5Checksum": "m2", "size": "7"]]])) }
            return .init(body: json(["nextPageToken": "p2", "files": [["id": "1", "name": "a.json", "md5Checksum": "m1", "size": "5"]]]))
        }
        let entries = try await GoogleDrive(http: stubHTTP()).list("")
        XCTAssertEqual(entries.map(\.name), ["a.json", "b.json"])
        XCTAssertEqual(entries.last?.size, 7)
    }

    func testGoogleQuotesNamesInQueries() {
        XCTAssertEqual(GoogleDrive.quote(#"it's a \ test"#), #"it\'s a \\ test"#)
    }

    func testGoogleMultipartBody() {
        let body = String(decoding: GoogleDrive.multipart(metadata: Data("{}".utf8), data: Data("DATA".utf8), contentType: "application/json", boundary: "B"), as: UTF8.self)
        XCTAssertEqual(body, "--B\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{}\r\n--B\r\nContent-Type: application/json\r\n\r\nDATA\r\n--B--\r\n")
    }

    func testOneDrivePutsByPathInsideItsAppFolder() async throws {
        StubProtocol.reset { _, _ in .init(status: 201, body: json(["id": "item-1", "cTag": "c1"])) }
        let drive = OneDrive(http: stubHTTP())
        let ref = try await drive.put(Data("{}".utf8), at: "plans/" + drive.remoteName("2026-11-16T16:02:07Z a.json"), known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "item-1", rev: "c1"))
        let sent = StubProtocol.seen[0].request
        XCTAssertEqual(sent.httpMethod, "PUT")
        XCTAssertEqual(sent.url!.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/special/approot:/plans/2026-11-16T16_02_07Z%20a.json:/content")
        XCTAssertEqual(CloudPath.safeName(#"a:b*c?d"e<f>g|h\i.json"#), "a_b_c_d_e_f_g_h_i.json")
    }

    func testOneDriveListsAMissingFolderAsEmpty() async throws {
        StubProtocol.reset { _, _ in .init(status: 404, body: json(["error": ["code": "itemNotFound"]])) }
        let entries = try await OneDrive(http: stubHTTP()).list("plans")
        XCTAssertEqual(entries, [])
    }

    func testOneDriveSendsALargeFileInPieces() async throws {
        StubProtocol.reset { request, _ in
            if request.url!.absoluteString.hasSuffix("createUploadSession") { return .init(body: json(["uploadUrl": "https://upload.example/session"])) }
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            return range.hasSuffix("-\(OneDrive.chunk + 9)/\(OneDrive.chunk + 10)") ? .init(status: 201, body: json(["id": "big", "cTag": "c"])) : .init(status: 202, body: json(["nextExpectedRanges": ["x"]]))
        }
        let ref = try await OneDrive(http: stubHTTP()).put(Data(count: OneDrive.chunk + 10), at: "workouts/big.json", known: nil)
        XCTAssertEqual(ref.id, "big")
        let pieces = StubProtocol.seen.filter { $0.request.url!.host == "upload.example" }
        XCTAssertEqual(pieces.map(\.body.count), [OneDrive.chunk, 10])
        XCTAssertNil(pieces[0].request.value(forHTTPHeaderField: "Authorization"), "the upload address carries its own permission")
    }

    func testDropboxUploadOverwritesByPath() async throws {
        StubProtocol.reset { _, _ in .init(body: json(["id": "id:1", "rev": "r1"])) }
        let ref = try await Dropbox(http: stubHTTP()).put(Data("{}".utf8), at: "workouts/a.json", known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "id:1", rev: "r1"))
        let sent = StubProtocol.seen[0].request
        XCTAssertEqual(sent.url!.absoluteString, "https://content.dropboxapi.com/2/files/upload")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Dropbox-API-Arg"), #"{"mode":"overwrite","mute":true,"path":"/workouts/a.json"}"#)
    }

    func testDropboxHeaderJSONIsPlainASCII() throws {
        XCTAssertEqual(try Dropbox.headerJSON(["path": "/Žiga ü.json"]), #"{"path":"/\u017diga \u00fc.json"}"#)
    }

    func testDropboxListFollowsTheCursorAndTreatsAMissingFolderAsEmpty() async throws {
        StubProtocol.reset { request, _ in
            if request.url!.absoluteString.hasSuffix("continue") {
                return .init(body: json(["entries": [[".tag": "file", "name": "b.json", "id": "id:2", "rev": "r2", "size": 2]], "has_more": false]))
            }
            return .init(body: json(["entries": [[".tag": "file", "name": "a.json", "id": "id:1", "rev": "r1", "size": 1], [".tag": "folder", "name": "sub", "id": "id:9"]],
                                     "has_more": true, "cursor": "c1"]))
        }
        let entries = try await Dropbox(http: stubHTTP()).list("plans")
        XCTAssertEqual(entries.map(\.name), ["a.json", "sub", "b.json"])
        XCTAssertEqual(entries.map(\.isFolder), [false, true, false])

        StubProtocol.reset { _, _ in .init(status: 409, body: json(["error_summary": "path/not_found/.."])) }
        let none = try await Dropbox(http: stubHTTP()).list("plans")
        XCTAssertEqual(none, [])
    }

    func testASlowDownAnswerIsTriedAgainAndARealErrorIsNot() async throws {
        var calls = 0
        StubProtocol.reset { _, _ in
            calls += 1
            return calls < 3 ? .init(status: 429, headers: ["Retry-After": "0"]) : .init(body: json(["id": "id:1", "rev": "r"]))
        }
        _ = try await Dropbox(http: stubHTTP()).put(Data(), at: "a.json", known: nil)
        XCTAssertEqual(calls, 3)

        calls = 0
        StubProtocol.reset { _, _ in calls += 1; return .init(status: 400, body: Data("bad request".utf8)) }
        do {
            _ = try await Dropbox(http: stubHTTP()).put(Data(), at: "a.json", known: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .http(400, "bad request"))
        }
        XCTAssertEqual(calls, 1)
    }

    func testARefusedTokenIsRefreshedOnceThenReportedAsExpired() async throws {
        var calls = 0
        StubProtocol.reset { _, _ in calls += 1; return .init(status: 401) }
        do {
            _ = try await Dropbox(http: stubHTTP()).list("")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInExpired)
        }
        XCTAssertEqual(calls, 2)
    }
}
