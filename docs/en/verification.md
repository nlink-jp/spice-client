# Verification record

Date: 2026-09-17. Local Apple Silicon host, macOS 27, Xcode/Swift 6.3.
Deployment target: macOS 26. The minimum OS version has not been tested separately.
This is a local development build, not a published or notarized release.

## Executed

- Reference: reviewed all 76 tracked application files and recorded their disposition.
  The original spice-mac checkout remains unchanged.
- `make test`: Swift parser, origin/cookie, immutable approval, lifecycle, input,
  clipboard authority, file preservation, UTI-independent selection, localization,
  menus, and inherited cookie-expiry regressions. Also verifies pinned dependency
  files and documentation links, and runs three Python archive rejection tests.
- `make simulate`: all 38 registered Swift tests, including four conditional
  simulation cases, passed. Real WebKit loaded local HTTPS pages performing an
  automatic location change and form POST; neither created a session without
  native approval. Actual URLSession redirects reselected cookies. Cross-origin,
  oversized, invalid UTF-8, and truncated responses were rejected; gzip was accepted.
  Temporary certificate trust still rejected a wrong hostname and expired date.
- The fake SPICE peer spoke the real binary protocol over loopback TCP. The actual
  SwiftSpice transport and SessionController completed bootstrap and sent six input
  packets for Ctrl-Alt-Delete. Authentication failure, malformed handshake, and
  cancellation while handshake was stalled were exercised. Counters: six accepted
  sockets, six closed sockets, six input packets, zero scoped-cookie leaks.
- `make test-vendor`: **897 SwiftSpice tests passed**, including the new actual
  agent-manager clipboard revocation/reannouncement regression. The first fully
  concurrent attempt stalled independent filesystem fixtures and was stopped;
  sequential execution completed. No upstream tests were deleted to obtain success.
- `make build`: release optimization, actual Metal compilation, app assembly,
  dynamic-library relocation audit, and local ad-hoc signature verification passed.
- Built-app visual inspection: Japanese launcher/version/menu, real file picker,
  populated native confirmation with clipboard OFF and plaintext protection text,
  and cancellation back to the launcher. The UTI collision found during this check
  was fixed and the same file became selectable.
- Both bundled Metal libraries loaded. A copy of the application launched and exited
  using `--smoke-test` while both development `.build` trees were temporarily hidden.
- Independent design and implementation review performed; the three implementation
  findings (retry focus, second portal candidate, final ZIP verification) were fixed
  and checked again. No additional high-impact defect was reported in that pass.

## Scope limits

There is no real QEMU/Ravada endpoint available; the user explicitly requested
simulation. End-to-end guest pixels, audio output, real clipboard contents,
resolution negotiation, sustained input, full-screen behavior with a guest,
and an actual H.264-to-MJPEG retry remain unverified. Upstream codec/audio/Metal
unit tests do not replace that interoperability and hardware validation.
Finder double-click/duplicate-process handoff and behavior on macOS 26 have not
been fully exercised. The real native file picker was exercised separately.

Native dependencies are unchanged pinned artifacts; their complete binary behavior
has not been reverse-engineered or certified defect-free. All 418 vendored file
hashes, symbolic links, 28 native hash entries, and the local patch are tracked.
The original reference's entire updater was omitted rather than inherited.

The release verification rejects invalid archives and validates the actual archive
when one is supplied. No Developer ID/notarization operation or public release was
performed, and no release ZIP is claimed verified. No remote repository was created,
no umbrella submodule/profile was changed, and the project remains under `_wip/`.
The initial organization check reported existing changes in `cli-series` and
`lab-series`. The final check reported three unrelated findings: `util-series`
has a dirty tree, and its `active-lens` and `active-lens-gui` submodule pointers
differ from their remotes. Those projects were left unchanged. Go checks do not
apply to this Swift project. The reusable WebKit testing lesson was fed back to the
organization knowledge repository in both languages.

## Reproduce

Run `make test`, `make test-vendor`, `make simulate`, then `make build`.
Simulation keys and tickets are generated in temporary directories and removed;
there are no persistent fixture private keys or real credentials in this project.
See [README](../../README.md) and [review](review.md).
