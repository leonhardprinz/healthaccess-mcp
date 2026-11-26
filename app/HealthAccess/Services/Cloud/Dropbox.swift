import Foundation

/// Dropbox through its HTTP API, as an "App folder" app: it gets Apps › Health Access and sees everything in it,
/// also what someone else puts there. Files go by path.
actor Dropbox: CloudDrive {
    private static let api = "https://api.dropboxapi.com/2/files"
    private static let content = "https://content.dropboxapi.com/2/files"

    private let http: CloudHTTP

    init(http: CloudHTTP) { self.http = http }

    func folderCache() -> [String: String] { [:] }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        var request = URLRequest(url: URL(string: "\(Self.content)/upload")!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(try Self.headerJSON(["path": "/" + path, "mode": "overwrite", "mute": true]), forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data
        return try Self.ref(try CloudHTTP.json(try await http.send(request).0))
    }

    private static func ref(_ object: [String: Any]) throws -> RemoteRef {
        guard let id = object["id"] as? String else { throw CloudError.unexpected("Dropbox's answer carried no file id") }
        return RemoteRef(id: id, rev: object["rev"] as? String ?? "")
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        var body: [String: Any] = ["path": directory.isEmpty ? "" : "/" + directory, "limit": 2000]
        var endpoint = "list_folder"
        while true {
            var request = URLRequest(url: URL(string: "\(Self.api)/\(endpoint)")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await http.send(request, accept: [409])
            if response.statusCode == 409 {
                // 409 is Dropbox's "this request cannot work"; for a folder that is not there it says path/not_found.
                if CloudHTTP.snippet(data).contains("not_found") { return [] }
                throw CloudError.http(409, CloudHTTP.snippet(data))
            }
            let object = try CloudHTTP.json(data)
            for entry in object["entries"] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String, let tag = entry[".tag"] as? String, tag != "deleted" else { continue }
                entries.append(RemoteEntry(name: name, ref: RemoteRef(id: entry["id"] as? String ?? "", rev: entry["rev"] as? String ?? ""),
                                           size: (entry["size"] as? NSNumber)?.intValue ?? 0, isFolder: tag == "folder"))
            }
            guard object["has_more"] as? Bool == true, let cursor = object["cursor"] as? String else { return entries }
            body = ["cursor": cursor]
            endpoint = "list_folder/continue"
        }
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.content)/download")!)
        request.httpMethod = "POST"
        request.setValue(try Self.headerJSON(["path": ref.id]), forHTTPHeaderField: "Dropbox-API-Arg")
        return try await http.send(request).0
    }

    /// Dropbox keeps deleted files for at least 30 days.
    func delete(_ ref: RemoteRef) async throws {
        var request = URLRequest(url: URL(string: "\(Self.api)/delete_v2")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": ref.id])
        _ = try await http.send(request, accept: [409])
    }

    /// JSON for an HTTP header: one line, and every character outside ASCII written as `\uXXXX`.
    static func headerJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        var out = ""
        for unit in String(decoding: data, as: UTF8.self).utf16 {
            if unit < 0x7F { out.unicodeScalars.append(Unicode.Scalar(UInt8(unit))) } else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }
}
