import Foundation

/// OneDrive through Microsoft Graph, with `Files.ReadWrite.AppFolder`: the app gets one folder of its own
/// (Apps › Health Access) and sees everything in it, also what someone else puts there. Files go by path.
actor OneDrive: CloudDrive {
    private static let root = "https://graph.microsoft.com/v1.0/me/drive/special/approot"
    private static let items = "https://graph.microsoft.com/v1.0/me/drive/items"
    /// Graph takes a file in one request up to here; a bigger one goes through an upload session.
    static let singleRequestLimit = 4 * 1024 * 1024
    /// Pieces of an upload session have to be a multiple of 320 KiB.
    static let chunk = 320 * 1024 * 32

    private let http: CloudHTTP

    init(http: CloudHTTP) { self.http = http }

    func folderCache() -> [String: String] { [:] }

    static func address(_ path: String) -> String {
        path.isEmpty ? root : "\(root):/\(CloudPath.encode(path)):"
    }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        if data.count <= Self.singleRequestLimit {
            var request = URLRequest(url: URL(string: "\(Self.address(path))/content")!)
            request.httpMethod = "PUT"
            request.setValue(CloudPath.contentType(path), forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            return try Self.ref(try await http.send(request).0)
        }
        var start = URLRequest(url: URL(string: "\(Self.address(path))/createUploadSession")!)
        start.httpMethod = "POST"
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = Data(#"{"item":{"@microsoft.graph.conflictBehavior":"replace"}}"#.utf8)
        let session = try CloudHTTP.json(try await http.send(start).0)
        guard let target = (session["uploadUrl"] as? String).flatMap(URL.init(string:)) else {
            throw CloudError.unexpected("OneDrive gave no place to send the file to")
        }
        var offset = 0
        var last = Data()
        while offset < data.count {
            let end = min(offset + Self.chunk, data.count)
            // The upload address carries its own permission; Graph rejects a bearer token on it.
            var request = URLRequest(url: target)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            request.httpBody = data.subdata(in: offset..<end)
            let (body, response) = try await http.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw CloudError.http(status, CloudHTTP.snippet(body)) }
            last = body
            offset = end
        }
        return try Self.ref(last)
    }

    private static func ref(_ body: Data) throws -> RemoteRef {
        let object = try CloudHTTP.json(body)
        guard let id = object["id"] as? String else { throw CloudError.unexpected("OneDrive's answer carried no file id") }
        return RemoteRef(id: id, rev: object["cTag"] as? String ?? object["eTag"] as? String ?? "")
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        var next = URL(string: "\(Self.address(directory))/children?$select=id,name,size,cTag,eTag,folder&$top=200")
        var entries: [RemoteEntry] = []
        while let url = next {
            let (body, response) = try await http.send(URLRequest(url: url), accept: [404])
            if response.statusCode == 404 { return [] }
            let object = try CloudHTTP.json(body)
            for item in object["value"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                entries.append(RemoteEntry(name: name, ref: RemoteRef(id: id, rev: item["cTag"] as? String ?? item["eTag"] as? String ?? ""),
                                           size: (item["size"] as? NSNumber)?.intValue ?? 0, isFolder: item["folder"] != nil))
            }
            next = (object["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return entries
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        try await http.send(URLRequest(url: URL(string: "\(Self.items)/\(CloudPath.encodeSegment(ref.id))/content")!)).0
    }

    /// Into OneDrive's recycle bin.
    func delete(_ ref: RemoteRef) async throws {
        var request = URLRequest(url: URL(string: "\(Self.items)/\(CloudPath.encodeSegment(ref.id))")!)
        request.httpMethod = "DELETE"
        _ = try await http.send(request, accept: [404])
    }
}
