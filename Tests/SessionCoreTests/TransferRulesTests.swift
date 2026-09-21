import Foundation
import Testing
import SwiftSpice
import SwiftSpiceAdapter

// The transfer bookkeeping rules (ADR-0005 §2). Each case is a defect that the
// live peer reproduced before the fix; these hold the rule without a peer.

private func group(_ states: [FileTransferItem.State]) -> FileTransferGroup {
    var g = FileTransferGroup(urls: states.indices.map { URL(fileURLWithPath: "/tmp/f\($0).bin") })
    for i in states.indices { g.items[i].state = states[i] }
    return g
}

@Test func aQueuedFileIsNeverStalledHoweverLongItWaits() {
    let now = ContinuousClock.now
    var g = group([.sending, .queued, .queued, .completed])
    for i in g.items.indices { g.items[i].lastChange = now.advanced(by: .seconds(-120)) }
    let stalled = FileTransferRules.stalled([g], now: now, timeout: .seconds(60))
    #expect(stalled == [g.items[0].id])
}

@Test func aSendingFileThatStillMovesIsNotStalled() {
    let now = ContinuousClock.now
    var g = group([.sending])
    g.items[0].lastChange = now.advanced(by: .seconds(-10))
    #expect(FileTransferRules.stalled([g], now: now, timeout: .seconds(60)).isEmpty)
}

@Test func aCancelledJobTheDependencyStillHoldsKeepsItsSlot() {
    var g = group([.cancelled, .sending, .sending, .sending, .queued])
    g.items[0].holdsBackendSlot = true
    #expect(FileTransferRules.slotsInUse([g]) == 4)
    g.items[0].holdsBackendSlot = false // the guest answered the cancellation
    #expect(FileTransferRules.slotsInUse([g]) == 3)
}

@Test func retiringAConnectionForgetsEveryBackendIdAndSlot() {
    var g = group([.completed, .sending, .queued, .cancelled])
    g.items[0].remote = SpiceFileTransferID(rawValue: 1)
    g.items[1].remote = SpiceFileTransferID(rawValue: 2)
    g.items[1].holdsBackendSlot = true
    g.items[3].remote = SpiceFileTransferID(rawValue: 3)
    g.items[3].holdsBackendSlot = true
    var groups = [g]
    FileTransferRules.retire(&groups, as: .failed("connection restarted"), now: .now)
    let items = groups[0].items
    #expect(items.map(\.state) == [.completed, .failed("connection restarted"), .failed("connection restarted"), .cancelled])
    #expect(items.allSatisfy { $0.remote == nil && !$0.holdsBackendSlot })
    #expect(FileTransferRules.slotsInUse(groups) == 0)
}
