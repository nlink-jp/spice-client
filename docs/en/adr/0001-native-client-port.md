# ADR-0001: Reimplement spice-client as a native application

| Field | Value |
|-------|-------|
| Status | **Accepted** — user approved implementation on 2026-09-17 |
| Date | 2026-09-17 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | Request for a new port and bug fixes following the spice-mac review |

Implementation note (2026-09-17): the user requested simulation because no real peer is available. Local app, loopback protocol/WebKit tests, and review are delivered separately from real-guest and signed-release validation. See [verification](../verification.md).

## Context

Build an Apple Silicon macOS SPICE client for standard QEMU and Ravada guests,
using spice-mac (Maspice) as the reference while redesigning input validation,
the web-to-native boundary, and session ownership. The user has chosen the name
`spice-client` and continued use of SwiftSpice. The complete design below was approved by the user on 2026-09-17.

The reference baseline is spice-mac commit
`4631b0cf43032671fe01e994db5613e78a91037a`. The review found no clear malicious
application code, but reproduced unsolicited connection initiation, ignored TLS
requirements, and stalled disconnection. After Metal Toolchain installation,
the reference project's `make test` and `make build` passed. Those results do
not validate the new implementation, real-peer interoperability, or binary safety.

## Decision

### 1. Product and placement

- Repository `spice-client`, application **Spice Client**, executable
  `SpiceClient`, bundle ID `jp.nlink.spice-client`.
- Develop under the organization's `_wip/spice-client/`. Use `util-series`,
  alongside its existing native GUI applications. Preserve spice-mac as a reference.
- Swift 6.3 with Swift 6 strict concurrency; SwiftUI with narrow AppKit, WebKit,
  and Metal integration. Initial platform: macOS 26 or later, arm64.
  Pin SwiftSpice 0.4.2 commit `3f8de33a3c91fd7ed42d42b5970e644a8abf94b6` as the
  tested baseline and apply only the clipboard-boundary changes below to a
  traceable local dependency. Review baseline, patch, and native artifact diffs
  before updating.
- Reimplement the application. SwiftSpice continues to own the protocol,
  transport TLS, codecs, and Metal rendering; rewriting those is outside this plan.

### 2. User interface and behavior

Accept `.vv` files through a picker, drop, Finder, or an HTTPS Ravada portal.
Every entry path parses the input and presents a native connection confirmation
showing source, destination host and port, encryption, certificate validation,
and clipboard sharing. Only an explicit Connect action starts the connection.
Never display tickets or passwords. Keep explicitly confirmed plain TCP for
compatibility, clearly labeled as unencrypted; never downgrade after a TLS error.

Support multiple session windows, each presenting one display stream. Port
keyboard and mouse input, cursor presentation, audio playback, guest resizing,
fullscreen, and diagnostic viewing/copying. Permit one MJPEG reconnect to the
same approved endpoint if H.264 is unavailable before its first presentation,
after stopping the old connection. Do not indefinitely retry connection or
authentication failures.

Clipboard sharing defaults OFF in the new application and can be explicitly
enabled at confirmation or during a session. Only the focused session may access
the host clipboard while enabled. Losing focus, disabling sharing, or beginning
disconnection revokes read/write access. Never relay contents between sessions.
Separate the agent needed for resizing from permission to access the clipboard.

**A dependency API change is already known to be necessary.** SwiftSpice 0.4.2
hardcodes `.general` in `SpicePasteboardBridge`; `SpiceAgentManager` immediately
offers its contents when reenabled. This can relay A's guest clipboard to B,
and previously queued MainActor writes can execute after revocation. Application
flags alone do not fix it. Make a minimal dependency change to inject clipboard
read/write access, without rewriting protocol or rendering. At actual access,
check session ID, permission generation, and focus on MainActor; distinguish
denial from copying empty text. An application-wide broker records each guest
write's pasteboard changeCount and source session to prevent automatic forwarding
to another session. A new copy made by the user in another application is a new
change. Discard pending clipboard actions on a revoked generation; data already
sent on the network before revocation cannot be recalled.

Keep this as a local SwiftPM package under `Vendor/SwiftSpice`, recording baseline
URL/tag/commit, changed files, a reapplicable patch, and native artifact hashes.
Do not describe it as identical to unmodified upstream 0.4.2. Run new dependency
tests and the existing suite. An upstream proposal may be drafted; publication
or submission is separate. Acceptance includes A→host write→focus B and
revocation while a MainActor read/write is pending. If implementation cannot
satisfy the contract, leave clipboard disabled and report the unmet requirement.

