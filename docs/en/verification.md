# Verification record

Date: 2026-09-17. Local Apple Silicon host, macOS 27, Xcode 27 with the Swift 6.4
toolchain (Swift tools version 6.3; corrected 2026-09-18, the original text named
the tools version as the toolchain).
Deployment target: macOS 26. The minimum OS version has not been tested separately.
At that date the artifact was a local development build; the 2026-09-18 section
below records the release gates.

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
when one is supplied. As of 2026-09-17 no Developer ID/notarization operation or
public release had been performed, no remote repository existed, no umbrella
submodule/profile had been changed, and the project stayed under `_wip/`; the
2026-09-18 section records the release.
The initial organization check reported existing changes in `cli-series` and
`lab-series`. The final check reported three unrelated findings: `util-series`
has a dirty tree, and its `active-lens` and `active-lens-gui` submodule pointers
differ from their remotes. Those projects were left unchanged. Go checks do not
apply to this Swift project. The reusable WebKit testing lesson was fed back to the
organization knowledge repository in both languages.

## 2026-09-18 update

The local development build was linked against SDK 26.0 (the deployment target)
although the installed SDK is 27.0, the Xcode 27 toolchain behaviour already
corrected across the organization's other Swift applications. `make build` now
names the SDK at link time and, together with `make verify-release`, rejects any
other linked SDK. Rerun on the same host: `make test`, `make simulate` (same six
connections, six input packets, zero scoped-cookie leaks), `make build` (linked
SDK 27.0, no warnings), `--resource-check` and `--smoke-test` on the new bundle.
`make test-vendor` and the human GUI inspection were not repeated. The user decided
to place the repository in `lab-series` and to release v0.1.0 on this simulation-based
verification; the real-peer gate stays open. The version now comes from `git describe`
and is checked in the built bundle and the final archive.

Release v0.1.0 (2026-09-18): `make package` ran the tests, built the bundle (linked
SDK 27.0), signed it with Developer ID under the Hardened Runtime without
entitlements, and the Apple notary service returned Accepted; the ticket is stapled
and `verify-release` passed on the final archive. The notarized bundle loaded a
public HTTPS page through `--portal-smoke`. A copy extracted from the archive with
a quarantine attribute was accepted by `spctl --assess` as Notarized Developer ID
and answered `--version` and `--resource-check`; the binary is arm64 only. The
archive uploaded to GitHub was downloaded back with an identical SHA-256
(`19f920fc362bcd27ae508392acf8a84d2dcab51a1dde4140398001152fb75131`; executable
`fdfac627d3161218c89ae07d032c866c22a06f758a12565deebd42310400093a`), and the
Homebrew cask was generated from that archive. `make test-vendor` and the real-peer
gate remain as stated above.

## Live peer gate (2026-09-18, ADR-0002)

`make live-peer` passed on commit `8850484` with a clean tree: a real spice-server
(`libspice-server1 0.15.1-1build2`, `qemu-system-arm 1:8.2.2+ds-0ubuntu1.18`) in the
digest-pinned Ubuntu 24.04 image under the Podman machine with TCG, and an Alpine
`linux-virt 6.12.110-r0` guest built from the digest-pinned Alpine 3.22 image. Through
the application's own `ConnectionPlan` → `SessionController` → SwiftSpice path, the
session connected with the per-run ticket, a visible desktop subscription observed real
frame revisions, the injected A key was recorded by the guest's evdev stream, a wrong
ticket ended in an authentication failure with the peer surviving, and a second session
connected after disconnect. The diagnostics summary contained neither ticket nor host.
Five boots (two spike, three gate runs) reached the guest markers 4 s after `podman run`;
the host listener was `gvproxy` on `127.0.0.1` only and the ticket was absent from the
container's command line. Outside this phase at the time: audio, H.264, the Ravada
portal, the guest agent (clipboard, resize) and file transfer; the later phases below
cover all but H.264 and the portal. The pass record lives outside git and `make package` requires
one for the release commit.

Phase 1b, TLS (2026-09-18): the peer also listens on `tls-port` with a per-run CA and
server certificate generated on the host. `make live-peer` passed on commit `237860c`
with a clean tree: the `.vv` `ca` path and the `ca` plus `host-subject` path both
connected over TLS to the real spice-server, a decoy CA and a wrong subject were
refused during the TLS handshake (the server logged `SSL_accept failed` and stayed up),
and the plain and TLS connections that followed still succeeded. Across the day the
five-test suite ran eleven times against a live peer; ten passed. In the one failure the
peer container had exited by the fourth test and its exit status and log were lost
because the container was started with `--rm`; the gate now keeps the container until
`stop.sh` removes it and prints its exit state on failure, so a recurrence will carry
evidence. Six consecutive suite runs against one kept peer, twelve refused TLS
handshakes included, did not reproduce it.

## Agent guest (2026-09-18, ADR-0003)

The live peer guest now runs Xorg and `spice-vdagent 0.22.1` on the same Alpine
`linux-virt` kernel, and the gate drives this application's clipboard broker and
resize path against them. `make live-peer` passed on the agent guest in eleven of
twelve runs; the suite covers transport, TLS, clipboard and resize.

