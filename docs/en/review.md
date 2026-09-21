# Review and remediation

2026-09-17. The review of 76 reference project files found no evidence of an intentional backdoor or hidden third-party transmission. It did identify authorization, TLS, cookie, and shutdown defects below.

The reference checkout remains unchanged; remediation is in the new application. The [detailed baseline audit](baseline-review.md) describes the earlier version.

| ID | Reference problem | Remediation / evidence |
|---|---|---|
| R1 | Web navigation metadata mistaken for human approval | Immutable candidate consumed once by native confirmation; actual WebKit automatic navigation and POST tested |
| R2 | Old updater dependency and inherited distribution authority | Removed Sparkle, update keys and feeds from the new application |
| R3 | Incomplete origin matching | Match HTTPS scheme, host, effective port, and main frame |
| R4 | Cookies reused across redirect paths | Reselect in an ephemeral session for every redirect; actual HTTPS receiver reported zero scoped-cookie leaks |
| R5 | Malformed tls-port silently becomes plaintext | Reject malformed and out-of-range ports; prefer valid TLS and stop on failure |
| R6 | Ignored secure-channels requirements | Accept known channels only and require a TLS endpoint |
| R7 | Waiting for input gates transport closure | Stop input synchronously, close transport first, then join; regression covers a blocked send |
| R8 | Source file moved before connection succeeds | Move once after success; verify inode/content, restore races safely, join maintenance on exit |
| R9 | Metal compiler shim mistaken for installed toolchain | Doctor compiles a shader; load both metallib resources from the assembled app |
| R10 | Inaccurate dependency versions and notices | Pin SwiftSpice 0.4.2 and 28 native entries; verify 418 files, patch and symbolic links |
| R11 | Source-string tests enshrine incorrect behavior | Assert parser results, approval, actual network flow and injected clipboard access boundaries |
| R12 | Incomplete release gates | Require tests, Developer ID and notarization; unpack final ZIP and reject malformed archives |

Independent review also identified and led to fixes for clipboard permission not returning after MJPEG retry, the portal refusing a second candidate after confirmation, and release verification trusting the neighboring app instead of the ZIP. Actual WebKit tests verify that the Swift async authentication callback uses `webView(_:respondTo:)`. HTTPS tests include gzip responses and truncated bodies.

Built-app inspection found that another client's preferred UTI could prevent selecting `.vv` files. Selection now uses the filename extension; the read boundary separately validates the regular file, size, and contents.

The SwiftSpice patch is restricted to clipboard authorization and permission generations. Native binaries are unchanged. This is not proof that every dependency binary is defect-free or that real guests interoperate correctly. See [verification](verification.md) and the [source ledger](source-map.md).
