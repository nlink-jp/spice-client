# Changelog

## [Unreleased]

### Added
- `SPICE_CLIENT_LIVE_PEER_DEMO=1` starts a live peer whose guest paints its root and
  opens a terminal, so the session can be looked at by hand. The gate never sets it,
  and the guest its tests observe is unchanged.

### Fixed
- Both READMEs said the live-peer guest is about 18 MB. It has been about 111 MB since
  Xorg was added, nearly all of it the Mesa stack that `xorg-server` pulls in. The
  Japanese README also still described two vendored patches, where there are three.

## [0.2.0] - 2026-09-18

### Added
- Send files to a connected guest, by dropping them on the session window or through
  Session ▸ Send Files…. The window lists one row per drop with aggregate progress and
  a cancel, names the files that failed, and says that delivered bytes cannot be
  recalled. A `.vv` dropped on a session window is refused, because it carries a
  ticket; the launcher still accepts one to start a connection. Transfers belong to the
  connection and are failed when it ends (ADR-0005).
- Diagnostics show `audio_packets` and `audio_frames` alongside the existing counters,
  and `files_sent`, `files_failed` and `bytes_sent` for file transfer. Counts only: no
  file names or paths.
- `make verify-vendor` replays `Vendor/*.patch` against the pinned upstream and fails
  if the recorded patches no longer compose the vendored tree. Needs the network, so it
  is separate from `make test`.
- `make live-peer`: a real spice-server (QEMU 8.2, spice-server 0.15) in a Podman
  container with an Alpine guest running Xorg and spice-vdagent, driven through the
  application's own session path; verifies transport, ticket, display frames, cursor,
  injected input reaching the guest, authentication failure and reconnection, TLS with a
  per-run certificate authority through the `.vv` `ca` and `host-subject` paths and
  refusal of a decoy authority (ADR-0002), and against the real agent the clipboard
  broker in both directions under sharing and focus changes, repeated viewport
  resizes, audio playback from the guest (ADR-0003), and a file sent to the guest whose
  SHA-256 the guest reports back (ADR-0005). `make package` requires a clean pass
  recorded for the release commit.

### Fixed
- A viewport resize after the first one on a session no longer goes missing. The
  backend sent a monitors configuration only when none was in flight and cleared that
  on a reply which QEMU does not send under virtio-gpu, so the first resize latched
  the sender for the life of the agent connection while the session still reported
  resizing as available. The vendored patch now bounds that wait (ADR-0004).
- The vendored clipboard patch no longer returns early when clipboard access is denied.
  That early return also skipped the display-configuration and file-transfer drives at
  the end of the same method, which is the only periodic path while automatic pasteboard
  synchronization is on (ADR-0005 §6).

Verified against a real spice-server and a real spice-vdagent by `make live-peer`,
which this release requires to have passed on the release commit. The Ravada portal
stays on simulation and H.264 is still unverified. See `docs/en/verification.md`.

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
