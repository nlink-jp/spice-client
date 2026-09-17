// SPDX-License-Identifier: MIT
// Format and compatibility fixtures informed by Maspice (MIT; see NOTICE.md).
import Foundation
import Darwin

public enum ConnectionError: Error, Equatable, Sendable {
    case tooLarge, invalidUTF8, malformed, missingGroup, unsupportedType
    case invalidHost, invalidPort, missingPort, duplicateKey, unsupportedOption
    case tlsRequired, invalidCertificate, invalidBoolean
}

/// Constructible only by validation; confirmation and connection use the same value.
public struct ConnectionPlan: Equatable, Sendable {
    public enum Security: Equatable, Sendable {
        case plain
        case systemTLS
        case certificateAuthority(pem: String, subject: String?)
    }
    public static let maximumBytes = 1 << 20
    public let host: String
    public let port: UInt16
    public let security: Security
    public let password: String?
    public let title: String?
    public let fullscreen: Bool
    public let deleteFileHint: Bool?
    public var usesTLS: Bool { security != .plain }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ConnectionError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw ConnectionError.invalidUTF8 }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var fields: [String: String] = [:]
        var active = false
        var found = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            // Reject, never silently strip characters that could change the destination.
            guard !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ConnectionError.malformed
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ConnectionError.malformed }
                active = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased() == "virt-viewer"
                if active {
                    guard !found else { throw ConnectionError.duplicateKey }
                    found = true
                }
                continue
            }
            guard active else { continue }
            guard let equal = line.firstIndex(of: "=") else { throw ConnectionError.malformed }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ConnectionError.malformed }
            guard fields[key] == nil else { throw ConnectionError.duplicateKey }
            fields[key] = value
        }
        guard found else { throw ConnectionError.missingGroup }
        guard fields["type"]?.lowercased() == "spice" else { throw ConnectionError.unsupportedType }
        guard let rawHost = fields["host"], let host = validatedHost(rawHost) else { throw ConnectionError.invalidHost }
        let plain = try parsePort(fields["port"])
        let tls = try parsePort(fields["tls-port"])

        let supported: Set<String> = ["type", "host", "port", "tls-port", "password", "title", "fullscreen",
            "ca", "host-subject", "secure-channels", "delete-this-file", "proxy", "unix-path", "username",
            "disable-channels", "tls-ciphers", "enable-smartcard", "enable-usbredir", "enable-usb-autoshare",
            "toggle-fullscreen", "release-cursor", "secure-attention", "zoom-in", "zoom-out", "zoom-reset",
            "color-depth", "disable-effects", "version", "versions", "newer-version-url"]
        guard Set(fields.keys).isSubset(of: supported) else { throw ConnectionError.unsupportedOption }
        for key in ["proxy", "unix-path", "username", "disable-channels", "tls-ciphers", "version", "versions"] {
            if let value = fields[key], !value.isEmpty { throw ConnectionError.unsupportedOption }
        }
        for key in ["enable-smartcard", "enable-usbredir", "enable-usb-autoshare"] {
            if try boolean(fields[key]) == true { throw ConnectionError.unsupportedOption }
        }
        if let requested = fields["secure-channels"], !requested.isEmpty {
            let channels = requested.split(separator: ";", omittingEmptySubsequences: false)
            let known: Set<String> = ["main", "display", "inputs", "cursor", "playback", "record", "smartcard", "usbredir"]
            // GLib string lists may have a trailing semicolon, but no empty interior entry.
            let entries = channels.last == "" ? channels.dropLast() : channels[...]
            guard !entries.isEmpty, entries.allSatisfy({ known.contains(String($0)) }) else {
                throw ConnectionError.unsupportedOption
            }
            guard tls != nil else { throw ConnectionError.tlsRequired }
        }
        let ca = fields["ca"]
        let subject = fields["host-subject"]
        if ca != nil || subject != nil {
            guard tls != nil else { throw ConnectionError.tlsRequired }
            guard let ca, !ca.isEmpty else { throw ConnectionError.invalidCertificate }
            if let subject, subject.isEmpty { throw ConnectionError.invalidCertificate }
            guard ca.contains("-----BEGIN CERTIFICATE-----"), ca.contains("-----END CERTIFICATE-----") else {
                throw ConnectionError.invalidCertificate
            }
        }
        guard let selected = tls ?? plain else { throw ConnectionError.missingPort }
        let security: Security = tls == nil ? .plain : ca.map {
            .certificateAuthority(pem: $0.replacingOccurrences(of: "\\n", with: "\n"), subject: subject)
        } ?? .systemTLS
        return Self(host: host, port: selected, security: security, password: fields["password"],
                    title: fields["title"].flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                    fullscreen: try boolean(fields["fullscreen"]) ?? false,
                    deleteFileHint: try boolean(fields["delete-this-file"]))
    }

    private static func parsePort(_ value: String?) throws -> UInt16? {
        guard let value else { return nil }
        if value == "-1" { return nil }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(value), port > 0 else { throw ConnectionError.invalidPort }
        return port
    }

    private static func boolean(_ value: String?) throws -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw ConnectionError.invalidBoolean
        }
    }

    private static func validatedHost(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@%")) == nil else { return nil }
        if value.contains(":") {
            let host = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
            var address = in6_addr()
            return inet_pton(AF_INET6, host, &address) == 1 ? host : nil
        }
        guard !value.contains("["), !value.contains("]") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = value
        guard let host = components.url?.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }
}
