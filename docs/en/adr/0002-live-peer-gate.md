# ADR-0002: Live peer gate — QEMU with a real spice-server under Podman (TCG)

| Field | Value |
|-------|-------|
| Status | Proposed |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | v0.1.0 shipped on loopback simulation only; no QEMU/Ravada peer exists and the build host cannot run the upstream nested-virtualization harness |

## Context

Every SPICE-facing check so far runs against `scripts/simulate.py`, a fake peer
that speaks enough of the wire protocol to bootstrap a session. It cannot show
that a real spice-server accepts this client's handshake and ticket, that real
display frames reach the Metal path, or that injected input arrives inside a
real guest. The [verification record](../verification.md) says so, and the
user chose to release v0.1.0 with that gap open.

SwiftSpice ships a live harness (`Vendor/SwiftSpice/Integration/AppleContainer`)
that boots a nested QEMU guest with KVM inside Apple/container. It needs nested
virtualization (M3 or newer); the build host is an Apple M2 Max, and the local
Podman machine (`podman 6.1.2`, applehv, 6 CPUs, 7.45 GiB) exposes no
`/dev/kvm`. The upstream remote fixture (`Integration/RemoteRocky`) needs a Linux
host with KVM that does not exist here.

Measured on 2026-09-18 (scratch spike, not committed):

- The upstream `Containerfile` (`ubuntu:24.04` + `qemu-system-arm` +
  `qemu-system-modules-spice`) builds and runs under Podman: QEMU 8.2.2
  (`1:8.2.2+ds-0ubuntu1.18`) with `libspice-server1 0.15.1`, the
  `ui-spice-core`, `chardev-spice` and `audio-spice` modules, and `tcg` listed
  as an accelerator.
- A guest built in an `alpine:3.22` container from the `linux-virt` package
  (kernel `6.12.110-0-virt`, 9.6 MB) plus a pruned module tree (3.6 MB;
  `virtio-gpu`, `virtio_input`, `evdev`, `drm`) and Alpine's own userland as an
  8.4 MB initramfs reached its init markers 4 s after `podman run` in both of
  two boots. `virtio_pci` and `virtio_console` are built in.
- `spice-probe` (upstream, built from the vendored package) connected through
  the published port with a ticket, and reported `frames=113` in an 8 s window
  and `frames=90` in a 6 s window, `cursors=1`, `keyboard=1`, `motion-acks=2`,
  `gpu-errors=0`. The frames are the guest's own console writes to `tty0`
  drawn by the virtio-gpu framebuffer.
- After `evdev` was added to the guest, the guest's raw event dump contained
  the injected A key (`01 00 1e 00 01 00 00 00`).

A native QEMU on macOS is not an option: the Homebrew `qemu` formula (11.1.1)
has no spice dependency, so it carries no spice-server backend.

## Decision

### 1. Placement and components

Add `Integration/LivePeer/` to this repository:

- `Containerfile` — `ubuntu:24.04` pinned by digest, `qemu-system-arm` and
  `qemu-system-modules-spice` only.
- `build-guest.sh` — runs inside `alpine:3.22` pinned by digest; installs
  `linux-virt`, prunes the module tree to virtio, DRM, input and their
  dependencies, adds `guest/init`, and writes `Artifacts/vmlinuz-virt`,
  `Artifacts/initramfs.cpio.gz` and `Artifacts/guest.json` (kernel version,
  base image digest, SHA-256 of both artifacts). `Artifacts/` is ignored by git.
- `guest/init` — this project's init, derived from the upstream MIT init
  (attributed in `NOTICE.md`): mounts, `modprobe`, a console tick on `tty0`
  so the display keeps changing, and a raw dump of every `/dev/input/event*`
  as hex lines.
- `run.sh` / `stop.sh` — start one detached container per run with `--rm`,
  `--cpus` and `--memory` caps, the guest artifacts mounted read-only, the
  SPICE port published on `127.0.0.1` only, and a per-run random ticket
  passed to QEMU as a secret object; wait for the listener and the guest
  marker; print the port and ticket as environment for the test. `stop.sh`
  is idempotent and is also the trap handler.
- `make live-peer` — builds the image and guest when missing, starts the
  peer, runs `swift test --filter LivePeerTests` with the environment,
  requires the guest log to contain the injected key, and always stops the
  container. `make live-peer-clean` removes the image and artifacts.

### 2. What the gate asserts

`Tests/SpiceClientTests/LivePeerTests.swift` is enabled only when
`SPICE_CLIENT_LIVE_PEER_PORT` is set and drives the application's own code
path, `ConnectionPlan` → `SessionController` → SwiftSpice, not the probe:

