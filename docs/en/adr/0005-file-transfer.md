# ADR-0005: Host-to-guest file transfer by dropping files on a session window

| Field | Value |
|-------|-------|
| Status | Proposed |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | The live peer gate could not verify file transfer because the application never implemented it; the user asked for the feature |

## Context

SwiftSpice implements the vdagent file-transfer protocol — `sendFile(at:name:)`,
`cancelFileTransfer(_:)`, and a `fileTransferEvents` stream with queued,
awaiting-guest-approval, progress, completed, cancelled and failed cases — and
the application wires none of it up. `Sources/` contains no reference to it, and
both READMEs list file transfer as out of scope.

Two properties of the protocol shape this design. It is **push-only**: the client
sends files to the guest's agent, and there is no guest-to-host direction, so
nothing the guest does can create a file on this machine. And the guest decides
where a received file lands; the client names the file and supplies its bytes.

The backend already enforces the bounds worth having: the source must be a
regular file (directories and devices are refused, and no directory is ever
scanned), at most four transfers run at once, a file is at most 8 GiB, and the
wire chunk is 16 KB.

## Decision

### 1. One entry path: drop onto a connected session window

Dropping files on a session window transfers them to that session's guest. The
drag is the authorization. This is the gesture ADR-0001 R1 asked for in place of
inferred intent: it happens on this application's own window, it names the exact
files, and it cannot be produced by guest or portal content.

The launcher keeps its existing `.vv` drop, which starts a connection. A drop on
a session window is always a transfer, never a connection, including for a `.vv`
file: the window the operator dropped on says which of the two they meant.

A drop is refused, with a stated reason and without reading anything, when the
session is not connected, when the guest agent is unavailable, or when the guest
advertises that it does not accept files. Non-regular files are refused by the
backend and reported the same way.

There is no preference gate and no per-file confirmation. Unlike the clipboard,
which the guest can read passively and which therefore defaults off, nothing here
moves without a gesture that already names the files.

### 2. Lifetime and limits

`SessionController` owns a queue per session. Four transfers run at once, the
backend's limit; the rest wait and start as slots free, because dropping ten
files and having six refused is not a useful product. Each transfer is visible
in the session window with its name, its progress and a cancel control.

Disconnect cancels every transfer of that session. Cancellation is recorded
synchronously before transport closes, so a transfer in flight can never gate
shutdown; this is R7 applied to a second kind of pending work. A transfer is
bound to the session that started it: a queue entry from a closed session is
dropped, never sent on a later connection.

### 3. Privacy

The transfer list shows file names because the operator chose them. The
diagnostics summary does not: it gains `files_sent`, `files_failed` and
`bytes_sent`, counts only. ADR-0001 §6 excludes file paths from diagnostics, and
names are the same class of information.

### 4. Verification

The live peer gate gains a file-transfer test in the agent phase, driven through
the application's own path. The guest's `spice-vdagent` is started with
`--file-xfer-save-dir`, and a guest watcher logs
`FILE_TRANSFER_RECEIVED name=<name> bytes=<n> sha256=<digest>` for each file that
appears. The test sends a file of known content from a temporary directory and
records the name and digest in its receipt; the gate requires a matching guest
line, so a passing test means the guest holds the same bytes. Refusals — no
agent, a directory, a session that is not connected — are unit-tested, since they
need no peer.

## Consequences

- The application gains its first feature that sends the operator's own data to
  the guest. The gesture is the authorization, and the boundary is narrow: named
  regular files, one session, cancelled on disconnect.
- The live gate now covers every feature the application has except the Ravada
  portal, which stays on simulation, and H.264, which needs a codec the fixture
  cannot produce.
- A dropped `.vv` file on a session window now means "send this to the guest",
  which differs from the launcher. The window is the disambiguator; the READMEs
  say so.
- Nothing about the guest's own file-transfer policy is controlled from here. A
  guest that refuses, or saves somewhere unexpected, is reported, not overridden.

## Alternatives considered

1. **A menu item with a file picker.** A second entry path for the same
   operation, with a modal in front of it. Drag is the natural gesture for
   "put this in that window", and the picker can follow later if asked for.
2. **A confirmation sheet per drop.** The drag already names the files on this
   application's own window; a sheet would add a click without adding a
   decision, and ADR-0001 reserves confirmation for starting a connection.
3. **A preference, off by default, like the clipboard.** The clipboard defaults
   off because the guest can read it without the operator acting. Here nothing
   moves without a gesture, so a preference would only add a way for the feature
   to silently do nothing.
4. **Refuse files beyond the concurrency limit.** Simpler, and wrong for the
   common case of dropping a folder's worth of files.
5. **Guest-to-host transfer.** Not part of the vdagent protocol; it would need
   WebDAV sharing, which ADR-0001 excludes.

## References

- [ADR-0001](0001-native-client-port.md) R1 (a gesture on our own window, not
  inferred intent), R7 (pending work never gates shutdown), §6 (diagnostics
  exclude paths), §7 (WebDAV out of scope).
- [ADR-0003](0003-agent-guest.md), whose agent guest and gate this extends.
- `Vendor/SwiftSpice/Sources/SwiftSpice/SpiceFileTransfer.swift` and
  `sendFile(at:name:)`, which state the push-only contract and the bounds.
