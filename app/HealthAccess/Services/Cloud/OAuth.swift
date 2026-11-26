import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// The sign-in of one drive: OAuth 2 with PKCE for an app without a secret. The user signs in on the drive's
/// own page in the system sign-in sheet; the app only ever sees the code that comes back.
struct OAuthConfig: Sendable, Equatable {
    let kind: CloudKind
    let clientID: String
    let authorizeURL: URL
    let tokenURL: URL
    let scope: String
    let redirectURI: String
    let extra: [String: String]
    /// Sent with every token request when the drive insists on one (Box).
    var secret: String?
    /// PKCE protects a sign-in without a secret. Box does not know it.
    var pkce = true
    /// pCloud hands the token over in the redirect itself and it never runs out: no code, no refresh.
    var tokenInRedirect = false

    var callbackScheme: String { String(redirectURI.prefix { $0 != ":" }) }

    static func make(_ kind: CloudKind, clientID: String, secret: String? = nil,
                     bundleID: String = Bundle.main.bundleIdentifier ?? "com.healthaccessmcp.app") -> OAuthConfig {
        switch kind {
        case .google:
            // An iOS client's redirect is its own id backwards: "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc".
            let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
            return OAuthConfig(kind: kind, clientID: clientID,
                               authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                               tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                               // Only the files this app creates. Google asks for no security audit for it.
                               scope: "https://www.googleapis.com/auth/drive.file",
                               redirectURI: "\(reversed):/oauth2redirect", extra: [:])
        case .onedrive:
            return OAuthConfig(kind: kind, clientID: clientID,
                               authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                               tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                               // Only the app's own folder (Apps › Health Access), with everything in it.
                               scope: "Files.ReadWrite.AppFolder offline_access",
                               redirectURI: "msauth.\(bundleID)://auth", extra: [:])
        case .dropbox:
            return OAuthConfig(kind: kind, clientID: clientID,
                               authorizeURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                               tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                               // The Dropbox app is of the "App folder" kind, so these reach Apps › Health Access only.
                               scope: "files.content.write files.content.read files.metadata.read",
                               redirectURI: "db-\(clientID)://2/token", extra: ["token_access_type": "offline"])
        case .box:
            return OAuthConfig(kind: kind, clientID: clientID,
                               authorizeURL: URL(string: "https://account.box.com/api/oauth2/authorize")!,
                               tokenURL: URL(string: "https://api.box.com/oauth2/token")!,
                               // Box takes the permissions from the app's own settings ("Read and write all files").
                               scope: "",
                               redirectURI: "boxsdk-\(clientID)://boxsdkoauth2redirect", extra: [:],
                               secret: secret, pkce: false)
        case .pcloud:
            return OAuthConfig(kind: kind, clientID: clientID,
                               authorizeURL: URL(string: "https://my.pcloud.com/oauth2/authorize")!,
                               tokenURL: URL(string: "https://api.pcloud.com/oauth2_token")!,
                               scope: "",
                               redirectURI: "\(bundleID)://oauth/pcloud", extra: [:],
                               pkce: false, tokenInRedirect: true)
        case .webdav, .s3:
            preconditionFailure("\(kind.rawValue) has no sign-in page")
        }
    }

    func authorizeRequest(challenge: String, state: String) -> URL {
        var parts = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: tokenInRedirect ? "token" : "code"),
            URLQueryItem(name: "state", value: state),
        ]
        if !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        if pkce {
            items.append(URLQueryItem(name: "code_challenge", value: challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        for key in extra.keys.sorted() { items.append(URLQueryItem(name: key, value: extra[key])) }
        parts.queryItems = items
        return parts.url!
    }

    func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = fields
        fields["client_id"] = clientID
        if let secret { fields["client_secret"] = secret }
        request.httpBody = Data(OAuthForm.encode(fields).utf8)
        return request
    }
}

enum OAuthForm {
    static func encode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct TokenResponse: Sendable, Equatable {
    let accessToken: String
    let expiresIn: Double
    let refreshToken: String?

    static func parse(_ data: Data) throws -> TokenResponse {
        let object = try CloudHTTP.json(data)
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw CloudError.unexpected("the sign-in answer carried no token")
        }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return TokenResponse(accessToken: access, expiresIn: expires, refreshToken: object["refresh_token"] as? String)
    }
}

/// The long-lived token of one drive, in the iPhone's keychain. Readable after the first unlock, so a sync that
/// iOS starts while the phone is in a pocket can still upload. Never in a file, never in the folder.
enum CloudKeychain {
    private static let service = "com.healthaccessmcp.app.cloud"

    private static func query(_ kind: CloudKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: kind.rawValue]
    }

    static func save(_ token: String, for kind: CloudKind) {
        SecItemDelete(query(kind) as CFDictionary)
        var item = query(kind)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(_ kind: CloudKind) -> String? {
        var item = query(kind)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ kind: CloudKind) { SecItemDelete(query(kind) as CFDictionary) }
}

