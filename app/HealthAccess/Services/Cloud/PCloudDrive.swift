import Foundation

/// pCloud through its HTTP API, as an app with its own folder. Files go by path. pCloud answers every call
/// with HTTP 200 and says in the body whether it worked, so the result code is read here.
actor PCloudDrive: CloudDrive {
    private let http: CloudHTTP
    /// `api.pcloud.com` (United States) or `eapi.pcloud.com` (Europe): the region the account lives in.
    private let host: String
    private var made: Set<String> = [""]

    init(http: CloudHTTP, host: String) {
        self.http = http
        self.host = host
    }

    func folderCache() -> [String: String] { [:] }

    private func call(_ method: String, _ query: [(String, String)], body: Data? = nil, missingIsNil: Bool = false) async throws -> [String: Any]? {
        let text = "https://\(host)/\(method)?" + query.map { "\(CloudPath.encodeSegment($0.0))=\(CloudPath.encodeSegment($0.1))" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: text)!)
        if let body {
            request.httpMethod = "PUT"
            request.httpBody = body
        }
        let object = try CloudHTTP.json(try await http.send(request).0)
        let result = (object["result"] as? NSNumber)?.intValue ?? -1
        switch result {
        case 0: return object
        case 1000, 2000, 2094, 2095: throw CloudError.signInExpired
        case 2005, 2009, 2055: if missingIsNil { return nil }
        default: break
        }
        throw CloudError.http(result == 4000 ? 429 : 400, "pCloud \(result): \(object["error"] as? String ?? "")")
    }

    private func ensure(_ directory: String) async throws {
        if made.contains(directory) { return }
        try await ensure(CloudPath.split(directory).directory)
        _ = try await call("createfolderifnotexists", [("path", "/" + directory)])
        made.insert(directory)
    }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        let (directory, name) = CloudPath.split(path)
        try await ensure(directory)
        let query = [("path", "/" + directory), ("filename", name), ("nopartial", "1")]
        var answer = try await call("uploadfile", query, body: data, missingIsNil: true)
        if answer == nil {
            made = [""]   // the folder was deleted in pCloud
            try await ensure(directory)
            answer = try await call("uploadfile", query, body: data)
        }
        guard let file = (answer?["metadata"] as? [[String: Any]])?.first, let ref = Self.ref(file) else {
            throw CloudError.unexpected("pCloud's answer carried no file id")
        }
        return ref
    }

    private static func ref(_ file: [String: Any]) -> RemoteRef? {
        guard let id = (file["fileid"] as? NSNumber)?.stringValue ?? (file["folderid"] as? NSNumber)?.stringValue else { return nil }
        return RemoteRef(id: id, rev: (file["hash"] as? NSNumber)?.stringValue ?? "")
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        guard let answer = try await call("listfolder", [("path", "/" + directory)], missingIsNil: true) else { return [] }
        let contents = (answer["metadata"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        return contents.compactMap { item in
            guard let name = item["name"] as? String, let ref = Self.ref(item) else { return nil }
            return RemoteEntry(name: name, ref: ref, size: (item["size"] as? NSNumber)?.intValue ?? 0, isFolder: item["isfolder"] as? Bool == true)
        }
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        guard let link = try await call("getfilelink", [("fileid", ref.id)]),
              let server = (link["hosts"] as? [String])?.first, let path = link["path"] as? String,
              server.hasSuffix("pcloud.com"), let url = URL(string: "https://\(server)\(path)") else {
            throw CloudError.unexpected("pCloud gave no download address")
        }
        // The download address carries its own permission.
        let (data, response) = try await http.session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CloudError.http(status, "") }
        return data
    }

    /// Into pCloud's trash.
    func delete(_ ref: RemoteRef) async throws {
        _ = try await call("deletefile", [("fileid", ref.id)], missingIsNil: true)
    }
}
