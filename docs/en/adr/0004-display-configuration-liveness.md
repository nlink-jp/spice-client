# ADR-0004: Widen the vendored patch to bound the monitors-configuration send window

| Field | Value |
|-------|-------|
| Status | **Accepted** — user approved on 2026-09-18 |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | The agent-guest gate (ADR-0003) showed that only the first resize of an agent connection reaches the guest |

## Context

ADR-0001 kept the local change to `Vendor/SwiftSpice` deliberately narrow: one
patch, clipboard authorization only, so that the dependency stays reviewable
against its pinned upstream. It also said that when the dependency's API cannot
meet a requirement, the need for a dependency change is to be recorded rather
than masked.

The live peer gate recorded exactly that. `DisplayConfigurationCoordinator`
keeps a send window of one: while a configuration is in flight only the latest
queued one is kept, and the window closes on `didReceiveReply`, on an agent
disconnect, or on `reset`. Under `virtio-gpu`, QEMU consumes
`VD_AGENT_MONITORS_CONFIG` in its own `client_monitors_config` handler and sends
no `VD_AGENT_REPLY` — the upstream harness documents this — so the window never
closed. The first resize of an agent connection was delivered and every later
one was dropped, while `resizingAvailable` stayed true, which made it silent for
the operator. Reconnecting cleared it, which is why manual use never caught it.
The gate reproduced it on QEMU 8.2.2 and 10.0.13 alike.

The window itself is worth keeping: it stops a continuous drag from flooding the
guest agent, and the app's own 150 ms debounce is a consumer-side courtesy the
library should not depend on.

## Decision

Add a second local patch, `Vendor/display-configuration-liveness.patch`, which
gives the in-flight configuration a deadline:

- `DisplayConfigurationCoordinator.acknowledgementTimeout` is 2 seconds.
  `didSend(_:at:)` records an expiry, and `nextToSend(now:)` returns the latest
  queued configuration once that expiry has passed. A reply, a disconnect and a
  reset still clear the window as before.
- Liveness costs nothing when idle: an expired window with nothing queued sends
  nothing, so the guest is never told again what it already has. The only effect
  is that a newer configuration is no longer held forever behind an
  acknowledgement the peer is not obliged to send.
- 2 seconds is chosen so that coalescing still does its job during a drag (at
  most one unacknowledged configuration every 2 seconds) while a deliberate
  second resize lands within a poll of the deadline. The app's debounce makes
  the practical interval longer still.
- A reply that arrives after the window expired acknowledges whatever is in
  flight then, which is the newer configuration. The event is cosmetic and the
  latest-wins outcome is unchanged; this is noted rather than defended against.

**Provenance.** `Vendor/UPSTREAM.json` now carries `patches` as an ordered list,
each entry naming its file, its SHA-256 and the decision that introduced it;
each applies to the tree the previous ones produced, which matters because both
patches touch `SpiceClipboardManager.swift`. `check-project.py` verifies every
entry, and the three changed files' hashes are updated in `files_sha256` as
usual. The vendored upstream tests are extended, not replaced: the existing
coalescing test now passes explicit instants, and two new cases cover the
timeout releasing the window and an expired window with nothing queued staying
quiet.

**The gate's pin flips.** ADR-0003 recorded the defect as a checked fact: the
gate required the second mode to be absent and failed if it appeared. It now
requires the second mode to be applied, in order, after the first.

## Consequences

- A viewport resize works for the life of a session, on every transport, instead
  of once per agent connection. This is the last of ADR-0001's redesigned
  behaviours that the live gate had shown to be broken.
- The local dependency change is no longer a single narrow patch. It is two
  patches, each tied to the decision that introduced it, which keeps the
  dependency reviewable but raises the cost of moving to a new upstream: both
  must be reapplied in order, and the review before any upgrade now covers a
  second file.
- An upstream proposal is worth drafting, because the defect is upstream's and
  not specific to this application. Publishing or submitting it is separate work.
- The gate keeps the regression: a future upstream that closes the window
  differently still has to deliver the second mode.

## Alternatives considered

1. **Let a newer configuration supersede immediately, with no window.** Simplest,
   and correct for a state message where the newest is all that matters, but it
   removes the flood protection during a drag and makes the library depend on
   every consumer debouncing.
2. **Detect that the peer never replies and stop gating for that connection.**
   Adaptive and precise, but it needs a first unacknowledged request to learn
   from, which is the very request whose successor is dropped; it is the timeout
   with extra state.
3. **Fix it in the application.** `SessionController` cannot reach the
   dependency's in-flight state; it could only reconnect the agent to clear it,
   which is a visible disruption to paper over a library defect.
4. **Wait for upstream.** Leaves a silent failure in the shipped product for an
   unbounded time; ADR-0001 chose a traceable local patch over waiting for
   exactly this class of problem.

## References

- [ADR-0001](0001-native-client-port.md) §2 (local dependency change, kept
  narrow and traceable) and §6 (record a needed dependency change rather than
  masking it).
- [ADR-0003](0003-agent-guest.md) implementation note 3, which recorded the
  defect and pinned it.
- Upstream note that QEMU's virtio-gpu path consumes the monitors configuration
  without replying: `Vendor/SwiftSpice/Integration/AppleContainer/APPLE_CONTAINER.md`.
- [Configuration and I/O](https://github.com/nlink-jp/knowledge/blob/main/docs/en/config-and-io.md):
  do not gate the next send on an acknowledgement the peer is not obliged to send.
