# Changelog

## [0.1.0] - Unreleased

- Reimplement the macOS app as Spice Client with native confirmation, independent
  session windows, English/Japanese UI, local files, and an HTTPS Ravada portal.
- Reject invalid TLS requirements, enforce complete portal origins, and reselect
  redirect cookies. Keep connection tickets in memory and preserve changed files.
- Default clipboard sharing off, authorize actual access for only the focused
  session, block automatic guest-to-guest relay, and close transport before waiting
  on input. Retain SwiftSpice 0.4.2 with a documented clipboard access patch.
- Add input coalescing, audio/guest integration, viewport resize, a one-time MJPEG
  fallback, aggregate diagnostics, and a new application icon.
- Add real WebKit/HTTPS/SPICE simulation, regression tests, pinned dependency
  hashes, actual Metal compilation checks, and final-archive release verification.
- Retire the reference automatic updater and legacy settings migration. This is
  a local development build; a real-guest validation and notarized release are pending.
