import AppKit
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct ShownRefTests {
    func rows() -> [Row] {
        var root = RawNode(role: "AXWindow", title: "Reports")
        root.element = AXElement.application(pid: 220_000)
        root.children = (0..<40).map { i in
            var item = RawNode(role: "AXRow", title: "Report \(i)")
            item.path = "0.\(i)"
            item.element = AXElement.application(pid: Int32(220_001 + i * 2))
            var delete = RawNode(role: "AXButton", title: "Delete")
            delete.path = "0.\(i).0"
            delete.element = AXElement.application(pid: Int32(220_002 + i * 2))
            item.children = [delete]
            return item
        }
        return Snapshot.rows(from: root, pid: 7)
    }

    func sample(_ rows: [Row], rendered: Snapshot.Rendering, snapshot: Int, title: String = "Reports",
                focusRef: String? = nil) -> SnapshotResult {
        SnapshotResult(snapshot: snapshot, app: AppInfo(NSRunningApplication.current), windowTitle: title,
                       focusRef: focusRef, blockers: [], rows: rows,
                       lines: ["app: Host · focus: \(focusRef ?? "none") · snapshot s\(snapshot)", "blockers: none", "--- rows"]
                           + rendered.text.components(separatedBy: "\n"), shownRows: rendered.shownRows)
    }

    @Test(arguments: [false, true]) func guessedCollapsedRowsAndTheirDeleteButtonsAreRefused(current: Bool) async throws {
        let store = RefStore()
        var rows = rows()
        let snapshot = try await store.record(&rows, pid: 7)
        var request = SnapshotRequest()
        request.maxTokens = 200
        request.markShown = true
        let out = await Snapshotter.render(rows, request: request, refs: store)
        #expect(out.omitted > 0)
        for item in [rows[40], rows[41]] {
            #expect(!out.shownRows.contains(item))
            let ref = try #require(item.ref)
            do {
                _ = try await Actions.resolve(.ref(ref), currentSnapshot: current ? snapshot : snapshot + 1, refs: store)
                Issue.record("a guessed hidden \(item.role) was accepted")
            } catch let error as ActionError {
                #expect(error.description == "\(ref) was never shown; find it with mac_snapshot query= or take a new snapshot.")
            }
        }
    }

    @Test(arguments: ["overview", "query", "diff", "state", "wait", "timeout", "disappeared"])
    func everyReturnedRefIsMarkedAndCanResolve(path: String) async throws {
        let store = RefStore()
        var rows = rows()
        var snapshot = try await store.record(&rows, pid: 7)
        var request = SnapshotRequest()
        request.maxTokens = 200
        let overview = await Snapshotter.render(rows, request: request, refs: store)
        let target = rows[40]
        let ref = try #require(target.ref)
        #expect(!overview.shownRows.contains(target))
        var expected: [Row]
        let text: String
        switch path {
        case "overview", "query":
            request.markShown = true
            let input: [Row]
            if path == "query" {
                request.query = "Report 20"
                input = rows.filter { $0.matches(request.query!) }
            } else { input = rows }
            let out = await Snapshotter.render(input, request: request, refs: store)
            expected = out.shownRows
            text = out.text
        case "wait":
            let s = sample(rows, rendered: overview, snapshot: snapshot, focusRef: rows[0].ref)
            text = await WaitTool.matchedResponse(sample: s, matches: [target], until: "element", query: "Report 20", elapsed: 1, refs: store)
            expected = [target]
            #expect(!text.contains("focus: \(rows[0].ref!)"), "the focus header cannot expose an unreturned row")
        case "timeout":
            let s = sample(rows, rendered: overview, snapshot: snapshot)
            text = await WaitTool.timeoutResponse(s, refs: store)
            expected = overview.shownRows
        default:
            let beforeRows = path == "diff" ? rows.filter { $0.ref != ref } : rows
            let before = sample(beforeRows, rendered: overview, snapshot: snapshot, title: path == "state" ? "Old" : "Reports")
            if path == "disappeared" { rows.removeAll { $0.ref == ref } }
            snapshot = try await store.record(&rows, pid: 7)
            let afterRender = await Snapshotter.render(rows, request: request, refs: store)
            let after = sample(rows, rendered: afterRender, snapshot: snapshot, focusRef: rows[0].ref)
            text = await actionReport(summary: "clicked", settle: Settle.Result(settled: true, milliseconds: 1),
                                      before: before, after: after, refs: store)
            expected = path == "state" ? afterRender.shownRows : [target]
            if path != "state" { #expect(!text.contains("focus: \(rows[0].ref!)")) }
        }
        #expect(!expected.isEmpty)
        for item in expected {
            let r = try #require(item.ref)
            #expect(text.contains(r + " "))
            #expect(try #require(await store.entry(r)).shown == RefStore.Shown(item))
            // Disappearance reports can return an element no longer in the current walk. Test its marking above;
            // all live paths resolve against their current snapshot without any accessibility calls.
            if path != "disappeared" {
                let resolved = try await Actions.resolve(.ref(r), currentSnapshot: snapshot, refs: store)
                #expect(resolved.row?.ref == r)
            }
        }
        for item in rows where !expected.contains(item) {
            #expect(try #require(await store.entry(item.ref!)).shown == nil)
        }
    }

    @Test func windowListsAndWindowWaitsUseIndicesRatherThanElementRefs() {
        let window = WindowEntry(index: 2, element: AXElement.application(pid: 220_000), title: "Reports", frame: nil,
                                 isMain: false, isFocused: false, isMinimized: false, subrole: nil)
        #expect(window.line == "2. \"Reports\"")
        let text = WaitTool.windowText(app: AppInfo(NSRunningApplication.current), window: window, elapsed: 1)
        #expect(text.contains("2. \"Reports\""))
        #expect(!text.contains("e2 "))
    }

    @Test func aHeaderDoesNotIntroduceAnUnreturnedFocusRef() {
        let rows = rows()
        let overview = Snapshot.renderOverview(rows, frames: false, maxTokens: 200)
        let s = sample(rows, rendered: overview, snapshot: 1, focusRef: "e999")
        #expect(s.headerLines(showing: []).first?.contains("focus: (not listed)") == true)
    }
}
