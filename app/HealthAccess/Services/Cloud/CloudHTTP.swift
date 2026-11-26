import Foundation

/// One place for every request to a drive: the bearer token, one refresh on 401, and a few patient retries
/// when the drive says "slow down" or stumbles.
/// What makes a request the drive accepts: a bearer token, a name and password, or a signature.
protocol CloudAuthorizer: Sendable {
    func signed(_ request: URLRequest) async throws -> URLRequest
    /// The drive answered 401: whatever was cached is no good.
    func invalidate() async
}

struct CloudHTTP: Sendable {
    let session: URLSession
    let tokens: any CloudAuthorizer
    var maxAttempts = 4
    /// Longest wait between two attempts, in seconds. Tests set it to 0.
    var maxBackoff: Double = 20

    static let wifiOnlyKey = AppSettings.key("cloud.wifiOnly")

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// What a failed connection means for the user. "No connection" would hide a wrong address or a certificate iOS refuses.
    static func explain(_ error: URLError) -> Error {
        if error.code == .cancelled { return CancellationError() }
        if let reason = error.networkUnavailableReason, reason == .expensive || reason == .constrained { return CloudError.waitingForWiFi }
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return CloudError.unreachable("iOS does not trust the server's certificate. A self-made certificate does not work. Inside your own network, use http://. Elsewhere, the server needs a certificate from a known authority.")
        case .cannotFindHost, .dnsLookupFailed:
            return CloudError.unreachable("No server is known under that address.")
        case .cannotConnectToHost:
            return CloudError.unreachable("The server does not answer at that address and port.")
        case .appTransportSecurityRequiresSecureConnection:
            return CloudError.unreachable("iOS allows http:// only to a server in your own network. Use https://.")
        default:
            if error.failingURL?.host.map(WebDAVDrive.isLocal) == true {
                return CloudError.unreachable("The server in your network does not answer. If iOS asked for local network access and you said no, allow it in Settings → Health Access.")
            }
            return CloudError.offline
        }
    }

    /// Sends the request with a fresh token. Returns only for 2xx and for the statuses in `accept`.
    func send(_ request: URLRequest, accept: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        var attempt = 0
        while true {
            attempt += 1
            var request = try await tokens.signed(request)
            // Low Data Mode is the user's word that nothing big should go out; "Wi-Fi only" is the app's own switch.
            request.allowsConstrainedNetworkAccess = false
            request.allowsExpensiveNetworkAccess = !UserDefaults.standard.bool(forKey: Self.wifiOnlyKey)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if attempt < maxAttempts, [.timedOut, .networkConnectionLost].contains(error.code) {
                    try await pause(attempt, retryAfter: nil)
                    continue
                }
                throw Self.explain(error)
            }
            guard let http = response as? HTTPURLResponse else { throw CloudError.unexpected("no HTTP answer") }
            if (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) { return (data, http) }
            // 301/302/307 never arrive here: URLSession follows them.
            if http.statusCode == 401, !refreshed {
                refreshed = true
                await tokens.invalidate()
                continue
            }
            let text = Self.snippet(data)
            let slowDown = http.statusCode == 429 || (http.statusCode == 403 && text.localizedCaseInsensitiveContains("ratelimit"))
            if attempt < maxAttempts, slowDown || (500..<600).contains(http.statusCode) {
                try await pause(attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                continue
            }
            if http.statusCode == 401 { throw CloudError.signInExpired }
            // Still "slow down" after every wait: the next file would get the same answer.
            if slowDown { throw CloudError.slowDown }
            throw CloudError.http(http.statusCode, text)
        }
    }

    private func pause(_ attempt: Int, retryAfter: Double?) async throws {
        let seconds = min(maxBackoff, retryAfter ?? pow(2, Double(attempt - 1)))
        if seconds > 0 { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    }

    /// The start of an error body, on one line. Drives answer errors with a JSON message; never with user content.
    static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.unexpected("the drive's answer was not a JSON object")
        }
        return object
    }
}

/// A redirect to another host must not carry the sign-in along. A server that answers "go there instead" could
/// otherwise collect a password or a token meant for it alone.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    static func cleaned(_ redirect: URLRequest, from original: URL?) -> URLRequest {
        guard redirect.url?.host?.lowercased() != original?.host?.lowercased() || redirect.url?.scheme != original?.scheme else { return redirect }
        var request = redirect
        for header in ["Authorization", "x-amz-date", "x-amz-content-sha256", "Dropbox-API-Arg"] {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.cleaned(request, from: task.originalRequest?.url))
    }
}
