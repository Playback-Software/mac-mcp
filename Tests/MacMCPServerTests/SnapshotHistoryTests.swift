import AppKit
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct SnapshotHistoryTests {
    private func snapshot(_ id: Int, value: String = "old", complete: Bool = true, rows: Bool = true) -> SnapshotResult {
        let row = Row(kind: .interactive, role: "textfield", label: "Name", value: value, states: [], frame: nil,
                      depth: 0, ref: "e1", fingerprint: "name")
        var stats = WalkStats(); if !complete { stats.readFailures = 1 }
        return SnapshotResult(snapshot: id, app: AppInfo(.current), windowTitle: "Form", focusRef: "e1", blockers: [],
            rows: rows ? [row] : [], lines: ["app: fixture · focus: e1 · snapshot s\(id)", "blockers: none", "rows", row.render(frames: false)],
            stats: stats, shownRows: rows ? [row] : [])
    }

    @Test func baselinesBelongToTheConnectionAndExpire() async {
        let history = SnapshotHistory()
        await history.remember(snapshot(1), request: SnapshotRequest(), owner: "a")
        #expect(await history.baseline(1, owner: "b") == nil)
        #expect(await history.baseline(1, owner: "a") != nil)
        for id in 2...65 { await history.remember(snapshot(id), request: SnapshotRequest(), owner: "a") }
        #expect(await history.baseline(1, owner: "a") == nil)
    }

    @Test func changedRowsAreShownButMissingRowsNeedACompleteRead() {
        let before = SnapshotHistory.View(result: snapshot(1), request: SnapshotRequest())
        let changed = SnapshotHistory.render(before, after: snapshot(2, value: "new"), request: SnapshotRequest())
        #expect(changed.text.contains("old") && changed.text.contains("new") && changed.shown.map(\.ref) == ["e1"])
        let incomplete = SnapshotHistory.render(before, after: snapshot(3, complete: false, rows: false), request: SnapshotRequest())
        #expect(!incomplete.text.contains("- e1") && incomplete.text.contains("incomplete read"))
        let gone = SnapshotHistory.render(before, after: snapshot(3, rows: false), request: SnapshotRequest())
        #expect(gone.text.contains("- e1"))
        var request = SnapshotRequest(); request.query = "Other"
        #expect(SnapshotHistory.render(before, after: snapshot(4), request: request).text.hasPrefix("Snapshot context changed"))
    }
}