Persist the portal URL and nonsensitive UI preferences in the new application's
own domain. Do not automatically migrate the old application's preferences,
certificate exceptions, or update settings. Use the application's own WebKit
data store for portal login state, with an explicit Clear Portal Login Data
action. Never persist SPICE tickets or connection-file contents in preferences,
history, or logs. Provide Japanese and English UI and documentation, standard
editing commands, Command-O / Command-W, settings, and visible version information.

### 3. Modules and ownership

| Target / area | Responsibility | Main verification |
|---|---|---|
| ConnectionCore | `.vv` parsing/validation, connection plans, origins, cookie selection | Observable input/output unit and generated tests |
| SessionCore | State, generations, ordered input, sharing permissions, shutdown | Controlled events and fake transport failures/races |
| SwiftSpiceAdapter | Map approved plans onto real SwiftSpice sessions, events, audio, display | Integration through the actual public API |
| SpiceClient | SwiftUI, AppKit, WebKit, file intake, preferences, confirmation | Real WebKit / URLSession and assembled-app verification |

Core targets do not depend on AppKit, WebKit, or SwiftSpice. Inject clocks,
senders, file operations, clipboard access, and preferences. MainActor owns
presentation state. Each connection has one owner for transport, agent, audio,
input queue, and tasks. Every unstructured task has an intentional stop/join path.

Use `received → awaitingConfirmation → connecting → connected → stopping → closed`
as the basic lifecycle, retaining typed failure reasons. Cancelled confirmations,
old generations, and callbacks from closed windows cannot start a new connection
or sharing. Bind confirmation to an immutable parsed connection plan; never
re-read a mutable path after approval and connect using different contents.

### 4. Review findings and acceptance criteria

| ID | Root cause and new behavior | Required regression coverage |
|---|---|---|
| R1 | `buttonNumber == 0` does not establish human intent. Require native confirmation instead of treating navigation metadata as permission | Real WebKit automatic navigation/form submission: zero connect calls and host clipboard access before approval; cancellation and stale approval rejected |
| R2 | Do not inherit Sparkle 2.9.4 or the old update infrastructure. Omit automatic updating initially | Resolved dependencies, Info.plist, and built app contain no old updater/feed/key; startup makes no updater connection |
| R3 | Replace host-only checks with scheme, normalized host, and effective port | Omitted port equals 443; 8443 differs; reject HTTP, userinfo, iframe, foreign-origin handoffs and redirects |
| R4 | Never carry a manually constructed Cookie header unchanged across redirects | Real HTTPS redirect verifies path/domain/secure/expiry again; `/private` cookies never reach `/public` |
| R5 | Parse absent, explicitly disabled, and malformed ports separately | Explicit empty, `tls-port=oops`, and out-of-range values fail; supported disabling syntax pinned by specification-based fixtures |
| R6 | Do not silently ignore `secure-channels` or other transport-protection requests | Required secure channels only connect if all-channel TLS can guarantee them; unknown channel names or unsupported protection requirements fail |
| R7 | Input completion must not gate transport closure | A blocked send cannot prevent immediate clipboard revocation, transport close, and disconnection completion; cover reconnect, quit, and failure paths |
| R8 | Do not trash user files immediately after launching an asynchronous connect | Explicit preference plus confirmed connection success required; exactly once, never on failure/cancel; refuse if another file replaced the path |
| R9 | Doctor must do more than find the Metal compiler shim | Compile a small shader; fail clearly if the component is missing or unusable |
| R10 | Attribution must match actual dependencies and reach the artifact | Reconcile lockfile, inventory, bundled notices, and native artifacts |
| R11 | Replace implementation-string assertions with behavioral regressions | Reuse the reproductions: tests fail with old behavior and pass with the corrected contract |
| R12 | Release gates must run and fail closed | Test, signing/notarization, missing-resource, and dependency-audit failures stop package / verify-release |

R1–R7 are the original major findings. R8–R12 assign tracking IDs to its
supplementary findings. This table is not the whole-project review: account for
every reference file as reimplemented, delegated to the dependency, intentionally
removed with a reason, or unreviewed. Investigate additional defects and update
that ledger throughout the port.

### 5. Web, TLS, and file boundaries

