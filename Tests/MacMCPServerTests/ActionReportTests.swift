import AppKit
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

/// D5 and D1: what an action's report says about disappeared rows, and which refs it counts as shown.
@Suite struct ActionReportTests {
    func row(_ ref: String?, _ role: String, _ label: String) -> Row {
        Row(kind: ref == nil ? .text : .interactive, role: role, label: label, value: nil, states: [], frame: nil,
            depth: 0, ref: ref, fingerprint: "")
    }

    func result(_ rows: [Row], snapshot: Int, truncated: Bool = false, readFailures: Int = 0, textReadFailures: Int = 0,
                identityReadFailures: Int = 0, title: String = "Doc") -> SnapshotResult {
        let header = "app: Host · window \"\(title)\" · focus: none · snapshot s\(snapshot)"
        let body = rows.map { $0.render(frames: false) }
        var r = SnapshotResult(snapshot: snapshot, app: AppInfo(NSRunningApplication.current), windowTitle: title, focusRef: nil,
                               blockers: [], rows: rows,
                               lines: [header, "blockers: none", "--- \(rows.count) rows"] + body,
                               shownRows: rows)
        r.stats.truncated = truncated
        r.stats.readFailures = readFailures
        r.stats.textReadFailures = textReadFailures
        r.stats.identityReadFailures = identityReadFailures
        return r
    }

    let settled = Settle.Result(settled: true, milliseconds: 120)

    @Test func aCompleteWalkListsDisappearedRows() {
        let before = result([row("e1", "button", "Old"), row("e2", "button", "Same")], snapshot: 1)
        let after = result([row("e2", "button", "Same"), row("e3", "button", "New")], snapshot: 2)
        let out = report(summary: "clicked", settle: settled, before: before, after: after)
        #expect(out.text.contains("\n- e1 button \"Old\""))
        #expect(out.text.contains("\n+ e3 button \"New\""))
        #expect(!out.text.contains("incomplete"))
        #expect(out.shownRows.map(\.ref) == ["e3"], "only refs whose line the agent sees count as shown")
    }

    @Test func aTruncatedWalkSuppressesDisappearedRowsAndSaysSo() {
        let before = result([row("e1", "button", "Old"), row("e2", "button", "Same"), row(nil, "text", "Was here")], snapshot: 1)
        let after = result([row("e2", "button", "Same")], snapshot: 2, truncated: true)
        let out = report(summary: "clicked", settle: settled, before: before, after: after)
        #expect(!out.text.contains("- e1"), "a walk that stopped early never reached e1; it may still be there")
        #expect(!out.text.contains("- text \"Was here\""))
        #expect(out.text.contains("walk after the action was incomplete") && out.text.contains("take mac_snapshot"), "\(out.text)")
        #expect(out.shownRows.isEmpty)
    }

    @Test func readFailuresAlsoMakeTheWalkIncomplete() {
        let before = result([row("e1", "button", "Old")], snapshot: 1)
        let after = result([], snapshot: 2, readFailures: 2)
        let out = report(summary: "clicked", settle: settled, before: before, after: after)
        #expect(!out.text.contains("- e1") && out.text.contains("incomplete"), "\(out.text)")
    }

    /// A label or value that failed to read could be the row that seems to have gone; an identifier that failed to
    /// read can't be, so the diff still lists disappearances.
    @Test func failedLabelReadsMakeTheWalkIncompleteButFailedIdentifiersDoNot() {
        let before = result([row("e1", "button", "Old")], snapshot: 1)
        let text = report(summary: "clicked", settle: settled, before: before, after: result([], snapshot: 2, textReadFailures: 1))
        #expect(!text.text.contains("- e1") && text.text.contains("incomplete (the labels or values of 1 elements could not be read)"), "\(text.text)")
        let identifier = report(summary: "clicked", settle: settled, before: before, after: result([], snapshot: 2, identityReadFailures: 1))
        #expect(identifier.text.contains("- e1") && !identifier.text.contains("incomplete"), "\(identifier.text)")
        let cut = report(summary: "clicked", settle: settled, before: before, after: result([], snapshot: 2, truncated: true))
        #expect(cut.text.contains("incomplete (it stopped early)"), "\(cut.text)")
    }

    @Test func aChangedWindowShowsTheNewStateAndCountsItsRenderedRefs() {
        let before = result([row("e1", "button", "Old")], snapshot: 1, title: "Doc")
        let after = result([row("e5", "button", "Save"), row("e6", "button", "Cancel")], snapshot: 2, title: "Sheet")
        let out = report(summary: "clicked", settle: settled, before: before, after: after)
        #expect(out.text.contains("the UI changed substantially"))
        #expect(out.shownRows.map(\.ref) == ["e5", "e6"])
    }
}
