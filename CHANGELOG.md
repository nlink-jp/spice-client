# Changelog

## [Unreleased]

### Added
- `make live-peer`: a real spice-server (QEMU 8.2, spice-server 0.15) in a Podman
  container with a minimal Alpine guest, driven through the application's own session
  path; verifies transport, ticket, display frames, cursor, injected input reaching the
  guest, authentication failure and reconnection, plus TLS with a per-run certificate
  authority through the `.vv` `ca` and `host-subject` paths and refusal of a decoy
  authority (ADR-0002). `make package` requires a clean pass recorded for the release commit.

## [0.1.0] - 2026-09-18

### Added
- Reimplement the macOS app as Spice Client with native confirmation, independent
  session windows, English/Japanese UI, local files, and an HTTPS Ravada portal.
- Add input coalescing, audio/guest integration, viewport resize, a one-time MJPEG
  fallback, aggregate diagnostics, and a new application icon.
- Add real WebKit/HTTPS/SPICE simulation, regression tests, pinned dependency
  hashes, actual Metal compilation checks, and final-archive release verification.
- Distribute a Developer ID signed and notarized `.app` through GitHub Releases and
  the `nlink-jp/tap` Homebrew cask.

### Security
- Reject invalid TLS requirements, enforce complete portal origins, and reselect
  redirect cookies. Keep connection tickets in memory and preserve changed files.
- Default clipboard sharing off, authorize actual access for only the focused
  session, block automatic guest-to-guest relay, and close transport before waiting
  on input. Retain SwiftSpice 0.4.2 with a documented clipboard access patch.

### Removed
- Retire the reference automatic updater and legacy settings migration.

### Internal
- Link the release binary against the installed macOS SDK explicitly and reject
  any other linked SDK in `make build` and `make verify-release`; require one
  deployment target across Package.swift and Info.plist.
- Derive the version from `git describe`, write it into Info.plist at build time,
  check it in the built bundle and the final archive, and reject version literals
  in sources.

Real-guest QEMU/Ravada validation remains open; this release is verified by
simulation. See `docs/en/verification.md`.
