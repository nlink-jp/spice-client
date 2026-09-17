// SPDX-License-Identifier: MIT
import Foundation
import Security
import Synchronization
import ConnectionCore

enum PortalError: Error { case invalidOrigin, invalidResponse, tooLarge, cancelled }

/// Immutable configuration plus a mutex-protected cookie jar because URLSession
/// may call delegate methods on different executors. No global cookie storage.
final class PortalTransferDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State { var cookies: [HTTPCookie]; var redirects = 0 }
    private let state: Mutex<State>
    let origin: PortalOrigin
    let trust: @Sendable (URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    init(origin: PortalOrigin, cookies: [HTTPCookie],
         trust: @escaping @Sendable (URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)) {
        self.origin = origin; state = Mutex(State(cookies: cookies)); self.trust = trust
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard origin.contains(response.url), origin.contains(request.url) else { return nil }
        return state.withLock { state in
            state.redirects += 1
            guard state.redirects <= 8 else { return nil }
            if let url = response.url {
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                    // Do not accept a Set-Cookie for an unrelated domain.
                    let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    guard let host = url.host()?.lowercased(), host == domain.lowercased() || host.hasSuffix("." + domain.lowercased()) else { continue }
                    state.cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                    state.cookies.append(cookie)
                }
            }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            return PortalPolicy.request(next, cookies: state.cookies, now: Date())
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust(challenge)
    }
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust(challenge)
    }
}

enum PortalTransfer {
    static func fetch(_ original: URLRequest, origin: PortalOrigin, cookies: [HTTPCookie],
                      trust: @escaping @Sendable (URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)) async throws -> ConnectionPlan {
        guard origin.contains(original.url), original.httpBodyStream == nil else { throw PortalError.invalidOrigin }
        let delegate = PortalTransferDelegate(origin: origin, cookies: cookies, trust: trust)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = PortalPolicy.request(original, cookies: cookies, now: Date())
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // WebKit-originated headers are not a general native request capability.
        for field in ["Authorization", "Proxy-Authorization", "Host"] { request.setValue(nil, forHTTPHeaderField: field) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, origin.contains(response.url),
              (200..<300).contains(response.statusCode), response.expectedContentLength <= ConnectionPlan.maximumBytes else {
            throw PortalError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ConnectionPlan.maximumBytes else { throw PortalError.tooLarge }
            data.append(byte)
        }
        if response.expectedContentLength >= 0 && response.expectedContentLength != data.count {
            throw PortalError.invalidResponse
        }
        return try ConnectionPlan.parse(data)
    }
}
