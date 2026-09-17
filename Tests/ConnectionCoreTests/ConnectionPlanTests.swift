import Foundation
import Testing
@testable import ConnectionCore

private func parse(_ fields: String) throws -> ConnectionPlan {
    try .parse(Data(("[virt-viewer]\ntype=spice\nhost=guest.example\n" + fields).utf8))
}

@Test func acceptsTCPAndPrefersTLSWithoutFallback() throws {
    #expect(try parse("port=5900").security == .plain)
    let plan = try parse("port=5900\ntls-port=5901")
    #expect(plan.port == 5901)
    #expect(plan.security == .systemTLS)
    #expect(try parse("port=-1\ntls-port=5901").usesTLS)
}
@Test(arguments: ["oops", "", "0", "65536", "-2", "+5901", "5.901", "５９０１"])
func malformedTLSPortCannotBecomePlaintext(_ value: String) {
    #expect(throws: ConnectionError.invalidPort) { try parse("port=5900\ntls-port=" + value) }
}
@Test func secureChannelsAreRequirements() throws {
    #expect(throws: ConnectionError.tlsRequired) { try parse("port=5900\nsecure-channels=main;display;inputs") }
    #expect(try parse("tls-port=5901\nsecure-channels=main;display;inputs;").usesTLS)
    #expect(throws: ConnectionError.unsupportedOption) { try parse("tls-port=5901\nsecure-channels=made-up") }
}
@Test(arguments: ["tls-ciphers=HIGH", "disable-channels=inputs", "proxy=http://proxy.invalid", "unix-path=/socket", "tls-porrt=5901", "enable-usbredir=1"])
func unsupportedRequirementsNeverDisappear(_ field: String) {
    #expect(throws: ConnectionError.unsupportedOption) { try parse("port=5900\n" + field) }
}
@Test func rejectsAmbiguousAndNulContainingValues() {
    #expect(throws: ConnectionError.duplicateKey) { try parse("port=5900\nTLS-PORT=5901\ntls-port=5902") }
    #expect(throws: ConnectionError.malformed) { try parse("port=5900\npassword=abc\0def") }
    #expect(throws: ConnectionError.tlsRequired) { try parse("port=5900\nca=bad") }
    #expect(throws: ConnectionError.invalidBoolean) { try parse("port=5900\nfullscreen=maybe") }
}
@Test func preservesRealFileSyntaxAndSecretsInMemoryOnly() throws {
    let data = Data("\u{FEFF}[virt-viewer]\r\ntype=spice\r\nhost=::1\r\nport=5900\r\npassword=a=b;c\r\nfullscreen=yes\r\n;comment\r\n".utf8)
    let plan = try ConnectionPlan.parse(data)
    #expect(plan.host == "::1")
    #expect(plan.password == "a=b;c")
    #expect(plan.fullscreen)
}
@Test func boundedBytesAndRequiredGroup() {
    #expect(throws: ConnectionError.tooLarge) { try ConnectionPlan.parse(Data(repeating: 65, count: ConnectionPlan.maximumBytes + 1)) }
    #expect(throws: ConnectionError.invalidUTF8) { try ConnectionPlan.parse(Data([255])) }
    #expect(throws: ConnectionError.missingGroup) { try ConnectionPlan.parse(Data("hello".utf8)) }
}

@Test func originIncludesSchemeAndEffectivePort() throws {
    let origin = try #require(PortalOrigin(URL(string: "https://portal.example")!))
    #expect(origin.contains(URL(string: "https://PORTAL.example:443/console.vv")))
    #expect(!origin.contains(URL(string: "https://portal.example:8443/console.vv")))
    #expect(!origin.contains(URL(string: "http://portal.example/console.vv")))
    #expect(!origin.contains(URL(string: "https://user@portal.example/console.vv")))
    #expect(!PortalPolicy.permitsHandoff(source: origin, isMainFrame: false, destination: URL(string: "https://portal.example/a.vv"), expected: origin))
}
@Test func redirectReplacesCookieHeaderAccordingToPath() throws {
    let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "portal.example", .path: "/private", .secure: "TRUE"]))
    var request = URLRequest(url: URL(string: "https://portal.example/private/a.vv")!)
    request = PortalPolicy.request(request, cookies: [cookie], now: Date())
    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic") == true)
    request.url = URL(string: "https://portal.example/public/b.vv")!
    request = PortalPolicy.request(request, cookies: [cookie], now: Date())
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(!PortalPolicy.cookie(cookie, appliesTo: URL(string: "https://portal.example/private%2Ffake")!, now: Date()))
}
