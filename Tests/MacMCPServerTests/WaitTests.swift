import AppKit
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct WaitLogicTests {
    @Test func waitsUseFullTextAndDoNotConfuseGoneWithTruncatedOutput() {
        let value = String(repeating: "x", count: 150) + "needle"
        let rows = Snapshot.rows(from: RawNode(role: "AXTextField", title: "Log", value: value), pid: 7)
        let matches = WaitTool.matchingRows(rows, query: "needle", until: "text")
        #expect(matches.count == 1)
        #expect(WaitTool.conditionMet(until: "text", matches: matches, stats: WalkStats()))
        #expect(!WaitTool.conditionMet(until: "gone", matches: matches, stats: WalkStats()))
        #expect(WaitTool.conditionMet(until: "gone", matches: [], stats: WalkStats()))
    }

    @Test func incompleteOrLoadingTreesCannotProveSomethingIsGone() {
        var stats = WalkStats()
        stats.truncated = true
        #expect(!WaitTool.conditionMet(until: "gone", matches: [], stats: stats))
        stats.truncated = false
        stats.loadingPages = 1
        #expect(!WaitTool.conditionMet(until: "gone", matches: [], stats: stats))
        stats.loadingPages = 0
        stats.readFailures = 1
        #expect(!WaitTool.conditionMet(until: "gone", matches: [], stats: stats))
    }

    @Test func elementWaitIgnoresStaticTextMatches() {
        let rows = Snapshot.rows(from: RawNode(role: "AXStaticText", value: "Ready"), pid: 7)
        #expect(WaitTool.matchingRows(rows, query: "ready", until: "text").count == 1)
        #expect(WaitTool.matchingRows(rows, query: "ready", until: "element").isEmpty)
    }

    @Test func sparseTreeTimeoutShowsCurrentStateAndAnOCRRecoveryPath() {
        let app = AppInfo(NSRunningApplication.current)
        var sample = SnapshotResult(snapshot: 1, app: app, windowTitle: "Canvas", focusRef: nil,
                                    blockers: [], rows: [], text: "Current canvas window")
        sample.stats.truncated = true
        let diagnostic = WaitTool.timeoutDiagnostic(sample)
        #expect(diagnostic.contains("Current canvas window"))
        #expect(diagnostic.contains("incomplete") && diagnostic.contains("ocr=true"))
    }

    @Test func OCRMatchesVisibleTextCaseInsensitively() {
        let lines = [OCR.Line(text: "Canvas Launch", confidence: 0.95, box: .zero),
                     OCR.Line(text: "Canvas Abort", confidence: 0.95, box: .zero)]
        #expect(WaitTool.matchingOCR(lines, query: "launch").map(\.text) == ["Canvas Launch"])
        #expect(WaitTool.matchingOCR(lines, query: "Missing").isEmpty)
    }

    @Test func OCRRejectsAbsenceChecksBeforeTouchingTheGUI() async {
        let result = await WaitTool.spec.handler(ToolArgs(["until": "gone", "query": "Ready", "ocr": true]),
                                                 ToolContext(client: "test"))
        #expect(result.isError)
        #expect(result.auditDetail?.contains("only with until=text") == true)
    }
}

@Suite struct AuditPrivacyRegressionTests {
    @Test func promptInputIsRedactedUsingTheActualDialogSpecification() {
        let text = "synthetic-private-prompt-input"
        let args = ToolArgs(["action": "accept", "text": .string(text)])
        let redacted = AuditLog.redact(args.auditStrings, secretValueKeys: WebTools.dialog.secretArguments)
        #expect(redacted["text"] == "[REDACTED \(text.count) chars]")
        #expect(redacted["action"] == "accept")
    }

    @Test func abandonmentExplainsThatAnAlreadySentActionMayStillFinish() {
        let output = abandoned("mac_click", 20)
        let text = output.content.compactMap { if case let .text(s) = $0 { s } else { nil } }.joined()
        #expect(output.isError && text.contains("already sent"))
        #expect(text.contains("before retrying"))
    }
}
