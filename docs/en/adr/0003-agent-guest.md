# ADR-0003: Agent guest for the live peer gate — clipboard and resize against a real spice-vdagent

| Field | Value |
|-------|-------|
| Status | Proposed |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | ADR-0002 left the clipboard broker and the resize path, the parts of this application that differ most from the reference, verified only against simulation |

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
  (9 frames in 10 s) instead of the console tick's tens per second.

## Decision

### 1. One guest, layered init

The agent guest replaces the minimal guest of ADR-0002 rather than being added
beside it. `Integration/LivePeer/guest/build-in-container.sh` builds it with
`apk --root --initdb` from `https://dl-cdn.alpinelinux.org/alpine` (never the
third-party mirror the upstream script defaults to), takes the kernel from the
same `linux-virt` package, prunes the module tree as before plus keeps `uinput`,
and records every installed package in `guest.json`.

`guest/init` is layered so that a broken Xorg fails only the agent tests:

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
   `spice-client guest clipboard <token>` and logs `CLIPBOARD_OFFERED <token>`.
   An xrandr loop applies the preferred mode of `Virtual-1` whenever it
   changes and logs `XRANDR_MODE WxH`.

`run.sh` waits for `GUEST monitoring` lines as before and then for
`AGENT_STACK_STARTED` (bounded; `AGENT_ERROR` fails the run), settles 5 s, and
adds `SPICE_CLIENT_LIVE_PEER_AGENT=1` to the environment file. The QEMU
command gains `-m 2048` and the container `--memory 3g` for the larger
initramfs.

### 2. What the agent tests assert

`Tests/SpiceClientTests/LiveAgentTests.swift`, enabled by
`SPICE_CLIENT_LIVE_PEER_AGENT`, drives `SessionController` with an injected
`ClipboardBroker(read:write:)` over an in-memory pasteboard; the operator's
`NSPasteboard` is never read or written (with an injected access the vendored
patch never falls back to `SpicePasteboardBridge`).

- **Host to guest follows sharing and focus.** With sharing on and the session
  focused, a new host text `spice-client host clipboard <token>` is logged by
  the guest with its SHA-256 within 10 s. With sharing off, a second token is
  not logged within 5 s. With sharing on again, a third is. With focus
  resigned, a fourth is not; with focus regained, a fifth is.
- **Guest to host follows sharing.** The guest's answer to a delivered token
  arrives in the in-memory pasteboard as `spice-client guest clipboard <token>`
  within 10 s; no answer arrives for a token that sharing off withheld.
- **Resize reaches Xorg.** Once `resizingAvailable` is true, `resize(width:
  1024, height: 768)` produces `XRANDR_MODE 1024x768` in the guest log within
  15 s, and `resize(width: 1280, height: 800)` produces `XRANDR_MODE 1280x800`.
- The diagnostics summary contains neither the tokens nor the host.

`LivePeerTests` (transport, TLS) run unchanged against the same guest; the
frame assertion (at least one revision within 30 s) holds on the static
desktop. The gate requires the receipts of all eight tests. What one session
cannot prove, guest-to-guest relay between two sessions, stays with the unit
tests of the broker.

### 3. Provenance and limits

As in ADR-0002: both images digest-pinned, packages recorded not pinned,
`guest.json` lists the installed agent packages, the pass record embeds it.
Not covered: audio, H.264, the Ravada portal, file transfer, a desktop
environment's own clipboard managers, and USB.

## Consequences

- The clipboard broker and the resize path are verified against a real
  `spice-vdagent 0.22`, including the two revocation edges (sharing off, focus
  lost) at the boundary where the reference client leaked.
- The guest artifact grows from 8 MB to about 113 MB and boots in 7 s instead
  of 4 s on this host; Xorg joins the moving parts, contained by the layered
  init. The gate takes roughly the same wall-clock time plus the settle.
- The live frame stream becomes a static desktop; the frame assertion keeps
  its threshold of one revision, and the console-tick measurement from
  ADR-0002 is superseded.

## Alternatives considered

1. **Two guests, minimal plus agent** — keeps the rich frame stream and a
   transport-only gate when Xorg breaks, at the price of two artifact sets and
   two boots per gate. The layered init gives the same isolation with one boot.
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
