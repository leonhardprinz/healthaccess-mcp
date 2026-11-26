import XCTest
@testable import HealthAccess

// MARK: - S3

final class S3Tests: XCTestCase {
    /// The worked examples in Amazon's documentation of Signature Version 4 for S3 ("examplebucket", 24 May 2013).
    private func signer() -> S3Signer {
        var signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        signer.now = { Date(timeIntervalSince1970: 1_369_353_600) }   // 2013-05-24T00:00:00Z
        return signer
    }

    func testSignatureOfAmazonsListObjectsExample() {
        let signed = signer().sign(URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!))
        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testSignatureOfAmazonsLifecycleExample() {
        let signed = signer().sign(URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!))
        XCTAssertTrue(signed.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543") == true,
                      signed.value(forHTTPHeaderField: "Authorization") ?? "")
    }

    func testAmazonGetsTheBucketInTheHostAndOthersInThePath() throws {
        let amazon = try S3Target.make(["bucket": "my-bucket", "accessKey": "A", "secretKey": "S", "region": "eu-central-1", "prefix": "/health-access/"])
        XCTAssertEqual(amazon.url(key: amazon.key("workouts/a b.json")).absoluteString, "https://my-bucket.s3.eu-central-1.amazonaws.com/health-access/workouts/a%20b.json")
        let r2 = try S3Target.make(["bucket": "b", "accessKey": "A", "secretKey": "S", "endpoint": "abc.r2.cloudflarestorage.com"])
        XCTAssertEqual(r2.region, "auto")
        XCTAssertEqual(r2.url(key: r2.key("index.json")).absoluteString, "https://abc.r2.cloudflarestorage.com/b/index.json")
        XCTAssertEqual(r2.url(key: "", query: [("list-type", "2"), ("prefix", "plans/")]).absoluteString, "https://abc.r2.cloudflarestorage.com/b/?list-type=2&prefix=plans%2F")
    }

    func testWhatIsNotATargetIsRefused() {
        XCTAssertThrowsError(try S3Target.make(["bucket": "b"]))
        XCTAssertThrowsError(try S3Target.make(["bucket": "a/b", "accessKey": "A", "secretKey": "S"]))
        XCTAssertThrowsError(try S3Target.make(["bucket": "b", "accessKey": "A", "secretKey": "S", "endpoint": "http://example.com"]), "no plain http to the internet")
    }

    func testListReadsFilesFoldersAndTheNextPage() async throws {
        StubProtocol.reset { request, _ in
            let url = request.url!.absoluteString
            XCTAssertTrue(url.contains("prefix=health-access%2Fplans%2F") && url.contains("delimiter=%2F"))
            if url.contains("continuation-token=T2") {
                return .init(body: Data(#"<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>health-access/plans/b.json</Key><ETag>"e2"</ETag><Size>2</Size></Contents></ListBucketResult>"#.utf8))
            }
            return .init(body: Data(#"<?xml version="1.0"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>true</IsTruncated><NextContinuationToken>T2</NextContinuationToken><Contents><Key>health-access/plans/a.json</Key><ETag>&quot;e1&quot;</ETag><Size>11</Size></Contents><Contents><Key>health-access/plans/</Key><Size>0</Size></Contents><CommonPrefixes><Prefix>health-access/plans/old/</Prefix></CommonPrefixes></ListBucketResult>"#.utf8))
        }
        let target = try S3Target.make(["bucket": "b", "accessKey": "A", "secretKey": "S", "prefix": "health-access"])
        let drive = S3Drive(http: stubHTTP(), target: target)
        let entries = try await drive.list("plans")
        XCTAssertEqual(entries.map(\.name), ["a.json", "old", "b.json"])
        XCTAssertEqual(entries[0].ref, RemoteRef(id: "plans/a.json", rev: "e1"))
        XCTAssertEqual(entries[0].size, 11)
        XCTAssertEqual(entries.map(\.isFolder), [false, true, false])
    }

    func testPutSignsTheBodyAndTakesTheETagAsRev() async throws {
        StubProtocol.reset { _, _ in .init(headers: ["ETag": "\"abc123\""]) }
        let target = try S3Target.make(["bucket": "b", "accessKey": "AK", "secretKey": "S", "endpoint": "https://s3.example.com"])
        var http = CloudHTTP(session: StubProtocol.session(), tokens: S3Signer(accessKey: "AK", secretKey: "S", region: target.region))
        http.maxBackoff = 0
        let ref = try await S3Drive(http: http, target: target).put(Data("{}".utf8), at: "index.json", known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "index.json", rev: "abc123"))
        let sent = StubProtocol.seen[0].request
        XCTAssertEqual(sent.url!.absoluteString, "https://s3.example.com/b/index.json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-amz-content-sha256"), Data("{}".utf8).sha256Hex)
        XCTAssertTrue(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/") == true)
    }
}

// MARK: - WebDAV

final class WebDAVTests: XCTestCase {
    func testOnlySafeAddressesAreTaken() throws {
        XCTAssertNoThrow(try WebDAVDrive.validate(" https://cloud.example.com/remote.php/dav/files/anna/ "))
        XCTAssertNoThrow(try WebDAVDrive.validate("http://nas.local:5005/home"))
        XCTAssertNoThrow(try WebDAVDrive.validate("http://192.168.1.20/dav"))
        XCTAssertThrowsError(try WebDAVDrive.validate("http://cloud.example.com/dav"), "no password in the clear over the internet")
        XCTAssertThrowsError(try WebDAVDrive.validate("https://anna:secret@cloud.example.com/dav"))
        XCTAssertThrowsError(try WebDAVDrive.validate("cloud.example.com"))
        XCTAssertThrowsError(try WebDAVDrive.validate("ftp://cloud.example.com"))
        XCTAssertFalse(WebDAVDrive.isLocal("172.32.0.1"))
        XCTAssertTrue(WebDAVDrive.isLocal("172.20.0.1"))
    }

    func testAnswerOfANextcloudServer() throws {
        let xml = #"""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/remote.php/dav/files/anna/Health%20Access/plans/</d:href>
            <d:propstat><d:prop><d:getetag>&quot;dir&quot;</d:getetag><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/anna/Health%20Access/plans/2026-11-16T16%3A02%3A07Z-a2.json</d:href>
            <d:propstat><d:prop><d:getetag>&quot;e1&quot;</d:getetag><d:getcontentlength>321</d:getcontentlength><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/anna/Health%20Access/plans/archive/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """#
        let entries = WebDAVDrive.entries(try CloudXML.parse(Data(xml.utf8), records: ["response"]), directory: "plans",
                                          selfPath: "/remote.php/dav/files/anna/Health Access/plans")
        XCTAssertEqual(entries.map(\.name), ["2026-11-16T16:02:07Z-a2.json", "archive"])
        XCTAssertEqual(entries[0].ref, RemoteRef(id: "plans/2026-11-16T16:02:07Z-a2.json", rev: "\"e1\""))
        XCTAssertEqual(entries[0].size, 321)
        XCTAssertEqual(entries.map(\.isFolder), [false, true])
    }

    func testPutMakesTheFoldersOnceAndSendsNameAndPassword() async throws {
        StubProtocol.reset { request, _ in
            request.httpMethod == "MKCOL" ? .init(status: request.url!.path.hasSuffix("Health Access") ? 405 : 201) : .init(status: 201, headers: ["ETag": "\"v1\""])
        }
        var http = CloudHTTP(session: StubProtocol.session(), tokens: BasicAuth(user: "anna", password: "pw"))
        http.maxBackoff = 0
        let drive = WebDAVDrive(http: http, base: URL(string: "https://cloud.example.com/dav/files/anna/")!)
        let ref = try await drive.put(Data("{}".utf8), at: "workouts/a b.json", known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "workouts/a b.json", rev: "\"v1\""))
        _ = try await drive.put(Data("{}".utf8), at: "workouts/c.json", known: nil)
        let calls = StubProtocol.seen.map { "\($0.request.httpMethod!) \($0.request.url!.absoluteString)" }
        XCTAssertEqual(calls, ["MKCOL https://cloud.example.com/dav/files/anna/Health%20Access",
                               "MKCOL https://cloud.example.com/dav/files/anna/Health%20Access/workouts",
                               "PUT https://cloud.example.com/dav/files/anna/Health%20Access/workouts/a%20b.json",
                               "PUT https://cloud.example.com/dav/files/anna/Health%20Access/workouts/c.json"])
        XCTAssertEqual(StubProtocol.seen[0].request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("anna:pw".utf8).base64EncodedString())
    }

    func testAMissingFolderListsAsEmpty() async throws {
        StubProtocol.reset { _, _ in .init(status: 404) }
        let entries = try await WebDAVDrive(http: stubHTTP(), base: URL(string: "https://x.example.com/dav")!).list("plans")
        XCTAssertEqual(entries, [])
        XCTAssertEqual(StubProtocol.seen[0].request.value(forHTTPHeaderField: "Depth"), "1")
    }
}

// MARK: - Box and pCloud

final class BoxAndPCloudTests: XCTestCase {
    func testBoxSignInUsesItsSecretAndNoPKCE() {
        let config = OAuthConfig.make(.box, clientID: "cid", secret: "sec")
        XCTAssertEqual(config.redirectURI, "boxsdk-cid://boxsdkoauth2redirect")
        let query = config.authorizeRequest(challenge: "CH", state: "ST").query ?? ""
        XCTAssertFalse(query.contains("code_challenge"))
        XCTAssertTrue(query.contains("response_type=code"))
        XCTAssertEqual(String(decoding: config.tokenRequest(["grant_type": "refresh_token", "refresh_token": "r"]).httpBody!, as: UTF8.self),
                       "client_id=cid&client_secret=sec&grant_type=refresh_token&refresh_token=r")
    }

    func testBoxIsOfferedOnlyWithIDAndSecret() {
        XCTAssertFalse(CloudConfig(ids: [.box: "id"]).offers(.box))
        XCTAssertTrue(CloudConfig(ids: [.box: "id"], secrets: [.box: "s"]).offers(.box))
        XCTAssertEqual(CloudConfig(ids: [:]).kinds, [.webdav, .s3], "a server of one's own needs no id of ours")
    }

    func testBoxFindsItsFolderUploadsAndGivesAnExistingNameANewVersion() async throws {
        var uploads = 0
        StubProtocol.reset { request, body in
            let url = request.url!.absoluteString
            if url.contains("/folders/0/items") { return .init(body: json(["total_count": 1, "entries": [["type": "folder", "id": "100", "name": "Health Access"]]])) }
            if url.contains("/folders/100/items") { return .init(body: json(["total_count": 0, "entries": []])) }
            if url.hasSuffix("/folders") { return .init(status: 201, body: json(["id": "200"])) }
            if url.hasSuffix("/files/content") {
                uploads += 1
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#""parent":{"id":"200"}"#))
                return .init(status: 409, body: json(["context_info": ["conflicts": ["id": "f9", "type": "file"]]]))
            }
            if url.hasSuffix("/files/f9/content") { return .init(status: 201, body: json(["entries": [["id": "f9", "sha1": "s1"]]])) }
            return .init(status: 500)
        }
        let drive = BoxDrive(http: stubHTTP())
        let ref = try await drive.put(Data("{}".utf8), at: "workouts/a.json", known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "f9", rev: "s1"))
        XCTAssertEqual(uploads, 1)
        let cache = await drive.folderCache()
        XCTAssertEqual(cache, ["": "100", "workouts": "200"])
        XCTAssertEqual(drive.rev(of: Data("abc".utf8)), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testPCloudTokenComesFromTheRedirectWithTheRegionsHost() throws {
        let found = try OAuthFlow.token(from: URL(string: "com.healthaccessmcp.app://oauth/pcloud#access_token=TOK&token_type=bearer&userid=1&locationid=2&hostname=eapi.pcloud.com&state=S1")!, state: "S1")
        XCTAssertEqual(found.token, "TOK")
        XCTAssertEqual(found.host, "eapi.pcloud.com")
        XCTAssertEqual(try OAuthFlow.token(from: URL(string: "x://y#access_token=T&locationid=1")!, state: "S").host, "api.pcloud.com")
        XCTAssertThrowsError(try OAuthFlow.token(from: URL(string: "x://y#access_token=T&hostname=evil.example.com")!, state: "S"))
        XCTAssertThrowsError(try OAuthFlow.token(from: URL(string: "x://y#access_token=T&state=other")!, state: "S"))
        XCTAssertTrue(OAuthConfig.make(.pcloud, clientID: "c").authorizeRequest(challenge: "", state: "S").query!.contains("response_type=token"))
    }

    func testPCloudReadsTheResultCodeInTheBody() async throws {
        StubProtocol.reset { request, _ in
            let url = request.url!.absoluteString
            if url.contains("listfolder") { return .init(body: json(["result": 2005, "error": "Directory does not exist."])) }
            if url.contains("createfolderifnotexists") { return .init(body: json(["result": 0, "metadata": ["folderid": 5]])) }
            return .init(body: json(["result": 0, "metadata": [["fileid": 77, "hash": 123456789012, "name": "a.json", "size": 2]]]))
        }
        let drive = PCloudDrive(http: stubHTTP(), host: "eapi.pcloud.com")
        let none = try await drive.list("plans")
        XCTAssertEqual(none, [])
        let ref = try await drive.put(Data("{}".utf8), at: "workouts/a.json", known: nil)
        XCTAssertEqual(ref, RemoteRef(id: "77", rev: "123456789012"))
        let upload = StubProtocol.seen.last!.request
        XCTAssertEqual(upload.httpMethod, "PUT")
        XCTAssertEqual(upload.url!.absoluteString, "https://eapi.pcloud.com/uploadfile?path=%2Fworkouts&filename=a.json&nopartial=1")

        StubProtocol.reset { _, _ in .init(body: json(["result": 2094, "error": "Invalid access_token"])) }
        do {
            _ = try await drive.list("")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInExpired)
        }
    }
}

// MARK: - a real WebDAV server

/// Runs only when a WebDAV server answers on this Mac (Apache with mod_dav, started by `scripts/webdav-test-server.sh`).
/// The whole mirror against a server someone else wrote: folders, uploads, the listing, a plan coming back.
final class WebDAVLiveTests: XCTestCase {
    static let port = 8765
    static let dataRoot = "/tmp/healthaccess-webdav/root"

    private func liveDrive() async throws -> WebDAVDrive {
        var http = CloudHTTP(session: CloudHTTP.makeSession(), tokens: BasicAuth(user: "anna", password: "test-password"))
        http.maxAttempts = 1
        let drive = WebDAVDrive(http: http, base: URL(string: "http://127.0.0.1:\(Self.port)/files")!)
        do {
            _ = try await drive.list("")
        } catch let error as CloudError where error == .signInExpired || error.endsRun {
            // No server, or one started with `lan` for a phone test, which has another password and real data.
            throw XCTSkip("no WebDAV test server with the test password on port \(Self.port)")
        }
        return drive
    }

    func testTheMirrorAgainstApache() async throws {
        let drive = try await liveDrive()
        let server = URL(fileURLWithPath: Self.dataRoot).appendingPathComponent("files/Health Access")
        try? FileManager.default.removeItem(at: server)

        let folder = TempFolder()
        folder.write("index.json", "{}")
        folder.write("briefing.md", "# briefing ž")
        folder.write("workouts/2026-11-18_1045_PoolSwim_548573A1.json", #"{"w":1}"#, age: 100)
        folder.write("days/2026-11-18.json", #"{"d":1}"#, age: 200)
        folder.write("plans/2026-11-16T16:02:07Z-a2 steady.json", #"{"p":1}"#, age: 300)

        let mirror = CloudMirror(kind: .webdav, drive: drive)
        let first = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(first.uploaded, 5)
        XCTAssertEqual(first.failed, 0, first.firstFailure ?? "")
        let onServer = { (path: String) in try? String(contentsOf: server.appendingPathComponent(path), encoding: .utf8) }
        XCTAssertEqual(onServer("workouts/2026-11-18_1045_PoolSwim_548573A1.json"), #"{"w":1}"#)
        XCTAssertEqual(onServer("briefing.md"), "# briefing ž")
        XCTAssertEqual(onServer("plans/2026-11-16T16_02_07Z-a2 steady.json"), #"{"p":1}"#)
        XCTAssertEqual(onServer("plans/inbox.json"), "[]\n")
        XCTAssertTrue(onServer("README.md")?.contains("How to send a workout plan") == true)

        let second = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.pulled, 0, "its own plan is not taken for a new one")

        // Someone else writes a plan on the server, and one into the inbox.
        try #"{"id":"from-server"}"#.write(to: server.appendingPathComponent("plans/from-server.json"), atomically: true, encoding: .utf8)
        try #"[{"id":"from-inbox","name":"Inbox"}]"#.write(to: server.appendingPathComponent("plans/inbox.json"), atomically: true, encoding: .utf8)
        let third = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(third.pulled, 2)
        XCTAssertEqual(folder.read("plans/from-server.json"), #"{"id":"from-server"}"#)
        XCTAssertNotNil(folder.read("plans/from-inbox.json"))
        XCTAssertNotNil(onServer("plans/from-inbox.json"), "the inbox plan goes up as a plan file")

        // A status file the app removes again goes from the server too.
        folder.write("plans/from-server.status.json", #"{"state":"scheduled"}"#)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertNotNil(onServer("plans/from-server.status.json"))
        try folder.store.remove("plans/from-server.status.json")
        let last = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(last.removed, 1)
        XCTAssertNil(onServer("plans/from-server.status.json"))

        // A reconnect finds everything and uploads what it cannot compare, without a second copy.
        let again = try await CloudMirror(kind: .webdav, drive: drive).run(folder: folder.store, mode: .full)
        XCTAssertEqual(again.failed, 0)
        XCTAssertEqual(again.pulled, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: server.appendingPathComponent("plans").path).sorted()
        XCTAssertEqual(names, ["2026-11-16T16_02_07Z-a2 steady.json", "from-inbox.json", "from-server.json", "inbox.json"])
    }

    func testAWrongPasswordIsReportedAsSuch() async throws {
        _ = try await liveDrive()
        var http = CloudHTTP(session: CloudHTTP.makeSession(), tokens: BasicAuth(user: "anna", password: "wrong"))
        http.maxAttempts = 1
        do {
            _ = try await WebDAVDrive(http: http, base: URL(string: "http://127.0.0.1:\(Self.port)/files")!).list("")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInExpired)
        }
    }
}

// MARK: - what goes wrong, and what the user is told

final class ComplicationTests: XCTestCase {
    func testAFailedConnectionIsExplainedNotJustCalledOffline() {
        func explain(_ code: URLError.Code, host: String = "cloud.example.com") -> CloudError? {
            CloudHTTP.explain(URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://\(host)/dav")!])) as? CloudError
        }
        XCTAssertEqual(explain(.notConnectedToInternet), .offline)
        if case .unreachable(let text)? = explain(.serverCertificateUntrusted) { XCTAssertTrue(text.contains("certificate")) } else { XCTFail() }
        if case .unreachable(let text)? = explain(.cannotFindHost) { XCTAssertTrue(text.contains("address")) } else { XCTFail() }
        if case .unreachable(let text)? = explain(.timedOut, host: "nas.local") { XCTAssertTrue(text.contains("local network")) } else { XCTFail() }
        XCTAssertTrue(CloudHTTP.explain(URLError(.cancelled)) is CancellationError)
    }

    func testOnlySomeErrorsEndAWholeRun() {
        XCTAssertTrue(CloudError.offline.endsRun && CloudError.signInExpired.endsRun && CloudError.slowDown.endsRun
                      && CloudError.waitingForWiFi.endsRun && CloudError.unreachable("x").endsRun)
        XCTAssertFalse(CloudError.http(400, "").endsRun || CloudError.unexpected("x").endsRun)
    }

    func testADriveThatKeepsSayingSlowDownEndsTheRun() async throws {
        var calls = 0
        StubProtocol.reset { _, _ in calls += 1; return .init(status: 429, headers: ["Retry-After": "0"]) }
        let folder = TempFolder()
        folder.write("workouts/a.json", "{}")
        folder.write("workouts/b.json", "{}")
        do {
            _ = try await CloudMirror(kind: .dropbox, drive: Dropbox(http: stubHTTP())).run(folder: folder.store, mode: .full)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .slowDown)
        }
        XCTAssertEqual(calls, 4, "one call, tried four times, and no second file after it")
    }

    func testARedirectToAnotherHostLosesTheSignIn() {
        var redirect = URLRequest(url: URL(string: "https://elsewhere.example.com/x")!)
        redirect.setValue("Basic abc", forHTTPHeaderField: "Authorization")
        redirect.setValue("keep", forHTTPHeaderField: "Content-Type")
        let cleaned = RedirectGuard.cleaned(redirect, from: URL(string: "https://cloud.example.com/dav"))
        XCTAssertNil(cleaned.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(cleaned.value(forHTTPHeaderField: "Content-Type"), "keep")
        var same = URLRequest(url: URL(string: "https://cloud.example.com/dav/other")!)
        same.setValue("Basic abc", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(RedirectGuard.cleaned(same, from: URL(string: "https://cloud.example.com/dav")).value(forHTTPHeaderField: "Authorization"), "Basic abc")
        var downgraded = URLRequest(url: URL(string: "http://cloud.example.com/dav")!)
        downgraded.setValue("Basic abc", forHTTPHeaderField: "Authorization")
        XCTAssertNil(RedirectGuard.cleaned(downgraded, from: URL(string: "https://cloud.example.com/dav")).value(forHTTPHeaderField: "Authorization"), "not from https to http either")
    }

    func testFilesThatAreInICloudOnlyAreCountedNotLost() async throws {
        let folder = TempFolder()
        folder.write("workouts/here.json", "{}")
        folder.write("workouts/.away.json.icloud", "placeholder")
        folder.write("mcp/clients/.x.json.icloud", "placeholder")
        folder.write(".Trash/old.json", "{}")
        let survey = try CloudScanner.survey(folder.store)
        XCTAssertEqual(survey.files.map(\.path), ["workouts/here.json"])
        XCTAssertEqual(survey.inICloud, ["workouts/away.json"])
        let summary = try await CloudMirror(kind: .dropbox, drive: FakeDrive()).run(folder: folder.store, mode: .full)
        XCTAssertEqual(summary.inICloud, 1)
        XCTAssertEqual(summary.uploaded, 1)
    }

    func testADisconnectedMirrorDoesNotWriteItsStateBack() async throws {
        let folder = TempFolder()
        folder.write("index.json", "{}")
        let url = folder.url.deletingLastPathComponent().appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let mirror = CloudMirror(kind: .dropbox, drive: FakeDrive(), stateURL: url)
        await mirror.retire()
        _ = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a new connection must not inherit what an old one uploaded")
    }

    func testAPlanTheAppCannotReadGetsAStatusFileAndLosesItWhenFixed() throws {
        let folder = TempFolder()
        folder.write("plans/broken.json", #"{"schema":"healthaccess.plan.v1","id":"broken"}"#)
        var items = try PlanInstaller.scan(folder: folder.store)
        XCTAssertTrue(AppModel.notePlanProblems(items, folder: folder.store))
        let status = try HealthAccessJSON.decode(PlanStatus.self, from: try XCTUnwrap(folder.store.read("plans/broken.status.json")))
        XCTAssertEqual(status.state, "failed")
        XCTAssertTrue(status.error?.hasPrefix("not a valid plan: ") == true)
        items = try PlanInstaller.scan(folder: folder.store)
        XCTAssertFalse(AppModel.notePlanProblems(items, folder: folder.store), "written once, not on every scan")

        // The AI writes a valid plan into the same file: the note goes, the plan waits like any other.
        let guide = PlanGuide.text(for: .dropbox)
        let start = try XCTUnwrap(guide.range(of: "```json\n")), end = try XCTUnwrap(guide.range(of: "\n```", range: start.upperBound..<guide.endIndex))
        folder.write("plans/broken.json", String(guide[start.upperBound..<end.lowerBound]))
        items = try PlanInstaller.scan(folder: folder.store)
        XCTAssertTrue(AppModel.notePlanProblems(items, folder: folder.store))
        XCTAssertNil(try folder.store.read("plans/broken.status.json"))
        XCTAssertEqual(try PlanInstaller.scan(folder: folder.store).first?.state, .pending)
    }

    func testTheGuideStepsAsideForAReadmeTheUserKeeps() async throws {
        let folder = TempFolder(), drive = FakeDrive()
        folder.write("index.json", "{}")
        let mirror = CloudMirror(kind: .dropbox, drive: drive)
        _ = try await mirror.run(folder: folder.store, mode: .full)
        var guide = await drive.files["README.md"]?.data
        XCTAssertTrue(guide.map { String(decoding: $0, as: UTF8.self) }?.contains("How to send a workout plan") == true)

        folder.write("README.md", "my own notes")
        _ = try await mirror.run(folder: folder.store, mode: .full)
        let own = await drive.files["README.md"]?.data
        XCTAssertEqual(own, Data("my own notes".utf8), "the user's file wins the name")
        guide = await drive.files["README-health-access.md"]?.data
        XCTAssertTrue(guide.map { String(decoding: $0, as: UTF8.self) }?.contains("How to send a workout plan") == true)
        await drive.resetLog()
        let again = try await mirror.run(folder: folder.store, mode: .full)
        XCTAssertEqual(again.uploaded, 0)
        let puts = await drive.puts
        XCTAssertEqual(puts, [], "and the two do not overwrite each other on every run")
    }

    func testAskingForADriveSendsOneSmallEventAndNothingElse() throws {
        let request = try XCTUnwrap(DriveInterest.request(host: "https://eu.i.posthog.com/", token: "phc_test", installID: "11111111-2222-3333-4444-555555555555",
                                                          drive: .onedrive, version: "1.1.0", build: "34"))
        XCTAssertEqual(request.url?.absoluteString, "https://eu.i.posthog.com/i/v0/e/")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["api_key", "event", "distinct_id", "properties"])
        XCTAssertEqual(body["event"] as? String, "drive_interest")
        XCTAssertEqual(body["distinct_id"] as? String, "11111111-2222-3333-4444-555555555555")
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["drive", "$app_version", "$app_build", "$lib", "$process_person_profile", "$geoip_disable"])
        XCTAssertEqual(properties["drive"] as? String, "onedrive")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertNil(DriveInterest.request(host: "http://example.com", token: "t", installID: "i", drive: .onedrive, version: "1", build: "1"), "never over plain http")
    }

    func testTheMessageForTheAINamesTheCloudCopy() {
        let plain = SetupMessage.text(for: nil, summary: nil)
        XCTAssertFalse(plain.contains("connector:"))
        let cloud = SetupMessage.text(for: nil, summary: "S", drives: [(name: "Google Drive", place: "My Drive › Health Access"), (name: "Dropbox", place: "Apps › Health Access")])
        XCTAssertTrue(cloud.contains("If you can read my Google Drive or Dropbox through a connector:"))
        XCTAssertTrue(cloud.contains("Google Drive (My Drive › Health Access), Dropbox (Apps › Health Access)"))
        XCTAssertTrue(cloud.contains("README.md"))
    }

    func testTheFolderOnThisIPhoneNeedsNoBookmarkAndSurvivesARestart() throws {
        defer { FolderStore.forget() }
        let store = try FolderStore.useAppFolder()
        XCTAssertTrue(store.root.path.hasSuffix("/Documents/Health Access"))
        XCTAssertEqual(FolderStore.restore()?.store.root.path, store.root.path)
        XCTAssertEqual(FolderStore.restore()?.stale, false)
        XCTAssertEqual(store.provider, .onMyiPhone)
        FolderStore.forget()
        XCTAssertFalse(FolderStore.usesAppFolder)
    }
}

final class FolderPlaceTests: XCTestCase {
    func testEveryDriveSaysWhereTheFolderGoes() {
        for kind in CloudKind.allCases { XCTAssertFalse(kind.newFolderWhere.isEmpty, kind.rawValue) }
        XCTAssertTrue(CloudKind.google.newFolderWhere.contains("top level"))
        XCTAssertFalse(CloudKind.google.isBeta)
    }
}

final class FolderChoiceTests: XCTestCase {
    func testTheQuestionNamesTheDrivesThisBuildOffers() {
        let line = FolderChoiceCopy.drivesLine(["Google Drive", "WebDAV server", "S3 storage"])
        XCTAssertTrue(line.hasPrefix("Google Drive, WebDAV server or S3 storage."))
        XCTAssertTrue(line.contains("keeps your files on this iPhone"))
    }
}
