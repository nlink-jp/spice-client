// SPDX-License-Identifier: MIT
import Foundation

public struct PortalOrigin: Hashable, Sendable {
    public let host: String
    public let port: Int
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host()?.lowercased(), !host.isEmpty,
              (1...65535).contains(url.port ?? 443) else { return nil }
        self.host = host
        port = url.port ?? 443
    }
    public init?(scheme: String, host: String, port: Int) {
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.port = port == 0 ? nil : port
        guard let url = c.url else { return nil }
        self.init(url)
    }
    public func contains(_ url: URL?) -> Bool { url.flatMap(Self.init) == self }
}

public enum PortalPolicy {
    public static func permitsHandoff(source: PortalOrigin?, isMainFrame: Bool,
                                       destination: URL?, expected: PortalOrigin) -> Bool {
        isMainFrame && source == expected && expected.contains(destination)
    }

    public static func cookie(_ cookie: HTTPCookie, appliesTo url: URL, now: Date) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let name = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard !name.isEmpty, host == name || (domain.hasPrefix(".") && host.hasSuffix("." + name)) else { return false }
        // Compare the encoded HTTP request path, not a decoded slash in a segment.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let requestPath = path.isEmpty ? "/" : path
        let scope = cookie.path.isEmpty ? "/" : cookie.path
        let matches = requestPath == scope || (requestPath.hasPrefix(scope) &&
            (scope.hasSuffix("/") || requestPath.dropFirst(scope.count).first == "/"))
        return matches && (!cookie.isSecure || url.scheme?.lowercased() == "https") &&
            (cookie.expiresDate.map { $0 > now } ?? true)
    }

    public static func request(_ original: URLRequest, cookies: [HTTPCookie], now: Date) -> URLRequest {
        var request = original
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        guard let url = request.url else { return request }
        let matching = cookies.filter { cookie($0, appliesTo: url, now: now) }
            .sorted { $0.path.count > $1.path.count }
        for (key, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
