import Foundation
import Security
import WebKit
import Testing
import ConnectionCore
import SwiftSpiceAdapter
@testable import SpiceClient

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SPICE_CLIENT_SIMULATION_URL"] != nil))
@MainActor
struct LoopbackSimulationTests {
    let base = URL(string: ProcessInfo.processInfo.environment["SPICE_CLIENT_SIMULATION_URL"] ?? "https://localhost")!
    func anchor() throws -> SecCertificate {
        let path = try #require(ProcessInfo.processInfo.environment["SPICE_CLIENT_SIMULATION_CA"])
        return try #require(SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: path)) as CFData))
    }
    func trusted(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust, let certificate = try? anchor() else { return (.cancelAuthenticationChallenge, nil) }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        let valid = SecTrustEvaluateWithError(trust, &error)
        if !valid { print("Synthetic TLS validation:", String(describing: error)) }
        return valid ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
    func eventually(_ predicate: @MainActor () -> Bool, seconds: Double = 10) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predicate())
    }
    @Test func temporaryTrustDoesNotOverrideNameOrExpiry() throws {
        let certificate = try anchor()
        for (host, date, expected) in [("localhost", Date(), true), ("other.invalid", Date(), false),
                                        ("localhost", Date().addingTimeInterval(3 * 86400), false)] {
            var trust: SecTrust?
            #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess)
            let value = try #require(trust)
            _ = SecTrustEvaluateWithError(value, nil)
            #expect((PortalTrust.temporaryAnchor(value, host: host, now: date) != nil) == expected)
        }
    }
    @Test func actualHTTPSRedirectReselectsCookiesAndRejectsBadResponses() async throws {
        let origin = try #require(PortalOrigin(base))
        let cookie = try #require(HTTPCookie(properties: [.name: "scoped", .value: "synthetic", .domain: "localhost", .path: "/private", .secure: "TRUE"]))
        let plan = try await PortalTransfer.fetch(URLRequest(url: base.appendingPathComponent("private/start.vv")), origin: origin, cookies: [cookie], trust: { challenge in await trusted(challenge) })
        #expect(plan.host == "127.0.0.1")
        let compressed = try await PortalTransfer.fetch(URLRequest(url: base.appendingPathComponent("gzip.vv")), origin: origin, cookies: [], trust: { challenge in await trusted(challenge) })
        #expect(compressed == plan)
        for path in ["cross-origin.vv", "oversized.vv", "invalid-utf8.vv", "truncated.vv"] {
            do {
                _ = try await PortalTransfer.fetch(URLRequest(url: base.appendingPathComponent(path)), origin: origin, cookies: [], trust: { challenge in await trusted(challenge) })
                Issue.record("Rejected response unexpectedly accepted: \(path)")
            } catch { /* expected rejection */ }
        }
    }
    @Test func realWebKitAutomaticNavigationAndFormNeedNativeApproval() async throws {
        let certificate = try anchor()
        for path in ["auto.html", "form.html"] {
            let model = ApplicationModel(defaults: UserDefaults(suiteName: "spice-client-simulation-" + UUID().uuidString)!)
            let portal = try PortalController(url: base.appendingPathComponent(path), offer: { model.offer($0, source: $1) }, report: { model.message = $0 }, dataStore: .nonPersistent(), evaluateTrust: { trust in
                SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                var error: CFError?
                let valid = SecTrustEvaluateWithError(trust, &error)
                if !valid { print("Synthetic WebKit TLS validation:", String(describing: error)) }
                return valid
            })
            defer { portal.close(); model.stop() }
            try await eventually { model.pending != nil || model.message != nil }
            #expect(model.message == nil)
            let candidate = try #require(model.pending)
            #expect(model.sessions.isEmpty)
            model.cancel(candidate.id)
            model.confirm(candidate.id, clipboard: true)
            #expect(model.sessions.isEmpty)
        }
    }
    @Test func realSPICEBootstrapInputFailuresAndCancellation() async throws {
        let json = try #require(ProcessInfo.processInfo.environment["SPICE_CLIENT_SIMULATION_PORTS"])
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(json.utf8))
        for mode in ["normal", "authentication", "malformed", "stalled"] {
            let port = try #require(ports[mode])
            let plan = try ConnectionPlan.parse(Data("[virt-viewer]\ntype=spice\nhost=127.0.0.1\nport=\(port)\npassword=synthetic".utf8))
            let controller = SessionController(plan: plan)
            controller.start()
            defer { controller.disconnect() }
            if mode == "normal" {
                try await eventually { controller.lifecycle.phase == .connected || controller.failure != nil }
                #expect(controller.failure == nil)
                #expect(controller.inputAvailable)
                controller.secureAttention()
                controller.setDiagnostics(true)
                try await eventually { !controller.summary.isEmpty }
                #expect(!controller.summary.contains("synthetic"))
                #expect(!controller.summary.contains("127.0.0.1"))
            } else if mode != "stalled" {
                try await eventually { controller.lifecycle.phase == .closed }
                #expect(controller.failure != nil)
                if mode == "authentication" { #expect(controller.failure == .authentication) }
            } else {
                try await Task.sleep(for: .milliseconds(120))
            }
            controller.disconnect()
            try await eventually({ controller.lifecycle.phase == .closed }, seconds: 3)
            #expect(!controller.inputAvailable)
        }
    }
}