- A generated `.vv` (host `127.0.0.1`, the port, the ticket) parses, the
  session reaches `connected`, `inputAvailable` is true, `desktop` is present,
  and the diagnostics counter `frames_presented` grows within a bounded wait.
- The test submits key A down and up; the host side requires
  `01 00 1e 00 01 00 00 00` in the guest log after the test.
- A wrong ticket ends in `failure == .authentication` and `closed` against
  the real server, and the peer stays up for the next connection.
- `disconnect()` reaches `closed` within the existing shutdown bound, and a
  second session to the same peer connects afterwards.
- The diagnostics summary never contains the ticket or the host.

Audio, H.264, the Ravada portal, and the guest agent (clipboard, resize) are
not asserted by this gate. Phase 1b adds a TLS listener (`tls-port` with a CA
generated at container start and exported read-only) so the `.vv` CA path is
exercised against a real server. Phase 2, the agent guest (Xorg and
`spice-vdagent` from Alpine packages, as upstream does), is a separate
decision once phase 1 has run for a release.

### 3. Provenance

Both base images are pinned by digest in the files that use them, and
`check-project.py` requires every `FROM` line under `Integration/` to carry
`@sha256:`. The kernel version floats with Alpine 3.22's `linux-virt`; the
build records what it produced in `Artifacts/guest.json` and the gate prints
it, so any result can be tied to a kernel. No artifact is committed and no
image is pushed to a registry.

### 4. Operation and safety

The container mounts only the artifact directory, read-only, publishes only on
loopback, and dies with the run (`--rm`, trap-based stop, and a QEMU
`-no-reboot`); a stale container of the same name is removed before start so
an interrupted run cannot leave an orphaned QEMU burning CPU. The ticket lives
in the process environment of one run and is never written under the
repository. Inside the container QEMU binds `0.0.0.0`, which is required by
the Podman machine's port forwarding and is not reachable from outside the
host.

The gate is not part of `make test`: it needs Podman and roughly a minute of
CPU. It runs before a release and its result goes into the verification record
alongside the simulation results.

## Consequences

- A real spice-server and a real Linux guest replace the fake peer for the
  transport, ticket, display, cursor, input and shutdown paths. The
  interoperability claim in the README changes from "unverified" to "verified
  against QEMU 8.2 / spice-server 0.15 with a minimal guest", which is still
  not a Ravada or a desktop guest.
- Podman becomes an optional development dependency for this gate only.
  TCG is fast enough for this guest (4 s to markers; frame rate in the tens
  per second) and needs no hardware support, so the gate runs on any Apple
  silicon host with Podman.
- The guest artifacts are rebuilt on demand (about 18 MB) and are not part of
  the repository or the release.
- The clipboard broker and resize path, the parts of this application that
  differ most from the reference, stay simulation-only until phase 2.

## Alternatives considered

1. **Upstream Apple/container harness** — needs nested virtualization (M3 or
   newer) and Apple/container; the build host cannot run it. Its guest images
   and scripts are reused where they apply.
2. **Remote Linux host with KVM** (upstream `RemoteRocky` fixture) — no such
   host exists; adding one is infrastructure, not a test.
3. **Native QEMU on macOS** — the Homebrew formula has no spice-server
   backend, and no packaged macOS spice-server exists.
4. **UTM or another desktop hypervisor** — bundles SPICE for its own display
   over a Unix socket; exposing a TCP listener needs custom arguments and
   competes with the app's own server. Not measured; rejected as a gate
   because it is manual and machine-specific.
5. **Keep simulation only** — the status quo; it cannot answer whether a real
   server accepts this client.

## References

- [ADR-0001](0001-native-client-port.md) §8 milestone 6 (real peers) and the
  [verification record](../verification.md).
- [SwiftSpice Apple/container guide](../../../Vendor/SwiftSpice/Integration/AppleContainer/APPLE_CONTAINER.md)
  and its guest init, reused under MIT.
- [Testing](https://github.com/nlink-jp/knowledge/blob/main/docs/en/testing.md):
  all-green unit tests still need real-data E2E; a gate that only runs by hand
  needs a test of its own; before calling something measured, ask whether the
  probe input represents the real thing.
- [Containers and infrastructure](https://github.com/nlink-jp/knowledge/blob/main/docs/en/containers-and-infra.md):
  Podman machine binds `0.0.0.0` inside, forwards published ports on the host.
- pcap-analyzer-mcp ADR-0003: digest-pinned base image with a drift test, the
  organization's precedent for a Podman runtime.