/// Hands out a valid access token, refreshing it with the stored long-lived one when it is about to run out.
actor TokenSource: CloudAuthorizer {
    private let config: OAuthConfig?
    private let session: URLSession
    private let fixed: String?
    private var access: (token: String, until: Date)?
    private var refreshing: Task<String, Error>?

    init(config: OAuthConfig, session: URLSession) {
        self.config = config
        self.session = session
        self.fixed = nil
    }

    /// For tests: always this token.
    init(fixed: String) {
        self.config = nil
        self.session = .shared
        self.fixed = fixed
    }

    func signed(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return request
    }

    func token() async throws -> String {
        if let fixed { return fixed }
        if let access, access.until > Date().addingTimeInterval(60) { return access.token }
        if let refreshing { return try await refreshing.value }
        guard let config else { throw CloudError.notConfigured }
        guard let refresh = CloudKeychain.load(config.kind) else { throw CloudError.notConnected }
        let session = self.session
        let task = Task { () throws -> String in
            let request = config.tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) } catch { throw CloudError.offline }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 400 with invalid_grant: the drive no longer honours the stored token (revoked, password changed, unused too long).
            if status == 400 || status == 401 { throw CloudError.signInExpired }
            guard (200..<300).contains(status) else { throw CloudError.http(status, CloudHTTP.snippet(data)) }
            let parsed = try TokenResponse.parse(data)
            if let rotated = parsed.refreshToken, rotated != refresh { CloudKeychain.save(rotated, for: config.kind) }
            self.store(parsed)
            return parsed.accessToken
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func store(_ response: TokenResponse) {
        access = (response.accessToken, Date().addingTimeInterval(response.expiresIn))
    }

    /// After a fresh sign-in.
    func adopt(_ response: TokenResponse) { store(response) }

    func invalidate() { access = nil }
}

/// The system sign-in sheet. It shows the drive's own page; cookies are shared with Safari, so someone already
/// signed in there only confirms.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CloudError.cancelled)
                } else {
                    continuation.resume(throwing: CloudError.unexpected(error?.localizedDescription ?? "The sign-in did not finish."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: CloudError.unexpected("The sign-in sheet could not open."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map(UIWindow.init(windowScene:)) ?? ASPresentationAnchor()
        }
    }
}

enum OAuthFlow {
    /// The whole sign-in: sheet, code, tokens. Stores the long-lived token in the keychain and returns the first access token.
    @MainActor
    static func signIn(_ config: OAuthConfig, session: URLSession) async throws -> TokenResponse {
        let verifier = PKCE.verifier()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let web = WebSignIn()
        let callback = try await web.run(url: config.authorizeRequest(challenge: PKCE.challenge(for: verifier), state: state),
                                         scheme: config.callbackScheme)
        if config.tokenInRedirect {
            let found = try Self.token(from: callback, state: state)
            // The token and the region's API host are all there is to keep.
            CloudKeychain.save(try CloudSecrets.encode(["token": found.token, "host": found.host]), for: config.kind)
            return TokenResponse(accessToken: found.token, expiresIn: .infinity, refreshToken: nil)
        }
        let code = try Self.code(from: callback, state: state)
        var fields = ["grant_type": "authorization_code", "code": code, "redirect_uri": config.redirectURI]
        if config.pkce { fields["code_verifier"] = verifier }
        let request = config.tokenRequest(fields)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw CloudError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CloudError.http(status, CloudHTTP.snippet(data)) }
        let tokens = try TokenResponse.parse(data)
        guard let refresh = tokens.refreshToken else {
            throw CloudError.unexpected("\(config.kind.name) gave no long-lived sign-in. Connect again.")
        }
        CloudKeychain.save(refresh, for: config.kind)
        return tokens
    }

    /// pCloud's answer: the token after the `#`, with the API host of the region the account lives in.
    static func token(from callback: URL, state: String) throws -> (token: String, host: String) {
        var parts = URLComponents()
        parts.percentEncodedQuery = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedFragment
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if value("error") != nil { throw CloudError.cancelled }
        if let returned = value("state"), returned != state { throw CloudError.unexpected("The sign-in answer did not match the request.") }
        guard let token = value("access_token"), !token.isEmpty else { throw CloudError.unexpected("The sign-in answer carried no token.") }
        let host = value("hostname") ?? (value("locationid") == "2" ? "eapi.pcloud.com" : "api.pcloud.com")
        guard host.hasSuffix("pcloud.com") else { throw CloudError.unexpected("The sign-in answer named an unknown host.") }
        return (token, host)
    }

    /// The code from the redirect, after checking that the answer belongs to this request.
    static func code(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw CloudError.cancelled }
            throw CloudError.unexpected(value("error_description") ?? error)
        }
        guard value("state") == state else { throw CloudError.unexpected("The sign-in answer did not match the request.") }
        guard let code = value("code"), !code.isEmpty else { throw CloudError.unexpected("The sign-in answer carried no code.") }
        return code
    }
}

/// What is kept for a drive besides an OAuth token: a server's address and password, a storage's keys.
/// One JSON object per drive, in the keychain with the rest.
enum CloudSecrets {
    static func encode(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    static func load(_ kind: CloudKind) -> [String: String]? {
        guard let text = CloudKeychain.load(kind), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return object as? [String: String]
    }
}

/// A token that does not run out (pCloud).
struct StaticBearer: CloudAuthorizer {
    let token: String

    func signed(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func invalidate() async {}
}

/// A name and a password with every request (WebDAV). Only ever sent to the server the user typed in.
struct BasicAuth: CloudAuthorizer {
    let user: String
    let password: String

    func signed(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }

    func invalidate() async {}
}