- Derive the handoff origin from the user's configured HTTPS portal URL. Page
  navigation must not silently change it. Evaluate ordinary login navigation
  separately from permission to hand a `.vv` file to the native application.
- Fetch `.vv` data with a dedicated, origin-constrained URLSession. Reevaluate
  origin and cookies on every redirect. Apply a 1 MiB limit, finite timeout and
  redirect count; reject HTTP errors, invalid UTF-8, and truncated bodies.
  Never forward cookies or authentication to another origin. Apply same-origin
  Set-Cookie within the fetch session only, without an implicit shared cookie jar.
  Inspect and port Ravada clock-skew correction only within its existing narrow
  conditions and fixtures, never as general extension of expired cookies.
- Do not generate unlimited confirmations from server-controlled popups or
  downloads. Keep one pending candidate without silently replacing the approved
  subject; selecting a new candidate is explicit. Show safe rejection reasons.
- Portal TLS uses OS validation by default. A native prompt may approve a
  temporary self-signed certificate exception showing origin and SHA-256
  fingerprint. Scope it to that origin and certificate, expire it when closing
  the portal, and never treat it as a blanket bypass of other TLS errors.
  Persistent certificate exceptions are omitted initially.
- Port SPICE system trust, per-file CA, and CA + host-subject validation.
  Malformed CAs, mismatches, and unknown security directives are explicit errors.
  Compare `.vv` semantics with the virt-viewer specification and SwiftSpice
  implementation. Reject ambiguity in invalid/duplicate security-sensitive keys
  and document their distinction from harmless display hints.
- Parse portal bodies in memory so temporary credential files are unnecessary.
  Read user-selected files once with a size bound and preserve them by default.
  `delete-this-file` alone never permits deletion: require user preference,
  successful connection, and verification that the source is still the same file.
  Report cleanup failure separately from connection success.

### 6. Shutdown and sensitive information

At disconnect initiation, synchronously revoke new input and host clipboard
access, and invalidate the generation. Key release is a short best-effort
operation; explicitly close/cancel the transport without depending on it.
Then collect agent, audio, and input shutdown. Task.cancel alone is not a stop
guarantee. Avoid a timeout TaskGroup that itself waits forever for an
uncooperative child. If the dependency API cannot guarantee shutdown, record the
need for a dependency fix/API change instead of masking it with a disconnected UI.

Diagnostics default OFF and contain bounded in-memory aggregates only. Exclude
hosts, URLs, file paths, tickets, cookies, key contents, clipboard contents, and
display pixels. Errors must not interpolate response bodies or credentials.
Retain the last aggregate snapshot after disconnection for explicit Copy Summary.

### 7. Permissions, dependencies, and distribution

The app reads selected files, optionally moves them to Trash after successful
connection, and connects to chosen portals and SPICE servers. Clipboard access
is opt-in as described above. Microphone, camera, screen recording,
Accessibility, Apple Events, USB, and administrator privileges are not product
requirements. If the OS requires consent, explain it at the intended operation.
The application requests no OAuth API scopes of its own; portal authentication
runs in WebKit.

Use Hardened Runtime without mechanically adding JIT exceptions to a native
Swift app. Verify the real WebKit-containing bundle to establish entitlement
needs. App Sandbox support and App Store distribution are outside this plan.

Inventory SwiftSpice's MIT text and every native dependency's complete licenses,
provenance, versions, and hashes. Check distribution requirements and any
relinking materials for LGPL static components before shipping; the application's
MIT license is not a substitute for that work. Attribute reference-derived code
and preserve Ching367436 / BeriBeli notices and permission text in `NOTICE.md`.
Keep root LICENSE as the standard MIT text, and include complete dependency
notices inside `.app/Contents/Resources/`.

Provide `make test`, `make lint`, `make doctor`, `make build`, `make package`,
and `make verify-release`. Build a local verification `.app` under `dist/`.
Package runs tests and dependency audits, uses verbatim organization signing and
notarization scripts, and requires Developer ID signing, notarization, and a
stapled ticket before producing `spice-client-v0.1.0-darwin-arm64.zip`-style
release artifacts. Never label an unnotarized build distributable. Keep signing
values in the environment/Keychain. This design-writing step does not create or
publish a remote repository, install an application, tag, or release.

### 8. Milestones and verification

1. **Approve and scaffold:** settle this design, compatibility/removal list,
   and source ledger; establish build wiring, docs, licensing, and org checks.
2. **ConnectionCore and regressions:** implement `.vv`, TLS, origins, and
   cookies; preserve valid fixtures and add known-failure fixtures.
