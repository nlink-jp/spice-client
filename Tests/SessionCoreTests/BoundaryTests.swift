import Foundation
import Testing
import ConnectionCore
import SessionCore
import SwiftSpiceAdapter
import SwiftSpice

@Test @MainActor func confirmationIsRequiredAndCannotBeReplayedOrReplaced() throws {
    let inbox = ConnectionInbox()
    let plan = try ConnectionPlan.parse(Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5900".utf8))
    let a = ConnectionCandidate(plan: plan, source: "Portal"), b = ConnectionCandidate(plan: plan, source: "File")
    #expect(inbox.offer(a)); #expect(!inbox.offer(b))
    #expect(inbox.approve(id: b.id) == nil)
    #expect(inbox.approve(id: a.id) == a)
    #expect(inbox.approve(id: a.id) == nil)
    #expect(inbox.offer(b)); inbox.cancel(id: b.id)
    #expect(inbox.approve(id: b.id) == nil)
}
@Test func stoppedConnectionCannotBecomeConnectedLate() throws {
    var lifecycle = SessionLifecycle()
    let started = lifecycle.start()
    let generation = try #require(started)
    let stopped = lifecycle.stop()
    #expect(stopped)
    let connected = lifecycle.connected(generation: generation)
    #expect(!connected)
    lifecycle.didStop()
    #expect(lifecycle.phase == .closed)
    let stoppedAgain = lifecycle.stop()
    #expect(!stoppedAgain)
}
@Test @MainActor func clipboardGateRevokesActualAccessAndNeverRelaysGuests() throws {
    var count = 0, reads = 0, writes = 0
    var text: String? = "local"
    let broker = ClipboardBroker(read: { reads += 1; return .init(changeCount: count, text: text) }, write: { value throws(SpiceClipboardError) in
        count += 1; writes += 1; text = value
        return .init(changeCount: count, text: text)
    })
    let a = UUID(), b = UUID()
    let aa = broker.access(for: a), ba = broker.access(for: b)
    #expect(aa.snapshot(aa.authorization().generation) == nil)
    #expect(reads == 0)
    broker.setEnabled(true, session: a); broker.setEnabled(true, session: b); broker.setFocused(a)
    let old = aa.authorization().generation
    #expect(try aa.write(old, "guest A") != nil)
    broker.setFocused(b)
    #expect(aa.snapshot(old) == nil)
    #expect(try aa.write(old, "late") == nil)
    #expect(ba.snapshot(ba.authorization().generation) == nil)
    #expect(writes == 1)
    count += 1; text = "new user copy"
    #expect(ba.snapshot(ba.authorization().generation)?.text == "new user copy")
    broker.setFocused(a)
    #expect(try aa.write(old, "stale grant") == nil)
    broker.revoke(a)
    #expect(!aa.authorization().allowed)
}

@Test @MainActor func temporaryReconnectPausePreservesFocusButRevokesOldAccess() {
    let broker = ClipboardBroker(read: { .init(changeCount: 1, text: "local") }, write: { _ throws(SpiceClipboardError) in .init(changeCount: 2, text: nil) })
    let id = UUID()
    broker.setEnabled(true, session: id); broker.setFocused(id)
    let access = broker.access(for: id)
    let before = access.authorization()
    broker.setEnabled(false, session: id)
    #expect(!access.authorization().allowed)
    broker.setEnabled(true, session: id)
    #expect(access.authorization().allowed)
    #expect(access.snapshot(before.generation) == nil)
    #expect(access.snapshot(access.authorization().generation)?.text == "local")
}

// ADR-0005: the rule a drop on a session window goes through. The drop handler,
// the menu command and the live gate all call this, so the surface cannot drift
// from what is tested here.
@Test func fileDropRefusesWhatASessionCannotOrMustNotSend() {
    let file = URL(fileURLWithPath: "/tmp/report.pdf")
    let ticket = URL(fileURLWithPath: "/tmp/console.vv")
    let folder = URL(fileURLWithPath: "/tmp/folder")
    func decide(_ urls: [URL], phase: SessionLifecycle.Phase = .connected,
                agent: Bool = true, guest: Bool = true) -> FileDropDecision {
        FileDropPolicy.decide(urls: urls, phase: phase, agentAvailable: agent, guestAcceptsFiles: guest,
                              isRegularFile: { $0 != folder })
    }
    #expect(decide([file]) == .send([file]))
    #expect(decide([]) == .refused(.empty))
    // A connection file carries a ticket: refused whatever else is in the drop.
    #expect(decide([ticket]) == .refused(.connectionFile))
    #expect(decide([file, ticket]) == .refused(.connectionFile))
    #expect(decide([ticket], phase: .idle, agent: false, guest: false) == .refused(.connectionFile))
    #expect(decide([file], phase: .connecting) == .refused(.notConnected))
    #expect(decide([file], phase: .closed) == .refused(.notConnected))
    #expect(decide([file], agent: false) == .refused(.agentUnavailable))
    #expect(decide([file], guest: false) == .refused(.guestRefuses))
    #expect(decide([folder]) == .refused(.noRegularFiles))
    // A mixed drop sends the regular files and never the folder.
    #expect(decide([file, folder]) == .send([file]))
}
