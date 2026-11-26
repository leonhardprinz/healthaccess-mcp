import Foundation

/// Any WebDAV server: Nextcloud, ownCloud, a Synology or QNAP NAS, Koofr, Hetzner Storage Box and many more.
/// The user gives the address of a folder there, a name and a password (an app password where the server has them).
/// Files go by path into `Health Access` inside that folder. WebDAV has no file ids, so a file's id is its path.
actor WebDAVDrive: CloudDrive {
    static let rootName = "Health Access"

    private let http: CloudHTTP
    private let base: String
    /// Directories known to exist in this session.
    private var made: Set<String> = []

    /// `base` is the folder the user named, e.g. `https://cloud.example.com/remote.php/dav/files/anna`.
    init(http: CloudHTTP, base: URL) {
        self.http = http
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        self.base = text
    }

    func folderCache() -> [String: String] { [:] }

    /// The checks before anything is saved: an address a phone can reach safely, and nothing odd in it.
    static func validate(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.query == nil, url.fragment == nil else {
            throw CloudError.unexpected("That is not a server address. It looks like https://cloud.example.com/remote.php/dav/files/you")
        }
        if scheme == "https" { return url }
        // iOS lets an app talk without encryption only to a server on the local network.
        if scheme == "http", isLocal(host) { return url }
        throw CloudError.unexpected("The address has to start with https://. Only a server in your own network (a name ending in .local, or a private address) may use http://.")
    }

    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254)
    }

    func address(_ path: String) -> URL {
        let full = path.isEmpty ? Self.rootName : Self.rootName + "/" + path
        return URL(string: base + "/" + CloudPath.encode(full))!
    }

    private func ensure(_ directory: String) async throws {
        if made.contains(directory) { return }
        if !directory.isEmpty { try await ensure(CloudPath.split(directory).directory) }
        var request = URLRequest(url: address(directory))
        request.httpMethod = "MKCOL"
        // 405: it is there already. Servers differ on the others for the same case.
        _ = try await http.send(request, accept: [405, 301, 302])
        made.insert(directory)
    }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        try await ensure(CloudPath.split(path).directory)
        var request = URLRequest(url: address(path))
        request.httpMethod = "PUT"
        request.setValue(CloudPath.contentType(path), forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        var (_, response) = try await http.send(request, accept: [404, 409])
        if response.statusCode == 404 || response.statusCode == 409 {
            // The folder was removed on the server since this session made it.
            made = []
            try await ensure(CloudPath.split(path).directory)
            (_, response) = try await http.send(request)
        }
        return RemoteRef(id: path, rev: response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "OC-ETag") ?? "")
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        let url = address(directory)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (body, response) = try await http.send(request, accept: [404])
        if response.statusCode == 404 { return [] }
        return Self.entries(try CloudXML.parse(body, records: ["response"]), directory: directory, selfPath: url.path)
    }

    /// The answer lists the folder itself first; everything else is one of its children.
    static func entries(_ xml: CloudXML.Result, directory: String, selfPath: String) -> [RemoteEntry] {
        func plain(_ path: String) -> String {
            var path = path.removingPercentEncoding ?? path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let own = plain(selfPath)
        var out: [RemoteEntry] = []
        for record in xml.records {
            guard let href = record["href"] else { continue }
            // An href is a path or a whole address, percent-encoded.
            let path = plain(URL(string: href)?.path ?? href)
            guard path != own, let name = path.split(separator: "/").last.map(String.init), !name.isEmpty else { continue }
            out.append(RemoteEntry(name: name, ref: RemoteRef(id: CloudPath.join(directory, name), rev: record["getetag"] ?? ""),
                                   size: Int(record["getcontentlength"] ?? "") ?? 0, isFolder: record["collection"] != nil))
        }
        return out
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        try await http.send(URLRequest(url: address(ref.id))).0
    }

    func delete(_ ref: RemoteRef) async throws {
        var request = URLRequest(url: address(ref.id))
        request.httpMethod = "DELETE"
        _ = try await http.send(request, accept: [404])
    }
}
