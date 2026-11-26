import CryptoKit
import Foundation

/// Where an S3 bucket is and how to sign for it.
struct S3Target: Sendable, Equatable {
    /// Empty for Amazon itself; otherwise the service's address (Cloudflare R2, Backblaze B2, MinIO, Wasabi, …).
    var endpoint: URL?
    var region: String
    var bucket: String
    /// The folder inside the bucket, without slashes at the ends. May be empty.
    var prefix: String
    var accessKey: String
    var secretKey: String

    static func make(_ fields: [String: String]) throws -> S3Target {
        func field(_ name: String) -> String { (fields[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let bucket = field("bucket"), access = field("accessKey"), secret = field("secretKey")
        guard !bucket.isEmpty, !access.isEmpty, !secret.isEmpty else { throw CloudError.unexpected("Enter a bucket, an access key and a secret key.") }
        guard bucket.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }) else {
            throw CloudError.unexpected("That is not a bucket name.")
        }
        var endpoint: URL?
        if !field("endpoint").isEmpty {
            let text = field("endpoint").contains("://") ? field("endpoint") : "https://" + field("endpoint")
            endpoint = try WebDAVDrive.validate(text)
        }
        let region = field("region").isEmpty ? (endpoint == nil ? "us-east-1" : "auto") : field("region")
        return S3Target(endpoint: endpoint, region: region, bucket: bucket,
                        prefix: field("prefix").trimmingCharacters(in: CharacterSet(charactersIn: "/")), accessKey: access, secretKey: secret)
    }

    func key(_ path: String) -> String {
        [prefix, path].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// Amazon wants the bucket in the host name; everyone else takes it as the first part of the path.
    func url(key: String, query: [(String, String)] = []) -> URL {
        var text: String
        if let endpoint {
            var base = endpoint.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            text = "\(base)/\(CloudPath.encodeSegment(bucket))"
        } else {
            text = "https://\(bucket).s3.\(region).amazonaws.com"
        }
        text += "/" + CloudPath.encode(key)
        if !query.isEmpty {
            text += "?" + query.map { "\(CloudPath.encodeSegment($0.0))=\(CloudPath.encodeSegment($0.1))" }.joined(separator: "&")
        }
        return URL(string: text)!
    }
}

/// AWS Signature Version 4 for S3: every request carries a signature over its method, path, query, three
/// headers and the hash of its body, made with the secret key. The secret itself never leaves the phone.
struct S3Signer: CloudAuthorizer {
    let accessKey: String
    let secretKey: String
    let region: String
    var now: @Sendable () -> Date = { Date() }

    func invalidate() async {}

    func signed(_ request: URLRequest) async throws -> URLRequest { sign(request) }

    func sign(_ request: URLRequest) -> URLRequest {
        var request = request
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let hostName = parts.host else { return request }
        let stamp = Self.stamp(now())
        let day = String(stamp.prefix(8))
        let payload = SHA256.hash(data: request.httpBody ?? Data()).map { String(format: "%02x", $0) }.joined()
        var host = hostName
        if let port = parts.port, !(parts.scheme == "https" && port == 443), !(parts.scheme == "http" && port == 80) { host += ":\(port)" }
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256")

        let query = (parts.percentEncodedQueryItems ?? []).map { ($0.name, $0.value ?? "") }.sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [request.httpMethod ?? "GET", path, query,
                         "host:\(host)\nx-amz-content-sha256:\(payload)\nx-amz-date:\(stamp)\n", signedHeaders, payload].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Data(canonical.utf8).sha256Hex].joined(separator: "\n")

        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        var key = hmac(Data("AWS4\(secretKey)".utf8), day)
        for part in [region, "s3", "aws4_request"] { key = hmac(key, part) }
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}

/// S3 and everything that speaks its API. Objects go by key; a file's id is its path, as with WebDAV.
actor S3Drive: CloudDrive {
    private let http: CloudHTTP
    private let target: S3Target

    init(http: CloudHTTP, target: S3Target) {
        self.http = http
        self.target = target
    }

    func folderCache() -> [String: String] { [:] }

    /// For a plain upload S3's ETag is the MD5 of the content.
    nonisolated func rev(of data: Data) -> String? { data.md5Hex }

    private static func clean(_ etag: String?) -> String {
        (etag ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    func put(_ data: Data, at path: String, known: RemoteRef?) async throws -> RemoteRef {
        var request = URLRequest(url: target.url(key: target.key(path)))
        request.httpMethod = "PUT"
        request.setValue(CloudPath.contentType(path), forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await http.send(request)
        return RemoteRef(id: path, rev: Self.clean(response.value(forHTTPHeaderField: "ETag")))
    }

    func list(_ directory: String) async throws -> [RemoteEntry] {
        let folder = target.key(directory)
        let prefix = folder.isEmpty ? "" : folder + "/"
        var entries: [RemoteEntry] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("delimiter", "/"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let (body, _) = try await http.send(URLRequest(url: target.url(key: "", query: query)))
            let xml = try CloudXML.parse(body, records: ["Contents", "CommonPrefixes"])
            for record in xml.records {
                if record["_kind"] == "CommonPrefixes" {
                    guard let name = record["Prefix"].map({ String($0.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }), !name.isEmpty else { continue }
                    entries.append(RemoteEntry(name: name, ref: RemoteRef(id: CloudPath.join(directory, name), rev: ""), size: 0, isFolder: true))
                } else if let key = record["Key"], key.hasPrefix(prefix) {
                    let name = String(key.dropFirst(prefix.count))
                    guard !name.isEmpty, !name.contains("/") else { continue }
                    entries.append(RemoteEntry(name: name, ref: RemoteRef(id: CloudPath.join(directory, name), rev: Self.clean(record["ETag"])),
                                               size: Int(record["Size"] ?? "") ?? 0, isFolder: false))
                }
            }
            token = xml.top["IsTruncated"] == "true" ? xml.top["NextContinuationToken"] : nil
        } while token != nil
        return entries
    }

    func get(_ ref: RemoteRef) async throws -> Data {
        try await http.send(URLRequest(url: target.url(key: target.key(ref.id)))).0
    }

    func delete(_ ref: RemoteRef) async throws {
        var request = URLRequest(url: target.url(key: target.key(ref.id)))
        request.httpMethod = "DELETE"
        _ = try await http.send(request, accept: [404])
    }
}
