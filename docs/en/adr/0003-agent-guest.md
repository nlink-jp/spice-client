# ADR-0003: Agent guest for the live peer gate — clipboard and resize against a real spice-vdagent

| Field | Value |
|-------|-------|
| Status | **Accepted** — user approved on 2026-09-18; revised the same day after the independent design verification pass (see the revision note) |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | ADR-0002 left the clipboard broker and the resize path, the parts of this application that differ most from the reference, verified only against simulation |

Revision note (2026-09-18): the design verification pass found that a withheld host
text would be offered as soon as sharing resumed, that timing windows made the
negative assertions racy, that the second resize on one agent connection is
reply-gated in the backend while virtio-gpu never replies, that the layered init and
a run that fails on `AGENT_ERROR` contradicted each other, and that the gate's new
logic had no self-test. §1–§2 are the revised text. ADR-0002 said phase 2 would wait
for a release of phase 1; the user chose to proceed the same day, before that release.

## Context

ADR-0002's live peer runs a minimal Alpine guest with no agent, so it cannot
exercise the two boundaries ADR-0001 redesigned: the host clipboard authority
(sharing off by default, only the focused session, revocation at the actual
access) and the viewport-driven resize. Both talk to the guest's `spice-vdagent`
through the agent channel, and the loopback simulation has no agent.

SwiftSpice's Apple/container harness carries an agent guest: an Alpine rootfs
with `dbus`, `spice-vdagent`, `xclip`, `xorg-server` (the built-in modesetting
driver on `/dev/dri/card0`) and `xrandr`, an init that starts the stack and
reports fixed clipboard and layout fixtures, and a probe that consumes them.

Measured on 2026-09-18 (scratch spike, not committed), on the ADR-0002 image
and Podman machine, with the same `linux-virt` kernel:

- An agent rootfs built with `apk --root --initdb` from the official Alpine
  3.22 CDN (`alpine-base`, `dbus`, `spice-vdagent 0.22.1`, `xclip`,
  `xorg-server 21.1.19`, `xrandr`, `linux-virt`) is 315 MB and packs into a
  113 MB initramfs. The guest reached `AGENT_STACK_STARTED` (Xorg up,
  `spice-vdagentd` and `spice-vdagent` connected, resolution 1280x800
  reported) 7 s after `podman run` in both of two boots.
- `spice-vdagentd` exits with `Fatal uinput error` when `/dev/uinput` is
  absent. The Alpine virt kernel ships `uinput` as a module; loading it in init
  fixed the agent connection. The busybox `mdev.conf` in `alpine-base` already
  creates `/dev/virtio-ports/com.redhat.spice.0`.
- After a 5 s settle, the upstream probe with `--require-agent
  --exercise-clipboard --exercise-monitor-config` passed: the guest logged the
  host clipboard fixture (26 bytes, expected SHA-256), offered its own text
  which the probe verified as a round trip, and applied the requested
  two-monitor layout (800x600 + 640x480, `XRANDR_DUAL_MONITOR_COMPLETE`).
  With Xorg owning the display the frame stream is a static desktop
  (9 frames in 10 s, one run) instead of the console tick's tens per second.
- The guest's screen size does not come back to the client. With the guest
  applying `xrandr --fb 800x600 --output Virtual-1 --mode 800x600` and its own
  `xrandr --query` reporting an 800x600 screen, every frame the client received
  stayed 1280x800: under `virtio-gpu-pci`, QEMU 8.2's SPICE backend does not
  republish the primary surface at the guest's new screen size. QXL, where this
  works, is not a device `qemu-system-aarch64` offers (only `virtio-gpu-pci`
  and `bochs-display`). The upstream harness asserts the same thing guest-side,
  through `xrandr --query`, and never on the client's surface.

## Decision

### 1. One guest, layered init

The agent guest replaces the minimal guest of ADR-0002 rather than being added
beside it. `Integration/LivePeer/guest/build-in-container.sh` builds it with
`apk --root --initdb` from the `main` and `community` repositories of
`https://dl-cdn.alpinelinux.org/alpine` (never the third-party mirror the
upstream script defaults to; `spice-vdagent`, `xorg-server` and `xclip` live in
`community`), with package signatures checked against the pinned image's
`/etc/apk/keys`. It takes the kernel from the same `linux-virt` package, prunes
the module tree as before plus keeps `uinput`, and records every installed
package and the SHA-256 of the init and of itself in `guest.json`, so the gate
rebuilds the guest whenever either source changes.

`guest/init` is layered so that a broken Xorg leaves the transport tests running
and the failure attributable to the agent layer; the gate still fails closed,
on the missing agent receipts:

1. Base: mounts, `modprobe` (`virtio_gpu`, `virtio_input`, `evdev`, `uinput`,
   `drm`), `mdev -s`, the input-event dump, then `GUEST ready` and
   `GUEST monitoring …` exactly as today; the console tick is dropped because
   Xorg owns the display.
2. Agent: `dbus-daemon`, `spice-vdagentd`, Xorg with the modesetting config,
   `spice-vdagent`, then `AGENT_STACK_STARTED`, or `AGENT_ERROR <reason>` on
   any step's timeout without stopping the base loops.
3. Observers: a clipboard loop reads the X clipboard twice a second and logs
   `CLIPBOARD_OBSERVED bytes=N sha256=…` on every change; when the text has
   the form `spice-client host clipboard <token>` it answers by offering
   `spice-client guest clipboard <token>` through an `xclip` that keeps the
   selection until another owner takes it (no `-loops`, so the observer's own
   reads cannot consume the offer before the client's request) and logs
   `CLIPBOARD_OFFERED <token>`; a read that finds no owner after text logs
   `CLIPBOARD_CLEARED`.
   An xrandr loop applies the preferred mode of `Virtual-1` whenever it
   changes and logs `XRANDR_MODE WxH`.

`run.sh` waits for `GUEST monitoring` lines as before and then, bounded, for
`AGENT_STACK_STARTED`; on `AGENT_ERROR` or the bound it reports and continues
with `SPICE_CLIENT_LIVE_PEER_AGENT=0`, otherwise it settles 5 s and writes
`SPICE_CLIENT_LIVE_PEER_AGENT=1`. `gate.sh` runs both suites, requires all
eight receipts, and checks the agent receipt against the guest log in order.
The QEMU command gains `-m 2048` and the container `--memory 3g` for the
larger initramfs.

### 2. What the agent tests assert

`Tests/SpiceClientTests/LiveAgentTests.swift`, enabled by
`SPICE_CLIENT_LIVE_PEER_AGENT`, drives `SessionController` with an injected
`ClipboardBroker(read:write:)` over an in-memory pasteboard; the operator's
`NSPasteboard` is never read or written (with an injected access the vendored
patch never falls back to `SpicePasteboardBridge`).

- **Host to guest and back, ordered, not timed.** With sharing on and the
  session focused, a host text `spice-client host clipboard <a>` is answered
  by the guest, and the answer reaches the in-memory pasteboard through the
  broker's write. The test then turns sharing off, sets a withheld text `<b>`,
  sets a newer text `<c>` and turns sharing on again in the same MainActor
  turn: revocation is synchronous, so no poll can read `<b>`, and resuming
  offers the current pasteboard, as ADR-0001 intends, which is `<c>`. The
  same sequence runs for focus resigned and regained with `<d>` and `<e>`. The
  test records `delivered`/`withheld` tokens and the measured latencies in its
  receipt; the gate walks the receipt against the guest log in order and
  requires each delivered token's SHA-256 after the previous match and each
  withheld token's SHA-256 nowhere. The withheld texts are never announced, so
  the negatives do not depend on timing. The client's release itself is not
  observable on the guest side in this sequence, because the guest holds the
  selection with its own answer by then; the vendored patch's regression test
  covers the release message.
- **Resize reaches the guest, twice on one agent connection.** Once
  `resizingAvailable` is true, `resize(width: 1024, height: 768)` and then,
  after a spacing wait, `resize(width: 1280, height: 800)` must each be applied
  by the guest: the gate requires `XRANDR_MODE 1024x768` and then
  `XRANDR_MODE 1280x800` in that order, so the mode the guest booted with
  cannot satisfy the second request. The client cannot observe the outcome
  itself, for the virtio-gpu reason in the Context above; the guest log is the
  observation, as it already is for the injected key. The second request is the
  one that matters: nothing acknowledges a monitors configuration under
  virtio-gpu, so a reply-gated sender would stall there. The spacing wait is
  fail-closed, since too short a wait fails the ordered check rather than
  passing it.
- **R7.** The clipboard test closes its session while the guest holds the X
  selection with its last answer; `closed` must arrive within the existing bound.
- The diagnostics summary contains neither the tokens nor the host (a tripwire
  on a counters-only summary, not evidence).

`LivePeerTests` (transport, TLS) run unchanged against the same guest with the
shared broker, which never enables sharing, so the operator's pasteboard is
not read even now that the guest has an agent; the frame assertion (at least
one revision within 30 s) holds on the static desktop. The gate requires the
receipts of all eight tests. What one session cannot prove, guest-to-guest
relay between two sessions, stays with the unit tests of the broker.
`Tests/test_live_peer.py` covers the gate's new checks with fixtures: agent
status from a log, the ordered receipt walk including a withheld token that
leaked and a startup mode line that must not satisfy a later request, and the
rebuild trigger on changed guest sources.

### 3. Provenance and limits

As in ADR-0002: both images digest-pinned, packages recorded not pinned,
`guest.json` lists the installed agent packages, the pass record embeds it.
Not covered: audio, H.264, the Ravada portal, file transfer, a desktop
environment's own clipboard managers, and USB.

## Implementation notes (2026-09-18)

Three things the implementation measured that the design did not anticipate:

1. **One client at a time.** QEMU's SPICE server serves a single client, and
   `swift test` runs suites in parallel, so the transport suite and the agent
   suite fought over the one slot: connections failed and the frame observer
   starved. The gate runs them as two sequential `swift test` invocations.
2. **Two display heads crash QEMU.** With `max_outputs=2`, QEMU dumped core
   (exit 139) while the client connected and disconnected repeatedly with the
   agent present, on both `qemu-system-arm` 8.2.2 (Ubuntu 24.04) and 10.0.13
   (Debian 13), so it is not a version fix. With `max_outputs=1`, which is what
   this application presents anyway (ADR-0001 excludes multiple guest display
   streams), eleven consecutive runs kept the peer alive. This is almost
   certainly the unexplained peer exit recorded once during ADR-0002 phase 1b.
3. **The second resize was a product defect; fixed by [ADR-0004](0004-display-configuration-liveness.md)
   on 2026-09-18, and the gate's pin is now a positive assertion.** `resize` after the
   first one on an agent connection never reaches the guest:
   `SpiceDisplayConfigurationState.nextToSend` yields nothing while a
   configuration is in flight, and in flight is cleared only by
   `didReceiveReply`, an agent disconnect or `stop()`. Under virtio-gpu, QEMU
   consumes `VD_AGENT_MONITORS_CONFIG` in its own `client_monitors_config`
   handler and never replies, so the first resize latches the sender for the
   life of the agent connection while `resizingAvailable` stays true, which
   makes it silent for the operator. The fix belongs in the vendored backend,
   whose local patch ADR-0001 scoped to clipboard authorization only, so
   widening it was a separate decision, taken in ADR-0004: the send window now
   has a deadline, and the gate requires the second mode to be applied in order
   after the first.

Residual: one clipboard wait timed out at its 10 s bound once in eleven runs,
with the peer alive and no log kept. It has not recurred in ten consecutive
runs since; `SPICE_CLIENT_LIVE_PEER_KEEP_LOG=<path>` now keeps the whole guest
log so a recurrence carries evidence.

## Consequences

- The clipboard broker and the resize path are verified against a real
  `spice-vdagent 0.22`, including the two revocation edges (sharing off, focus
  lost) at the boundary where the reference client leaked.
- The guest artifact grows from 8 MB to about 113 MB and boots in 7 s instead
  of 4 s on this host; Xorg joins the moving parts, and the layered init keeps
  an Xorg failure attributable. The gate takes roughly the same wall-clock
  time plus the settle.
- The live frame stream becomes a static desktop; the frame assertion keeps
  its threshold of one revision, and the console-tick measurement from
  ADR-0002 is superseded.

## Alternatives considered

1. **Two guests, minimal plus agent** — keeps the rich frame stream and a
   transport-only pass when Xorg breaks, at the price of two artifact sets and
   two boots per gate. The layered init keeps the transport results and the
   attribution with one boot; the gate still fails, which is what a gate is for.
2. **Reuse the upstream agent init verbatim** — its fixed fixtures answer once
   and cannot express the revocation sequences the broker exists for.
3. **Exercise the agent through the upstream probe** — proves the server and
   guest, not this application's broker, focus rule or resize path.
4. **A desktop environment in the guest** — would exercise real clipboard
   managers, at several times the size and boot time; deferred.

## References

- [ADR-0001](0001-native-client-port.md) §2 (clipboard authority) and §4 R7;
  [ADR-0002](0002-live-peer-gate.md) phases 1 and 1b.
- Upstream agent guest: `Vendor/SwiftSpice/Integration/AppleContainer/guest/`
  (`agent-init`, `xorg.conf`, `build-agent-rootfs.sh`), reused under MIT.
- [Testing](https://github.com/nlink-jp/knowledge/blob/main/docs/en/testing.md):
  observe what the view observes; a gate proves its own execution.
