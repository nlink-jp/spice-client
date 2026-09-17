# ADR-0002: Live peer gate — QEMU with a real spice-server under Podman (TCG)

| Field | Value |
|-------|-------|
| Status | **Accepted** — user approved on 2026-09-18; revised the same day after the independent design verification pass (see the revision note) |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | v0.1.0 shipped on loopback simulation only; no QEMU/Ravada peer exists and the build host cannot run the upstream nested-virtualization harness |

Revision note (2026-09-18): the design verification pass found that `frames_presented`
counts Metal draws and stays zero in a headless test, that a key injected before the
guest monitors its input devices is lost, and that the gate had no proof of its own
execution; §1–§4 below are the revised text. The first gate run reproduced the frame
finding before the revision.

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
- `run.sh` / `stop.sh` — start one detached container per run (kept until
  `stop.sh` removes it, so a peer that dies mid-run leaves its exit status and
  log for the gate to report) with `--cpus` and `--memory` caps, the guest artifacts mounted read-only, the
  SPICE port published on `127.0.0.1` with an ephemeral host port read back
  from `podman port` (a forward retained by the Podman machine from an
  earlier run cannot be mistaken for this one), a per-run random ticket
  written to a `0600` file under `~/.cache/spice-client/live-peer/` and
  handed to QEMU as `secret,file=` rather than an argument, and QEMU under a
  30-minute `timeout`. Readiness waits, bounded to 120 s and abandoned if the
  container dies, for both `GUEST monitoring /dev/input/event*` lines (evdev
  does not buffer for readers that are not there yet) and for the published
  port. The port, ticket, ticket file and container name go to a temporary
  environment file for the test; `stop.sh` removes container and ticket file
  and is also the trap handler.
- `make live-peer` — builds the image and guest when missing, starts the
  peer, runs `swift test --filter LivePeerTests` with the same flags as
  `make test`, requires the suite's receipt (each test appends its name to a
  file named by `SPICE_CLIENT_LIVE_PEER_RECEIPT`; a suite disabled by its
  environment skips silently and `swift test` still exits 0), requires the
  guest log to contain the injected key, writes `Artifacts/last-pass.json`
  (commit, whether the tree was dirty, guest and image provenance), and
  always stops the container. `make package` runs `require-pass.sh` and
  refuses a release commit without a clean pass recorded for exactly that
  commit. `make live-peer-clean` removes the image and artifacts.
- `lib.sh` holds the three checks (guest log, receipt, pass record) as
  functions, and `Tests/test_live_peer.py` drives them with fixture files,
  checks that `run.sh` fails before touching Podman when artifacts are
  missing, parses every script, and checks the digest pin. These run in
  `make test` without Podman, so the gate's own logic is tested.

### 2. What the gate asserts

`Tests/SpiceClientTests/LivePeerTests.swift` is enabled only when
`SPICE_CLIENT_LIVE_PEER_PORT` is set and drives the application's own code
path, `ConnectionPlan` → `SessionController` → SwiftSpice, not the probe:

- A `.vv` text (host `127.0.0.1`, the port, the ticket) parsed in memory,
  never written to disk, connects: the session reaches `connected` and
  `inputAvailable` is true. Real display frames are observed the way a window
  would observe them: a visible subscription on the session's desktop source
  counts distinct frame revisions and must count at least one within 30 s.
  `SessionController`'s `frames_presented` counts Metal draws and is not used;
  it stays zero without a view.
- The test submits key A down and up after the guest reports monitoring
  both input devices; the host side requires `01 00 1e 00 01 00 00 00` in the
  guest log after the test.
- A wrong ticket ends in `failure == .authentication` and `closed` against
  the real server, and the peer stays up for the next connection.
- `disconnect()` reaches `closed` within the existing shutdown bound, and a
  second session to the same peer connects afterwards.
- The diagnostics summary never contains the ticket or the host.

Audio, H.264, the Ravada portal, and the guest agent (clipboard, resize) are
not asserted by this gate. Phase 1b (implemented 2026-09-18): the peer also
listens on `tls-port` with a per-run CA and server certificate generated on the
host by `lib.sh` and mounted read-only as QEMU's `x509-dir`; the gate connects
through the `.vv` `ca` path, through `ca` plus `host-subject`, and proves that a
decoy CA and a wrong subject are refused while the peer survives. Phase 2, the
agent guest, is [ADR-0003](0003-agent-guest.md) (2026-09-18): it replaced the
minimal guest of this record with one that also runs Xorg and `spice-vdagent`,
fetched from the official Alpine CDN, not the third-party mirror the upstream
script defaults to.

### 3. Provenance

Both base images are pinned by digest in the files that use them, and
`check-project.py` requires every `docker.io` reference under `Integration/`
to carry `@sha256:`. The packages above the base layers are not pinned:
`apt` and `apk` keep only the current version of a package in a stable
release, so a hard pin would break within weeks. They are recorded instead:
`Artifacts/image.json` holds the image id and the `qemu-system-arm`,
`qemu-system-modules-spice` and `libspice-server1` versions read from the
built image, `Artifacts/guest.json` the kernel package and the SHA-256 of
both guest artifacts, and every pass record embeds both, so any result can
be tied to the software it ran against. No artifact is committed and no
image is pushed to a registry.

### 4. Operation and safety

The container mounts only the artifact directory, the ticket file and the TLS
material, all read-only, publishes only on loopback, and is removed by the
trap-based stop (`-no-reboot` ends QEMU on a guest reboot). A trap does not
run on SIGKILL or host sleep, so two further bounds exist: QEMU runs under a 30-minute `timeout`,
and a stale container of the gate's name is removed at the next start. The
ticket lives in the ticket file and the environment file of one run, both
outside the repository and removed at stop; it does not appear in the
container's command line. Inside the container QEMU binds `0.0.0.0`, which the
Podman machine's port forwarding requires; the host-side publish is on
`127.0.0.1`, verified once against `lsof` on this host, and other containers
inside the machine VM could reach the port, which is out of this gate's threat
model.

The gate is not part of `make test`: it needs Podman and roughly a minute of
CPU. `make package` requires its pass record for the release commit, and the
result goes into the verification record alongside the simulation results.

## Consequences

- A real spice-server and a real Linux guest replace the fake peer for the
  transport, ticket, display, cursor, input and shutdown paths. The
  interoperability claim in the README changes from "unverified" to "verified
  against QEMU 8.2 / spice-server 0.15 with a minimal guest", which is still
  not a Ravada or a desktop guest.
- Podman becomes a development dependency for this gate and therefore for
  `make package`. TCG needs no hardware support; on this host the guest
  reached its markers in 4 s in two of two boots and delivered frames in the
  tens per second, and the test waits are ten times those observations. Other
  hosts are expected to work and have not been measured.
- The guest artifacts are rebuilt on demand (about 18 MB) and are not part of
  the repository or the release.
- The clipboard broker and resize path, the parts of this application that
  differ most from the reference, stayed simulation-only until ADR-0003.

## Alternatives considered

1. **Upstream Apple/container harness** — needs nested virtualization (M3 or
   newer) and Apple/container; the build host cannot run it. Only its guest
   init is reused, as a copy; its scripts are never invoked, because they
   write under `Vendor/`, whose file set `check-project.py` hash-checks.
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
