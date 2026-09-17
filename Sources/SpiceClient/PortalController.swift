// SPDX-License-Identifier: MIT
import AppKit
import WebKit
import SwiftUI
import Security
import CryptoKit
import ConnectionCore

@MainActor
final class PortalController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let origin: PortalOrigin
    private let offer: @MainActor (ConnectionPlan, String) -> Void
    private let report: @MainActor (String) -> Void
    private var download: Task<Void, Never>?
    private var closed = false
    private var certificateFingerprint: String?
    private var delivered = false
    private let clock: PortalCookieClock
    private let evaluateTrust: @MainActor (SecTrust) -> Bool

    init(url: URL, offer: @escaping @MainActor (ConnectionPlan, String) -> Void,
         report: @escaping @MainActor (String) -> Void,
         dataStore: WKWebsiteDataStore = .default(),
         evaluateTrust: @escaping @MainActor (SecTrust) -> Bool = { SecTrustEvaluateWithError($0, nil) }) throws {
        guard let origin = PortalOrigin(url) else { throw PortalError.invalidOrigin }
        self.origin = origin; self.offer = offer; self.report = report
        self.evaluateTrust = evaluateTrust
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        clock = PortalCookieClock(store: config.websiteDataStore.httpCookieStore, portalURL: url)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        clock.start()
        webView.load(URLRequest(url: url))
    }
    func close() {
        closed = true; certificateFingerprint = nil
        download?.cancel(); download = nil; clock.stop()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
    }
    func allowNextCandidate() { delivered = false }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !closed else { return .cancel }
        guard action.request.url?.pathExtension.lowercased() == "vv" else {
            guard let scheme = action.request.url?.scheme?.lowercased(), ["https", "about"].contains(scheme) else { return .cancel }
            return .allow
        }
        let source = action.sourceFrame.securityOrigin
        let sourceOrigin = PortalOrigin(scheme: source.protocol, host: source.host, port: source.port)
        guard PortalPolicy.permitsHandoff(source: sourceOrigin, isMainFrame: action.sourceFrame.isMainFrame,
                                         destination: action.request.url, expected: origin) else {
            report(L.text("portalRejected")); return .cancel
        }
        guard download == nil, !delivered else { return .cancel }
        let request = action.request
        download = Task { [weak self] in
            guard let self else { return }
            defer { self.download = nil }
            do {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                let plan = try await PortalTransfer.fetch(request, origin: origin, cookies: cookies) { [weak self] challenge in
                    await self?.authenticate(challenge) ?? (.cancelAuthenticationChallenge, nil)
                }
                guard !closed, !Task.isCancelled else { return }
                delivered = true
                offer(plan, origin.host)
            } catch {
                if !closed && !Task.isCancelled { report(L.text("downloadFailed")) }
            }
        }
        return .cancel
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        clock.observe(response.response)
        if response.response.url?.pathExtension.lowercased() == "vv" ||
            (response.response.suggestedFilename as NSString?)?.pathExtension.lowercased() == "vv" {
            report(L.text("unsupportedDownload")); return .cancel
        }
        return closed ? .cancel : .allow
    }
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await authenticate(challenge)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled && !closed { report(L.text("portalFailed")) }
    }
    private func authenticate(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard !closed else { return (.cancelAuthenticationChallenge, nil) }
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        if evaluateTrust(trust) { return (.useCredential, URLCredential(trust: trust)) }
        guard PortalOrigin(scheme: space.protocol ?? "", host: space.host, port: space.port) == origin,
              let certificate = PortalTrust.temporaryAnchor(trust, host: origin.host) else { return (.cancelAuthenticationChallenge, nil) }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        if certificateFingerprint != fingerprint {
            let alert = NSAlert()
            alert.messageText = L.text("certificatePrompt")
            alert.informativeText = "\(origin.host):\(origin.port)\nSHA-256\n\(fingerprint)\n\n" + L.text("certificateTemporary")
            alert.addButton(withTitle: L.text("cancel")); alert.addButton(withTitle: L.text("trustOnce"))
            guard alert.runModal() == .alertSecondButtonReturn, !closed else { return (.cancelAuthenticationChallenge, nil) }
            certificateFingerprint = fingerprint
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

struct PortalWebView: NSViewRepresentable {
    let controller: PortalController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
