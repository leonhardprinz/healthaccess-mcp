import Foundation

/// Google Drive through its REST API, with `drive.file` access: the app sees the files and folders it created,
/// nothing else in the Drive. Files live in folders by id, so the ids of the app's folders are remembered.
actor GoogleDrive: CloudDrive {
    static let rootName = "Health Access"
    private static let folderType = "application/vnd.google-apps.folder"
    private static let api = "https://www.googleapis.com/drive/v3/files"
    private static let upload = "https://www.googleapis.com/upload/drive/v3/files"
    /// One request carries the file up to this size; a bigger one goes in two steps.
    static let singleRequestLimit = 4 * 1024 * 1024

    private let http: CloudHTTP
    /// Directory path → folder id. "" is the Health Access folder itself.
    private var folders: [String: String]

    init(http: CloudHTTP, folders: [String: String] = [:]) {
        self.http = http
        self.folders = folders
    }

    func folderCache() -> [String: String] { folders }

    /// Google's rev for a file is the MD5 of its content, so an unchanged file can be recognised without uploading it.
    nonisolated func rev(of data: Data) -> String? { data.md5Hex }

    // MARK: files

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        let (directory, name) = CloudPath.split(path)
        if let known {
            if let ref = try await update(data, id: known.id, name: name) { return ref }
            // 404: the file was deleted in Drive. Make it again.
        }
        do {
            return try await create(data, name: name, parent: try await folder(directory, create: true)!)
        } catch CloudError.http(404, _) {
            // The folder was deleted in Drive. Forget the ids and build the path again, once.
            folders = [:]
            return try await create(data, name: name, parent: try await folder(directory, create: true)!)
        }
    }

    private func update(_ data: Data, id: String, name: String) async throws -> RemoteRef? {
        let query = "fields=id,md5Checksum"
        if data.count <= Self.singleRequestLimit {
            var request = URLRequest(url: URL(string: "\(Self.upload)/\(id)?uploadType=media&\(query)")!)
            request.httpMethod = "PATCH"
            request.setValue(CloudPath.contentType(name), forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let (body, response) = try await http.send(request, accept: [404])
            return response.statusCode == 404 ? nil : try Self.ref(body)
        }
        var start = URLRequest(url: URL(string: "\(Self.upload)/\(id)?uploadType=resumable&\(query)")!)
        start.httpMethod = "PATCH"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(CloudPath.contentType(name), forHTTPHeaderField: "X-Upload-Content-Type")
        start.httpBody = Data("{}".utf8)
        let (_, response) = try await http.send(start, accept: [404])
        if response.statusCode == 404 { return nil }
        return try await finishResumable(response, data: data, name: name)
    }

    private func create(_ data: Data, name: String, parent: String) async throws -> RemoteRef {
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        let query = "fields=id,md5Checksum"
        if data.count <= Self.singleRequestLimit {
            let boundary = "healthaccess-\(UUID().uuidString)"
            var request = URLRequest(url: URL(string: "\(Self.upload)?uploadType=multipart&\(query)")!)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipart(metadata: metadata, data: data, contentType: CloudPath.contentType(name), boundary: boundary)
            return try Self.ref(try await http.send(request).0)
        }
        var start = URLRequest(url: URL(string: "\(Self.upload)?uploadType=resumable&\(query)")!)
        start.httpMethod = "POST"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(CloudPath.contentType(name), forHTTPHeaderField: "X-Upload-Content-Type")
        start.httpBody = metadata
        return try await finishResumable(try await http.send(start).1, data: data, name: name)
    }

    private func finishResumable(_ response: HTTPURLResponse, data: Data, name: String) async throws -> RemoteRef {
        guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw CloudError.unexpected("Google Drive gave no place to send the file to")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(CloudPath.contentType(name), forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try Self.ref(try await http.send(request).0)
    }

    static func multipart(metadata: Data, data: Data, contentType: String, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func ref(_ body: Data) throws -> RemoteRef {
        let object = try CloudHTTP.json(body)
        guard let id = object["id"] as? String else { throw CloudError.unexpected("Google Drive's answer carried no file id") }
        return RemoteRef(id: id, rev: object["md5Checksum"] as? String ?? "")
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        guard let parent = try await folder(directory, create: false) else { return [] }
        do {
            return try await children(of: parent)
        } catch CloudError.http(404, _) {
            folders = [:]
            return []
        }
    }

    private func children(of parent: String, named name: String? = nil, foldersOnly: Bool = false) async throws -> [RemoteEntry] {
        var q = "'\(Self.quote(parent))' in parents and trashed = false"
        if let name { q += " and name = '\(Self.quote(name))'" }
        if foldersOnly { q += " and mimeType = '\(Self.folderType)'" }
        var entries: [RemoteEntry] = []
        var pageToken: String?
        repeat {
            var parts = URLComponents(string: Self.api)!
            parts.queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,md5Checksum,size,mimeType)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "spaces", value: "drive"),
            ]
            if let pageToken { parts.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            // URLComponents leaves "+" alone, and Google reads it as a space.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let object = try CloudHTTP.json(try await http.send(URLRequest(url: parts.url!)).0)
            for file in object["files"] as? [[String: Any]] ?? [] {
                guard let id = file["id"] as? String, let name = file["name"] as? String else { continue }
                let size = (file["size"] as? String).flatMap(Int.init) ?? (file["size"] as? NSNumber)?.intValue ?? 0
                entries.append(RemoteEntry(name: name, ref: RemoteRef(id: id, rev: file["md5Checksum"] as? String ?? ""),
                                           size: size, isFolder: file["mimeType"] as? String == Self.folderType))
            }
            pageToken = object["nextPageToken"] as? String
        } while pageToken != nil
        return entries
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        try await http.send(URLRequest(url: URL(string: "\(Self.api)/\(CloudPath.encodeSegment(ref.id))?alt=media")!)).0
    }

    /// Into Drive's bin, where the user can get it back for 30 days.
    func delete(_ ref: RemoteRef) async throws {
        var request = URLRequest(url: URL(string: "\(Self.api)/\(CloudPath.encodeSegment(ref.id))")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"trashed":true}"#.utf8)
        _ = try await http.send(request, accept: [404])
    }

    // MARK: folders

    /// The id of a directory, made on the way when `create` is set. A folder this app made on an earlier install
    /// is found by name and used again, so a reconnect does not start a second "Health Access".
    private func folder(_ directory: String, create: Bool) async throws -> String? {
        if let id = folders[directory] { return id }
        let parentID: String
        let name: String
        if directory.isEmpty {
            parentID = "root"
            name = Self.rootName
        } else {
            let (up, last) = CloudPath.split(directory)
            guard let id = try await folder(up, create: create) else { return nil }
            parentID = id
            name = last
        }
        if let existing = try await children(of: parentID, named: name, foldersOnly: true).first {
            folders[directory] = existing.ref.id
            return existing.ref.id
        }
        guard create else { return nil }
        var request = URLRequest(url: URL(string: "\(Self.api)?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderType, "parents": [parentID]])
        let object = try CloudHTTP.json(try await http.send(request).0)
        guard let id = object["id"] as? String else { throw CloudError.unexpected("Google Drive made no folder") }
        folders[directory] = id
        return id
    }

    /// A value inside single quotes in a Drive query.
    static func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}
