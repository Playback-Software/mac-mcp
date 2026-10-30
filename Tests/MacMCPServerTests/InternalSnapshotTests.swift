import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

/// D1: snapshots the agent never sees (an action's before/after, a drag's drop target, mac_wait's polling) must not
/// record what they rendered as "shown to the agent", or a ref whose element was renamed in between would be
/// accepted on the strength of a label the agent was never given.
@Suite struct InternalSnapshotTests {
    func button(_ n: Int32, title: String) -> RawNode {
        var root = RawNode(role: "AXWindow", title: "Form")
        root.element = AXElement.application(pid: 210_000)
        var button = RawNode(role: "AXButton", title: title)
        button.element = AXElement.application(pid: 210_000 + n)
        root.children = [button]
        return root
    }

    @Test func actionsAndDragsSnapshotWithoutMarking() {
        #expect(!bookkeepingSnapshot(pid: 7).markShown)
        #expect(bookkeepingSnapshot(pid: 7).pid == 7)
        #expect(!SnapshotRequest().markShown, "the default is off; mac_snapshot opts in")
    }

    /// The agent saw the destination as "Drop here"; it was renamed before the drag. The drag's own snapshot of the
    /// destination must leave the guard alone so `resolve` refuses the stale ref.
    @Test func aDragsDestinationSnapshotLeavesTheGuardAlone() async throws {
        let store = RefStore()
        var shown = Snapshot.rows(from: button(1, title: "Drop here"), pid: 7)
        _ = try await store.record(&shown, pid: 7)
        await store.markShown(shown)   // mac_snapshot rendered it
        let ref = try #require(shown[0].ref)
        // What the drag does with its destination snapshot: record, and mark only if the request says so.
        var renamed = Snapshot.rows(from: button(1, title: "Delete"), pid: 7)
        _ = try await store.record(&renamed, pid: 7)
        if bookkeepingSnapshot(pid: 7).markShown { await store.markShown(renamed) }
        let entry = try #require(await store.entry(ref))
        #expect(entry.shown?.label == "Drop here")
        let message = RefStore.changeMessage(ref: ref, role: "button", shown: entry.shown, label: entry.row.label, identifier: nil)
        #expect(message.map { Untrusted.strip($0) } == "\(ref) was … but now reads …. Take a new mac_snapshot.")
        #expect(message?.contains(">>Drop here<<end") == true && message?.contains(">>Delete<<end") == true)
    }

    /// mac_wait polls with snapshots and returns only the matching rows: those are what the agent sees, so those
    /// (within the response budget) are marked, and nothing else in the polled tree is.
    @Test func aWaitMarksOnlyTheMatchesItReturns() async throws {
        let store = RefStore()
        var root = RawNode(role: "AXWindow", title: "Form")
        root.element = AXElement.application(pid: 211_000)
        var submit = RawNode(role: "AXButton", title: "Submit")
        submit.element = AXElement.application(pid: 211_001)
        var ready = RawNode(role: "AXButton", title: "Ready")
        ready.element = AXElement.application(pid: 211_002)
        root.children = [submit, ready]
        var rows = Snapshot.rows(from: root, pid: 7)
        _ = try await store.record(&rows, pid: 7)
        await store.markShown(rows)   // the agent's own snapshot
        let submitRef = try #require(rows[0].ref), readyRef = try #require(rows[1].ref)

        // Submit is renamed; the wait for "Ready" polls and succeeds.
        root.children[0].title = "Send Order"
        var polled = Snapshot.rows(from: root, pid: 7)
        let snapshot = try await store.record(&polled, pid: 7)
        let sample = SnapshotResult(snapshot: snapshot, app: AppInfo(NSRunningApplication.current), windowTitle: "Form", focusRef: nil,
                                    blockers: [], rows: polled, lines: ["app: Host · snapshot s\(snapshot)", "blockers: none", "--- rows"],
                                    shownRows: polled)
        let matches = WaitTool.matchingRows(polled, query: "Ready", until: "element")
        let met = WaitTool.metResponse(sample: sample, matches: matches, until: "element", query: "Ready", elapsed: 12)
        #expect(met.text.contains("met after 12 ms") && met.text.contains("\(readyRef) button \"Ready\""))
        #expect(!met.text.contains("Send Order"), "the response shows the matches, not the renamed button")
        #expect(met.shownRows.map(\.ref) == [readyRef])
        await store.markShown(met.shownRows)

        let stale = try #require(await store.entry(submitRef))
        #expect(stale.shown?.label == "Submit", "the polled snapshot must not have marked the renamed button")
        #expect(RefStore.changeMessage(ref: submitRef, role: "button", shown: stale.shown, label: stale.row.label, identifier: nil) != nil)
        #expect(try #require(await store.entry(readyRef)).shown?.label == "Ready")
    }

    @Test func aWaitResponseCutByItsBudgetMarksOnlyWhatFit() {
        let rows = (0..<200).map { i in
            Row(kind: .interactive, role: "button", label: String(repeating: "x", count: 60) + "\(i)", value: nil, states: [],
                frame: nil, depth: 0, ref: "e\(i)", fingerprint: "")
        }
        let sample = SnapshotResult(snapshot: 1, app: AppInfo(NSRunningApplication.current), windowTitle: nil, focusRef: nil,
                                    blockers: [], rows: rows, lines: ["h", "b"], shownRows: rows)
        let met = WaitTool.metResponse(sample: sample, matches: rows, until: "element", query: "x", elapsed: 1)
        #expect(met.shownRows.count < rows.count && !met.shownRows.isEmpty)
        #expect(met.shownRows.allSatisfy { met.text.contains($0.ref! + " ") })
    }
}