3. **SessionCore and SwiftSpiceAdapter:** connect/disconnect/reconnect, ordered
   input, audio, rendering, agent, clipboard; start with blocked-send/race/cancel tests.
4. **Application and portal:** wire file intake, native confirmation, WebKit,
   preferences, diagnostics, multiple windows, both languages, and accessible labels.
5. **Whole-project verification:** close unreviewed ledger entries, independent
   review, real WebKit/HTTPS tests, built-app startup/resources/standard commands.
6. **Real peers and release gates:** exercise QEMU/Ravada TCP and TLS, display,
   audio, input, clipboard, resize, disconnection, and diagnostics. Verify a clean
   environment, signing/notarization, archive contents, and bundled licenses.

Update tests and English/Japanese README, CHANGELOG, and AGENTS alongside each
stage, using small typed commits. Distinguish implemented from release-ready.
Record real-peer and human hardware UI checks as unverified until actually run;
mocks and the old application's build are not substitutes. Update the umbrella
and profile and run `check-org.sh` when integrating the release repository.

## Consequences

- Continue using the same backend while centralizing permission, validation,
  and lifetime boundaries in the new app. This is not a mechanical code copy.
- Initially omit automatic updates and persistent portal certificate exceptions;
  either can follow a separate design and verification. USB, microphone, WebDAV,
  Proxmox proxy, multiple display streams, Intel/Windows/Linux, and saved SPICE
  passwords are also outside this plan.
- Confirmation and clipboard OFF are intentional changes from the reference.
  Expired tickets require refetching, not indefinite retention.
- SwiftSpice/native dependency defects still matter. Keep app review separate
  from dependency source/binary verification, and block release if shutdown APIs
  or distribution obligations remain unresolved.
- Adopt the clipboard API gap identified by independent design verification,
  adding the minimal patch and acceptance tests above. This adds local dependency
  maintenance; evaluate and remove it when a compatible upstream fix is available.

## Alternatives considered

1. **Minimal fork fixes:** smaller diff, but retains distributed permission,
   shutdown, and file ownership and does not meet the requested redesign.
   Preserve useful specifications and fixtures instead.
2. **Rewrite protocol/rendering:** the user chose SwiftSpice; this also imposes
   a much larger codec and interoperability validation burden.
3. **Fix only web gesture detection:** observed navigation metadata does not
   establish user intent; native confirmation binds approval to the parsed plan.
4. **Upgrade Sparkle and port it immediately:** requires an independent feed,
   keys, and release operation; establish connection quality first.
5. **Prohibit plain TCP:** would remove existing direct TCP use. Preserve
   explicit TCP while prohibiting downgrade from failed TLS requirements.

## References

- [spice-mac baseline](https://github.com/BeriBeli/spice-mac/tree/4631b0cf43032671fe01e994db5613e78a91037a)
- [SwiftSpice 0.4.2](https://github.com/BeriBeli/spice-swift/tree/v0.4.2)
- [Organization conventions](https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md): planning, scaffolding, ADR approval, independent review, signing.
- [Development process](https://github.com/nlink-jp/knowledge/blob/main/docs/en/development-process.md): extract specifications/fixtures first and cross-check lessons the reference did not apply.
- [Testing](https://github.com/nlink-jp/knowledge/blob/main/docs/en/testing.md): wrong expectations can pass; drive actual boundaries for R1/R4 and hardware gates.
- [Configuration and I/O](https://github.com/nlink-jp/knowledge/blob/main/docs/en/config-and-io.md): do not hide malformed configuration with defaults or mistake cancellation notification for guaranteed shutdown.
- [macOS GUI](https://github.com/nlink-jp/knowledge/blob/main/docs/en/macos-gui.md): resource lookup, version display, editing menus, duplicate-instance defense; test startup with development resources unavailable.
- [Release engineering](https://github.com/nlink-jp/knowledge/blob/main/docs/en/release-engineering.md): fail-closed gates after optional notarization and verify actual archive notices after LICENSE separation.

Also consulted workspace memory `index_gui_dev`,
`feedback_swiftpm_bundle_module_app`, and `feedback_menubar_duplicate_instance_guard`.
Place the duplicate guard before application initialization and integration-test
that Finder file delivery is not silently lost. Read the menubar-spacer
AGENTS/CLAUDE and SwiftSpice AGENTS; spice-mac's baseline had neither file.
