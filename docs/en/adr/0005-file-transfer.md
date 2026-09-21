# ADR-0005: Host-to-guest file transfer

| Field | Value |
|-------|-------|
| Status | **Accepted** — user approved implementation on 2026-09-18; revised the same day after the independent design verification pass (see the revision note) |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | The live peer gate could not verify file transfer because the application never implemented it; the user asked for the feature |

Revision note (2026-09-18). The verification pass rejected four load-bearing
parts of the first draft and corrected several claims. A `.vv` dropped on a
session window would have handed a live SPICE ticket to the guest; it is now
refused. Drag was the only entry path, but the pointer is captured and hidden
during a session, so there is nothing to drag with; a menu command was added.
The draft asserted that a transfer can never gate shutdown, which the dependency
contradicts; the wait is now bounded here and the dependency gap is recorded.
The draft cited a sentence in ADR-0001 that does not exist ("confirmation is
reserved for connections"); §1 now argues the question on its own. Also
corrected: transfers bind to a connection rather than to the session object,
several bounds are now set explicitly instead of inherited as defaults, and the
irreversibility of a delivered byte is stated rather than implied.

Second revision note (2026-09-18, after implementation). Building this against
the live peer contradicted two of the numbers above. The chunk is 4,000 bytes,
not 16,000, because the agent channel's token window is smaller than the
dependency's default assumes (§2). The guest watcher keys on modification time,
not size, because vdagent preallocates the file (§4). Three defects behind a
single symptom are recorded in the new §6, including one in a local patch this
repository already owned.

## Context

SwiftSpice implements the vdagent file-transfer protocol — `sendFile(at:name:)`,
`cancelFileTransfer(_:)`, and a `fileTransferEvents` stream — and the
application wires none of it up. `Sources/` contains no reference to it, and
both READMEs list file transfer as out of scope.

Two properties of the protocol shape this design. It is **push-only**: the
client sends files to the guest's agent, there is no guest-to-host direction,
and guest-originated `start`/`data` messages are rejected outright, so nothing
the guest sends can create a file on this machine. And the guest decides where a
received file lands; the client names the file and supplies its bytes.

The backend refuses anything that is not a regular file and never walks a
directory. Its other bounds — four concurrent transfers, 8 GiB per file, 16,000
bytes per chunk — are constructor defaults, not enforcement this application has
chosen, and the first draft mistook one for the other.

## Decision

### 1. Two entry paths, both explicit, and one refusal

**Dropping files on a connected session window** sends them to that session's
guest. **Session ▸ Send Files…** does the same through a picker, because the
pointer is captured and hidden while a session has input focus
(`CGAssociateMouseAndMouseCursorPosition(0)` and `NSCursor.hide()` in the
desktop view), which leaves nothing to drag with until the operator releases
capture. A feature reachable only in a state the operator has to know how to
leave is not reachable.

Either way the operator names the exact files on this application's own window.
That is the authorization. ADR-0001 requires native confirmation before a
*connection* starts, because there the intent was inferred from web navigation
metadata that page content could produce (R1). Nothing here is inferred: a drop
or a picker selection is an operator action on our window, of the same kind as
clicking Connect, and neither guest nor portal content can produce one. This
record decides that question for files; ADR-0001 does not speak to it.

**A `.vv` file is refused on a session window**, with a message saying to use
the launcher. A connection file carries a SPICE ticket, and ADR-0001 §2 forbids
displaying or persisting one; sending it to a guest would be worse than either.
The launcher keeps its `.vv` drop, which starts a connection. For every other
file the window the operator dropped on says what they meant.

A transfer is refused, with a stated reason and without reading anything, when
the session is not connected, when the guest agent is unavailable, or when the
guest has said it does not accept files. The decision is a pure function over
(urls, lifecycle phase, agent availability), so the same rule the drop handler
applies is the one the tests exercise.

**Delivered bytes cannot be recalled.** Cancelling, disconnecting or quitting
stops sending; it does not retract what the guest already has, and the guest
keeps whatever partial file it wrote. The transfer list says so.

### 2. Ownership, lifetime and bounds

Transfers belong to the **connection**, not to the session object. The MJPEG
retry path tears down the transport and builds a new `SpiceAgentManager` while
the `SessionController` survives; a queue owned by the controller would resume
on the next connection. Every transfer is therefore failed when its connection
ends, and the event subscription is re-established with the new agent.

Four transfers run at once and the rest wait, because dropping a folder's worth
of files and having the surplus refused is not a useful product. That bound, the
8 GiB per file and the 4,000-byte chunk are passed to `SpiceAgentManager`
explicitly, so they are this application's numbers.

The chunk is small because the agent channel is token-flow-controlled and the
dependency's 16,000-byte default does not fit the window QEMU grants. Each
message costs one token per 2 KiB wire fragment; QEMU grants ten tokens and
returns them five at a time, so a 16,000-byte chunk needs eight and the second
one blocks at seven, for ever. This was measured, not reasoned about: the first
implementation stalled every transfer at exactly 32,000 of 64,000 bytes.

**A transfer that stops making progress fails after 60 seconds.** Three
dependency behaviours make this necessary rather than decorative: a transfer
started before the guest's capabilities arrive sits in its initial phase with no
further event and no timeout; a cancellation waits for a guest reply that may
never come while still holding one of the four slots; and the event stream
buffers the newest 64 events, so a terminal event can be evicted when several
transfers interleave. The deadline is measured from the last observed progress,
so a slow but live transfer is not killed.

**Shutdown is bounded here.** `SpiceAgentManager.stop()` drains active
operations without a deadline, and a `sendFile` holds one across blocking reads
in uncancellable detached tasks, so a source on a stalled mount can block quit
indefinitely. The session cancels its transfers first, then waits for the agent
with a deadline and proceeds regardless — R7's rule that pending work never
gates shutdown, applied where the dependency does not enforce it. The dependency
gap is recorded here rather than masked, as ADR-0001 §6 requires; bounding the
drain upstream would be a third local patch and is not part of this decision.

### 3. What is shown, and what is recorded

The window shows one row per drop, not one per file: a count, aggregate
progress, and a cancel that stops the whole drop. Failures are named
individually underneath, because "3 of 40 failed" without names is not
actionable. Forty rows over a video surface is the case the organization's
own GUI notes warn about.

The transfer list shows file names, which the operator chose. The diagnostics
summary does not: it gains `files_sent`, `files_failed` and `bytes_sent`,
counts only, consistent with ADR-0001 §6 excluding paths. Counts are derived
from the transfer list's own states rather than incremented on events, so an
evicted event cannot corrupt them. A failure the guest raises for an id we never
issued is counted separately and never attributed to a transfer.

### 4. Verification

- The refusal rules are a pure function with unit tests: not connected, no
  agent, guest refuses, a directory, a `.vv`, an empty drop.
- The live peer gate's agent phase gains a transfer test driven through the
  application's own path, which calls the same decision function the drop
  handler calls. It sends a file of known content from a temporary directory and
  records `file <name> <sha256>` in its receipt.
- The guest's `spice-vdagent` runs with `--file-xfer-save-dir` pointing at a
  directory this init owns, and a watcher reports
  `FILE_TRANSFER_RECEIVED name=<name> bytes=<n> sha256=<digest>` once a file's
  **modification time** has been stable for two seconds, with a hard deadline
  that always produces a line, because vdagent writes the file as chunks arrive
  and a poller that hashes on sight hashes a partial file. Size stability, which
  the first implementation used, proves nothing: vdagent allocates the full size
  before the first byte arrives, so every partial file already has its final
  size. The watcher also emits `FILE_TRANSFER_REMOVED` when the agent deletes
  the file, so a vanished file is a reported outcome rather than silence.
- The gate matches the receipt against that line, so a pass means the guest
  holds the same bytes. `live_peer_agent_log_matches` gains the three-field
  form; its existing walk skips any line that is not exactly two fields, which
  would have made this check silently vacuous. The three-field form searches the
  whole log and does not advance the cursor the two-field form walks, because
  the guest reports a file only after its modification time settles, seconds
  after the markers that follow it.

### 5. Known limits, stated rather than implied

- The backend stats the source by path and then opens it by path, without
  `O_NOFOLLOW` and without re-checking the descriptor, so a symlink is followed
  and a path swapped between the two is opened unchecked. The application
  validates the drop before handing the URL over, but does not hold the
  descriptor, so this is the dependency's boundary, weaker than the one the
  `.vv` reader applies to its own input.
- A file edited while it is being sent delivers a mix of old and new bytes: the
  size is fixed when the transfer starts and the content is read in chunks as it
  goes. Truncation surfaces as a read failure; growth is ignored.
- Cancellation is sent to the guest — the dependency sends a `CANCELLED` status —
  but spice-vdagent did not answer it in the live gate (2026-09-22), so the
  guest decides what to do with the partial file it holds, and the dependency
  keeps the job and its slot until the connection ends (§7).

### 6. Three defects found by building it, and where each was fixed

Every transfer stalled at exactly 32,000 of 64,000 bytes. Three independent
causes sat behind that one symptom, and the first two hid the third.

- **Our own ADR-0001 patch was wrong.** The clipboard boundary returned early
  when access was denied, skipping the file-transfer and display-configuration
  drives at the end of the same method. That method is the only periodic path
  while automatic pasteboard synchronization is on, so a session with the
  clipboard off never drove a transfer forward on a timer. The patch was
  widened; a local patch is a change we own, and it was two ADRs old.
- **The dependency's drive is not re-entrant.** Each pass reads a job, awaits a
  read and a send, then commits only if the entry is still what it read. Two
  passes interleaving at those awaits invalidate each other, so neither commits
  and the same offset is re-sent for ever, which the guest rejects as duplicate
  data. Concurrent callers are ordinary here: the pasteboard poll drives
  transfers every 250 ms and so does every inbound agent message. Serialised in
  a third local patch (`Vendor/file-transfer-drive.patch`) rather than worked
  around in the application, because no caller can avoid the race from outside.
- **The chunk size did not fit the token window**, as §2 records. This was the
  root cause; the two above had to be fixed before it was visible at all.

The lesson that generalises: a stall at a round number is a window, not a bug in
the byte handling, and a local patch is part of the system under test.

`Vendor/*.patch` is now replayed against the pinned upstream by
`make verify-vendor`, which fails if the recorded patches no longer compose the
vendored tree. `check-project.py` pins every vendored file and every patch by
hash, so it catches an unrecorded edit; it cannot tell whether the patches still
describe that edit, and after this work there are three of them.

### 7. Amendment (2026-09-22): who owns a slot, and what a stall is

An audit suspected three defects; two were reproduced against the live peer
before anything changed, and all three are fixed in the application, without a
fourth vendored patch.

- **A queued file was timed out.** The 60-second rule of §2 measured every
  unfinished item from its last change, and a queued item's last change was its
  creation. With the first four transfers taking longer than the timeout, the
  fifth and sixth failed as "stalled" without being sent (reproduced with six
  1 MB files and the timeout shortened to 2 s). Only a file being sent can
  stall now.
- **A cancel stranded the queue.** The application finished a cancelled row and
  freed its slot at once; the dependency keeps the job until the guest answers,
  which it did not. The next start hit the dependency's limit and failed with
  "maximum concurrent file transfers reached" (reproduced). A finished item now
  holds its slot until the dependency reports the job ended, a refusal on that
  limit returns the file to the queue, and a stalled transfer is cancelled in
  the dependency too. §2's "the deadline is the fix" was wrong: the watchdog
  never freed a dependency slot.
- **The MJPEG retry reused ids.** Its new agent numbers transfers from 1 while
  the old rows kept theirs, so a new transfer's events landed on an old row.
  A connection that ends now makes every row forget its backend id and slot.
  Not reproduced: the fixture cannot fall back from H.264 (verification.md).

The rules are pure (`FileTransferRules`) and unit-tested; the live gate adds
`sendsMoreFilesThanSlotsAndNoneWaitingIsFailedAsStalled` and
`cancellingOneTransferLeavesTheQueueMoving`, and records whether the guest
answered the cancellation (`cancel-ack`, "none" on 2026-09-22). Consequence: a
cancelled transfer costs one of the four slots for the rest of the connection.

## Consequences

- The application can send the operator's files to a guest. It already sends
  clipboard text, so this is a second path for the operator's data, not the
  first; it differs in that a file leaves a name and contents on the guest's
  disk.
- The live gate now covers every feature the application has except the Ravada
  portal, which stays on simulation, and H.264, which needs a codec the fixture
  cannot produce.
- A `.vv` now behaves differently on the two windows: connection on the
  launcher, refusal on a session. Both READMEs say so.
- The shutdown bound is the application's, not the dependency's. If a future
  upstream makes its drain cancellable, this deadline should be revisited with
  the pin upgrade.

## Alternatives considered

1. **Drag only.** The first draft. Unreachable while the pointer is captured,
   which is the normal state of a session in use.
2. **Menu only.** Reachable, but it makes the obvious gesture do nothing, and
   the launcher already teaches that dropping a file on a window means
   something.
3. **A confirmation sheet per drop.** The gesture already names the files on our
   own window; a sheet would add a click without adding a decision. The one case
   where the stakes justify refusing outright, a `.vv`, is refused instead.
4. **A preference, off by default, like the clipboard.** The clipboard defaults
   off because the guest can read it without the operator acting. Here nothing
   moves without a gesture, so a preference would mostly be a way for the
   feature to silently do nothing.
5. **Refusing files beyond the concurrency limit.** Simpler, and wrong for the
   common case of dropping many files at once.
6. **Guest-to-host transfer.** Not part of the vdagent protocol; it would need
   WebDAV sharing, which ADR-0001's consequences exclude.

## References

- [ADR-0001](0001-native-client-port.md): R1 (authorization is not inferred from
  metadata), R7 and §6 (pending work never gates shutdown; record a dependency
  gap rather than masking it; diagnostics exclude paths), §2 (never display or
  persist a ticket), §5 (read a selected file once under a size bound).
- [ADR-0003](0003-agent-guest.md), whose agent guest and gate this extends.
- `Vendor/SwiftSpice/Sources/SwiftSpice/SpiceFileTransfer.swift` and
  `sendFile(at:name:)`: the push-only contract, the phases, and the bounds.
- Knowledge that constrains this design:
  [security](https://github.com/nlink-jp/knowledge/blob/main/docs/en/security.md)
  on checking a path and then opening it again;
  [macOS GUI](https://github.com/nlink-jp/knowledge/blob/main/docs/en/macos-gui.md)
  on one drop meaning one progress report, and on drags that carry promises
  rather than file URLs;
  [testing](https://github.com/nlink-jp/knowledge/blob/main/docs/en/testing.md)
  on a gate that never drives the surface the rule lives on.