Clipboard, through an injected in-memory pasteboard so the operator's own
pasteboard is never read or written: a host copy reached the guest's X clipboard
and the guest's answer came back through the broker's write; with sharing off and
with focus resigned the withheld text was never announced to the guest, and the
text current when sharing or focus resumed was. Measured round trips over ten
runs: 423 to 844 ms for the first exchange, 582 to 644 ms after sharing resumed,
against a 10 s bound. The opening exchange of a session was lost twice in about
twenty runs, before the guest's agent had finished negotiating for that
connection; a second copy is delivered, so the test copies again up to three
times for that first exchange only and records the attempt count, which has been
1 in every run since. The revocation exchanges have no retry. The gate walks the guest log in order and requires each
delivered text's SHA-256 after the previous match and each withheld text's
nowhere.

Resize: the first `resize` reached the guest, which applied the mode and screen
size. The second one on the same agent connection did not, a defect in the
vendored backend's reply-gated sender; ADR-0004 bounded that wait and the gate
now requires both modes in order, which three consecutive runs delivered. The
full vendored suite passed after the change. The guest's new screen size
does not come back to the client at all under `virtio-gpu-pci`, and
`qemu-system-aarch64` offers no QXL device, so the resize observation is
guest-side, as it already is for the injected key.

Audio playback is verified in a second gate phase (2026-09-18): the guest plays a
silent PCM stream through `virtio_snd`, and the session's `audio_packets` and
`audio_frames` counters grow while `audioUnavailable` stays false. Silence keeps
the machine running the gate quiet while exercising the same path.

File transfer is verified in the agent phase (2026-09-18): the application sends a
64,000-byte file of known content through its own drop-decision path, and the
guest's watcher reports the file's SHA-256 once its modification time settles.
The gate requires that digest to equal the one the test recorded, so a pass means
the guest holds the same bytes, not merely that a transfer reported success. Seven
consecutive gate runs reported the same digest, `c57e96ad…a46212fe`; the one gate
failure among them came later, in phase 2, from the port race described below. The
watcher keys on modification time because `spice-vdagent` allocates the whole file
before the first byte arrives, which makes size stability meaningless.

Three defects sat behind one symptom, every transfer stalling at exactly 32,000 of
64,000 bytes, and the first two hid the third. This repository's own ADR-0001
clipboard patch returned early on denied access and skipped the drives at the end
of the same method; the dependency's transfer drive is not re-entrant, so two
drives invalidated each other's commit and re-sent one offset for ever; and the
16,000-byte default chunk does not fit the agent channel's token window, which
QEMU opens ten tokens wide and replenishes five at a time while a message costs
one token per 2 KiB fragment. The chunk is now 4,000 bytes and the drive is
serialised in a third vendored patch. `make verify-vendor` replays all three
patches against the pinned upstream so the record cannot drift from the change.

Four environment defects were found and fixed: `swift test` ran the suites in
parallel against a server that serves one client; two display heads made QEMU dump
core on both 8.2.2 and 10.0.13; the playback device does the same under
repeated client connect/disconnect (3 crashes in 12 runs with it, 0 in 18 without,
on 8.2.2, and 2 in 5 on 10.0.13); and podman lost the race for the ephemeral
loopback port it had just been allocated, once in three consecutive runs, in
phase 2 immediately after phase 1 released its own. The suites now run
sequentially, the peer has one display head, audio runs on its own peer with a
single connection, which was clean in 5 of 5 runs, and a peer start that loses the
port race is retried with a fresh allocation up to five times. Two defects the gate could not see were found by looking at a guest desktop by
hand (2026-09-18). The guest's Xorg had no input driver and no running udevd, so
it started with zero input devices: keys reached the guest kernel, which is all
the gate's evdev reader ever checked, and no X client could be typed into. And
the application's session window painted its control bar over: the backend's
presentation layer was 1024x752 inside a 1024x676 view whose parent did not clip,
so the phase text, the clipboard toggle and the Disconnect and Diagnostics
buttons were covered. Both are fixed. The gate now requires Xorg to have taken at
least two input devices, and requires an X client in the guest to have received
the injected key by keysym: the guest runs `xev` on the root window, so the key
is now observed where a person would type, not only at the guest kernel. Not covered: H.264, the Ravada portal, a
desktop environment's own clipboard managers, and USB.

## File transfer bookkeeping (2026-09-22, ADR-0005 §7)

Two gate cases were added before the fix and failed on it, as intended: six 1 MB
files with the stall timeout shortened to 2 s (the fifth and sixth failed as
"stalled" without being sent), and a cancel in flight followed by five more files
(one failed with "maximum concurrent file transfers reached"). After the fix
(`3e44d8c`, clean tree) all eleven gate tests passed; the six files, 6 MB in
all, took 35 s and the guest reported every digest. The cancel case recorded
`cancel-ack none`: spice-vdagent did not answer the client's cancellation, so a
cancelled transfer keeps its slot until the connection ends. The MJPEG retry's
id reuse is fixed and unit-tested but not reproduced, since the fixture cannot
fall back from H.264.

## Reproduce

Run `make test`, `make test-vendor`, `make simulate`, then `make build`.
Simulation keys and tickets are generated in temporary directories and removed;
there are no persistent fixture private keys or real credentials in this project.
See [README](../../README.md) and [review](review.md).
