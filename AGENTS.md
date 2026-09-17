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
- `Integration/LivePeer`, `make live-peer`: real spice-server in QEMU (TCG) under Podman with an
  Alpine guest running Xorg and spice-vdagent (ADR-0002, ADR-0003); needs a running Podman
  machine; `Artifacts/` (about 113 MB) is ignored by git and rebuilt when the guest sources change.
- `make test-vendor`: sequential upstream suite; unbounded concurrency stalls filesystem fixtures.
- `make package`, `make verify-release`: require valid Developer ID signing/notarization, and a
  clean `make live-peer` pass recorded for the exact release commit (`Artifacts/last-pass.json`).

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

The version is stated once: the Makefile derives `VERSION` from `git describe`,
`build-app.sh` writes it into Info.plist (`${VERSION}` placeholder) and checks the
bundle's `--version`, `verify-release.py` checks it again in the final archive, and
`check-project.py` rejects version literals under `Sources/`. `make package` refuses
a `VERSION` that is not exactly a `vX.Y.Z` tag.

WebKit under the Hardened Runtime is observable only in the signed bundle: after
`make package`, run the notarized app with `--portal-smoke=<https url>` and require
`Smoke: portal loaded` before uploading. Tests run in an unsigned test host and
cannot stand in for it.

Use `make` for builds and `dist/` for deliverables. Keep both language documents
current; preserve original copyright notices. Tests accompany behavior changes.
Read `Vendor/SwiftSpice/AGENTS.md` before dependency changes. Keep its original
code and binaries traceable through `Vendor/UPSTREAM.json` and the local patch.

Real peer and human GUI checks are separate gates: never substitute mocked
success or the reference app's test results. Keep their status explicit in docs.
The live peer verifies transport, ticket, TLS, display, cursor, input, shutdown, and
through the guest's spice-vdagent the clipboard broker (sharing and focus, both
directions) and resize; not audio, H.264, file transfer or a Ravada portal.
`spice-vdagentd` exits without `/dev/uinput`, so the guest init loads `uinput`; the
init is layered so an Xorg failure keeps the transport tests running and the gate
fails on the missing agent receipts. The SPICE server serves one client, so the two
suites run as separate sequential `swift test` invocations. The peer has one display
head: two made QEMU dump core on 8.2.2 and 10.0.13 alike.
`SPICE_CLIENT_LIVE_PEER_KEEP_LOG=<path>` keeps the whole guest log for diagnosis.
The vendored dependency carries two local patches, applied in the order
`Vendor/UPSTREAM.json` lists them, both touching `SpiceClipboardManager.swift`:
clipboard authorization (ADR-0001) and the monitors-configuration send window's
deadline (ADR-0004, without which only the first resize of an agent connection
reached the guest). The gate requires both resize modes in order.
Image references under `Integration/` are digest-pinned and checked; never write
under `Vendor/` (its file set is hash-checked). Inside the Podman machine QEMU binds
`0.0.0.0`; the host publishes on `127.0.0.1` only. A stale container of the gate's
name is removed on start, and QEMU runs under a 30-minute `timeout`, so an interrupted
run cannot leave QEMU forever. The ticket and the TLS material (CA, server
certificate, decoy CA) are per-run files under `~/.cache/spice-client/live-peer/`
(removed by `stop.sh`), never arguments.
Do not publish, install, or change system preferences while testing fixtures.

## Implementation notes

Read `docs/en/verification.md` before making claims about hardware or real guests.
`docs/{en,ja}/source-map*` covers all 76 reference application files. Vendor changes
must update the matching patch in `Vendor/` and `Vendor/UPSTREAM.json`, whose
`patches` list is ordered; file hashes plus native entries and links are checked.
Do not edit vendored binaries.

The WebKit async trust delegate is `webView(_:respondTo:)`, not an overload named
`didReceive`. Test through WebKit; optional Objective-C protocol methods may compile
without receiving callbacks. File picking uses an extension delegate because another
installed client's UTI may otherwise make valid `.vv` files unselectable. Keep that
delegate alive across the modal panel, including optimized builds.

The repository is `github.com/nlink-jp/spice-client`, a `lab-series` submodule
(ADR-0001 amendment of 2026-09-18). Releases are `make package`: Developer ID signing,
notarization, stapling, the final-archive check, then `make brew` for the cask; keep
the vendored `scripts/{gen-brew.sh,cask.rb.tmpl,release-brew.mk}` identical to
`.github/templates/`. A real spice-server and a real spice-vdagent are covered by `make live-peer`
(ADR-0002, ADR-0003); a Ravada portal, audio and H.264 remain unverified, and
`docs/{en,ja}/verification*` says so. Go checks do not apply to this Swift project.
