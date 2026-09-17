import Foundation
import Security

enum PortalTrust {
    /// A temporary exception may add only this self-issued certificate as an
    /// anchor. It never relaxes hostname, signature, usage, or validity checks.
    static func temporaryAnchor(_ trust: SecTrust, host: String, now: Date = Date()) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              chain.count == 1, let certificate = chain.first,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate),
              let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
              issuer == subject,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetVerifyDate(trust, now as CFDate) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { return nil }
        return certificate
    }
}
