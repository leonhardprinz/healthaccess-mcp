import Foundation

/// Box through its REST API. Box has no "one folder only" permission: the sign-in gives the app the whole
/// account, and the app keeps to its own `Health Access` folder. Files live in folders by id, as on Google Drive.
actor BoxDrive: CloudDrive {
    static let rootName = "Health Access"
    private static let api = "https://api.box.com/2.0"
    private static let upload = "https://upload.box.com/api/2.0"
    /// Box takes a file in one request up to here.
    static let singleRequestLimit = 50 * 1024 * 1024

    private let http: CloudHTTP
    private var folders: [String: String]

    init(http: CloudHTTP, folders: [String: String] = [:]) {
        self.http = http
        self.folders = folders
    }

    func folderCache() -> [String: String] { folders }

    /// Box's rev for a file is the SHA-1 of its content.
    nonisolated func rev(of data: Data) -> String? { data.sha1Hex }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        guard data.count <= Self.singleRequestLimit else { throw CloudError.unexpected("larger than 50 MB, which Box takes only in pieces") }
        let (directory, name) = CloudPath.split(path)
        if let known, let ref = try await send(data, name: name, to: "\(Self.upload)/files/\(known.id)/content", attributes: nil) { return ref }
        for attempt in 0..<2 {
            let parent = try await folder(directory, create: true)!
            let attributes = try JSONSerialization.data(withJSONObject: ["name": name, "parent": ["id": parent]])
            var request = Self.multipart(data: data, name: name, attributes: attributes, url: URL(string: "\(Self.upload)/files/content")!)
            request.httpMethod = "POST"
            let (body, response) = try await http.send(request, accept: [404, 409])
            if response.statusCode == 409 {
                // A file of that name is there already; the answer says which. Give it a new version.
                guard let existing = Self.conflictID(body),
                      let ref = try await send(data, name: name, to: "\(Self.upload)/files/\(existing)/content", attributes: nil) else {
                    throw CloudError.http(409, CloudHTTP.snippet(body))
                }
                return ref
            }
            if response.statusCode == 404, attempt == 0 {
                folders = [:]   // the folder was deleted in Box
                continue
            }
            if response.statusCode == 404 { throw CloudError.http(404, CloudHTTP.snippet(body)) }
            return try Self.ref(body)
        }
        throw CloudError.unexpected("Box did not take the file")
    }

    /// A new version of an existing file. `nil` when Box no longer has that file.
    private func send(_ data: Data, name: String, to address: String, attributes: Data?) async throws -> RemoteRef? {
        var request = Self.multipart(data: data, name: name, attributes: attributes, url: URL(string: address)!)
        request.httpMethod = "POST"
        let (body, response) = try await http.send(request, accept: [404])
        return response.statusCode == 404 ? nil : try Self.ref(body)
    }

    static func multipart(data: Data, name: String, attributes: Data?, url: URL) -> URLRequest {
        let boundary = "healthaccess-\(UUID().uuidString)"
        var body = Data()
        if let attributes {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n".utf8))
            body.append(attributes)
            body.append(Data("\r\n".utf8))
        }
        // The name in the header is a fixed word: the real name travels in `attributes`, where any character is safe.
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\nContent-Type: \(CloudPath.contentType(name))\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func ref(_ body: Data) throws -> RemoteRef {
        let object = try CloudHTTP.json(body)
        guard let entry = (object["entries"] as? [[String: Any]])?.first, let id = entry["id"] as? String else {
            throw CloudError.unexpected("Box's answer carried no file id")
        }
        return RemoteRef(id: id, rev: entry["sha1"] as? String ?? "")
    }

    static func conflictID(_ body: Data) -> String? {
        guard let context = (try? CloudHTTP.json(body))?["context_info"] as? [String: Any] else { return nil }
        if let one = context["conflicts"] as? [String: Any] { return one["id"] as? String }
        return (context["conflicts"] as? [[String: Any]])?.first?["id"] as? String
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        guard let id = try await folder(directory, create: false) else { return [] }
        do {
            return try await items(in: id)
        } catch CloudError.http(404, _) {
            folders = [:]
            return []
        }
    }

    private func items(in folder: String) async throws -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        var offset = 0
        while true {
            let url = URL(string: "\(Self.api)/folders/\(folder)/items?fields=id,name,type,sha1,size&limit=1000&offset=\(offset)")!
            let object = try CloudHTTP.json(try await http.send(URLRequest(url: url)).0)
            let page = object["entries"] as? [[String: Any]] ?? []
            for item in page {
                guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                entries.append(RemoteEntry(name: name, ref: RemoteRef(id: id, rev: item["sha1"] as? String ?? ""),
                                           size: (item["size"] as? NSNumber)?.intValue ?? 0, isFolder: item["type"] as? String == "folder"))
            }
            offset += page.count
            let total = (object["total_count"] as? NSNumber)?.intValue ?? 0
            if page.isEmpty || offset >= total { return entries }
        }
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        try await http.send(URLRequest(url: URL(string: "\(Self.api)/files/\(CloudPath.encodeSegment(ref.id))/content")!)).0
    }

    /// Into Box's trash.
    func delete(_ ref: RemoteRef) async throws {
        var request = URLRequest(url: URL(string: "\(Self.api)/files/\(CloudPath.encodeSegment(ref.id))")!)
        request.httpMethod = "DELETE"
        _ = try await http.send(request, accept: [404])
    }

    private func folder(_ directory: String, create: Bool) async throws -> String? {
        if let id = folders[directory] { return id }
        let parent: String
        let name: String
        if directory.isEmpty {
            parent = "0"
            name = Self.rootName
        } else {
            let (up, last) = CloudPath.split(directory)
            guard let id = try await folder(up, create: create) else { return nil }
            parent = id
            name = last
        }
        if let existing = try await items(in: parent).first(where: { $0.isFolder && $0.name == name }) {
            folders[directory] = existing.ref.id
            return existing.ref.id
        }
        guard create else { return nil }
        var request = URLRequest(url: URL(string: "\(Self.api)/folders")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parent": ["id": parent]])
        let (body, response) = try await http.send(request, accept: [409])
        let id = response.statusCode == 409 ? Self.conflictID(body) : try CloudHTTP.json(body)["id"] as? String
        guard let id else { throw CloudError.unexpected("Box made no folder") }
        folders[directory] = id
        return id
    }
}
