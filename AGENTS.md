# spice-client

Native macOS 26+ arm64 SPICE client in Swift 6 language mode (tools version 6.3,
built with the Xcode 27 / Swift 6.4 toolchain), SwiftUI / AppKit / WebKit.
Organization rules: https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md

The user approved ADR-0001 on 2026-09-17. Implement the application while retaining
SwiftSpice; a narrowly scoped clipboard API patch is explicitly part of the design.

## Layout and commands

- `Sources/ConnectionCore`: immutable connection plans, strict file validation, origins/cookies.
- `Sources/SessionCore`: pure lifecycle and permissions; no GUI or backend imports.
- `Sources/SwiftSpiceAdapter`: backend integration, ordered input, clipboard broker.
- `Sources/SpiceClient`: native windows, confirmation, portal, file intake, settings.
- `Vendor/SwiftSpice`: pinned upstream with documented local clipboard patch.
- `Tests`: regressions; `docs/{en,ja}`: accepted ADR and source coverage ledger.
- `make test`, `make lint`, `make doctor`, `make build`: local verification.
- `make simulate`: temporary HTTPS/WebKit/SPICE loopback fixtures; no real guest required.
- `make test-vendor`: sequential upstream suite; unbounded concurrency stalls filesystem fixtures.
- `make package`, `make verify-release`: require valid Developer ID signing/notarization.

## Invariants

All connection entry paths must pass immutable native confirmation. No plaintext
fallback from malformed TLS. Cookies are selected anew for every redirect using
scheme/host/effective-port origin. Clipboard defaults off; actual access checks
the active session and permission generation. Closing transport never depends on
input draining. No credentials, endpoint details, clipboard or pixel contents in
diagnostic logs. No old updater feed, keys, or settings migration.

The release link step names the SDK explicitly: `build-app.sh` passes
`-platform_version macos <minimum from Package.swift> <current SDK>`, and both
`build-app.sh` and `verify-release.py` fail when `LC_BUILD_VERSION` records any
other SDK. macOS draws an app linked against an old SDK with the previous window
chrome, the Xcode 27 toolchain stamps the deployment target unless told
otherwise, and signing, notarization and every test pass either way. The
deployment target is stated once: `check-project.py` requires Info.plist's
minimum system version to equal the Package.swift platform.

Use `make` for builds and `dist/` for deliverables. Keep both language documents
current; preserve original copyright notices. Tests accompany behavior changes.
Read `Vendor/SwiftSpice/AGENTS.md` before dependency changes. Keep its original
code and binaries traceable through `Vendor/UPSTREAM.json` and the local patch.

Real peer and human GUI checks are separate gates: never substitute mocked
success or the reference app's test results. Keep their status explicit in docs.
Do not publish, install, or change system preferences while testing fixtures.

## Implementation notes

Read `docs/en/verification.md` before making claims about hardware or real guests.
`docs/{en,ja}/source-map*` covers all 76 reference application files. Vendor changes
must update `Vendor/clipboard-boundary.patch` and `Vendor/UPSTREAM.json`; 418 file
hashes plus native entries and links are checked. Do not edit vendored binaries.

The WebKit async trust delegate is `webView(_:respondTo:)`, not an overload named
`didReceive`. Test through WebKit; optional Objective-C protocol methods may compile
without receiving callbacks. File picking uses an extension delegate because another
installed client's UTI may otherwise make valid `.vv` files unselectable. Keep that
delegate alive across the modal panel, including optimized builds.

The project is staged in `_wip/`, with no published remote or umbrella integration.
Go checks do not apply to this Swift project. Before publishing, complete Developer
ID/notarization and real-peer validation, integrate the lab-series submodule, update
the organization profile, and rerun the organization health check.
