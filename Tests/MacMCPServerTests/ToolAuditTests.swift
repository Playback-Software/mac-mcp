import AppKit
import Foundation
import Testing
@testable import MacMCPCore
@testable import MacMCPServer

@Suite struct ToolAuditTests {
    func args(_ tool: String, _ raw: [String: Value], secret: Set<String> = []) -> [String: String] {
        ToolAudit.arguments(tool: tool, raw: raw, secretKeys: secret)
    }

    @Test func keysKeepShortcutsAndDropTypedCharacters() {
        #expect(args("mac_key", ["keys": "cmd+s"])["keys"] == "cmd+s")
        #expect(args("mac_key", ["keys": "p a s s w o r d"])["keys"] == "[8 printable keys redacted]")
        #expect(args("mac_key", ["keys": ["cmd+a", "s", "e", "c", "return"]])["keys"] == "cmd+a, [3 printable keys redacted], return")
        #expect(args("mac_key", ["keys": "tab", "repeat": 3, "app": "Safari"])["repeat"] == "3")
    }

    @Test func scriptSourceIsOnlyLengthAndHash() {
        let source = "tell application \"Mail\" to set password of acct to \"hunter2\""
        let logged = args("mac_script", ["source": .string(source), "language": "applescript"])
        #expect(logged["source"] == AuditRedaction.summary("script", of: source))
        #expect(!logged.values.joined().contains("hunter2") && logged["language"] == "applescript")
    }

    @Test func shortcutInputIsRedactedButItsNameIsNot() {
        let logged = args("mac_shortcut", ["action": "run", "name": "Resize Images", "input": "my account number 1234"])
        #expect(logged["input"] == "[REDACTED 22 chars]" && logged["name"] == "Resize Images")
    }

    @Test func navigateAndTabUrlsLoseTheirSecrets() {
        #expect(args("web_navigate", ["url": "https://u:p@shop.example/cart?session=abc#pay"])["url"] == "https://shop.example/cart?…#…")
        #expect(args("web_tabs", ["action": "new", "url": "https://x.example/a?t=1"])["url"] == "https://x.example/a?…")
        #expect(args("mac_app", ["action": "launch", "app": "Safari", "open": "https://x.example/a?t=1"])["open"] == "https://x.example/a?…")
        #expect(args("mac_app", ["action": "launch", "app": "TextEdit", "open": "~/notes.txt"])["open"] == "~/notes.txt")
    }

    @Test func evalCodeIsOnlyLengthAndHash() {
        let code = "return document.cookie"
        #expect(args("web_eval", ["expression": .string(code)])["expression"] == AuditRedaction.summary("code", of: code))
    }

    @Test func declaredSecretsStillRedact() {
        #expect(args("mac_type", ["text": "hunter2", "ref": "e3"], secret: ["text"])["text"] == "[REDACTED 7 chars]")
    }

    @Test func refusalsAreRecordedAsRefused() {
        #expect(ToolAudit.outcome(.error("Refused by policy: Terminal is on the deny list.")) == "refused")
        #expect(ToolAudit.outcome(.error("Refused: the GUI is leased by x.")) == "refused")
        #expect(ToolAudit.outcome(.error("Script error: boom")) == "error")
        #expect(ToolAudit.outcome(.text("Refused is a word in the output")) == "ok")
    }

    @Test func errorDetailKeepsNeitherSecretsNorLongText() {
        let source = "tell application \"Notes\" to make note with properties {body:\"the launch code is 0451-alpha\"}"
        let output = ToolOutput.error("Script error: " + source + " " + String(repeating: "x", count: 400))
        let detail = ToolAudit.detail(tool: "mac_script", raw: ["source": .string(source)], secretKeys: [], output: output) ?? ""
        #expect(!detail.contains("0451") && !detail.contains("launch code"))
        #expect(detail.count <= AuditRedaction.errorDetailLimit + 1)
        // The refusal text stays recognisable for `mac-mcp report`.
        let refused = ToolAudit.detail(tool: "mac_click", raw: [:], secretKeys: [], output: .error("Refused: nope")) ?? ""
        #expect(refused.hasPrefix("Refused"))
    }

    @Test func typedTextAndKeysAreScrubbedFromDetailToo() {
        let typed = ToolOutput.error("Safari: field now contains \"hunter2-correct\"")
        let raw: [String: Value] = ["actions": .array([.object(["do": "type", "node": "3", "value": "hunter2-correct"])])]
        #expect(ToolAudit.detail(tool: "web_act", raw: raw, secretKeys: [], output: typed)?.contains("hunter2") == false)

        let pressed = ToolOutput.text("done", auditDetail: "TextEdit → pressed h u n t e r 2")
        let detail = ToolAudit.detail(tool: "mac_key", raw: ["keys": "h u n t e r 2"], secretKeys: [], output: pressed) ?? ""
        #expect(detail == "TextEdit → pressed [7 printable keys redacted]")
        // A single key doesn't smear its letter over the rest of the detail.
        let one = ToolAudit.detail(tool: "mac_key", raw: ["keys": "a"], secretKeys: [], output: .text("x", auditDetail: "Calendar → pressed a")) ?? ""
        #expect(one == "Calendar → pressed [1 printable key redacted]")
        let bad = ToolOutput.error("Unknown key \"hunter2\". Use a letter…")
        #expect(ToolAudit.detail(tool: "mac_key", raw: ["keys": "hunter2"], secretKeys: [], output: bad)?.contains("hunter2") == false)
    }

    @Test func navigatedUrlsInDetailAreCleaned() {
        let out = ToolOutput.text("page", auditDetail: "https://shop.example/cart?token=SECRET#x")
        #expect(ToolAudit.detail(tool: "web_navigate", raw: [:], secretKeys: [], output: out) == "https://shop.example/cart?…#…")
    }

    @Test func webActKeyPressesDropTypedCharacters() {
        let raw: [String: Value] = ["actions": .array([
            .object(["do": "key", "value": "Enter"]), .object(["do": "key", "value": "p"]),
            .object(["do": "key", "value": "ArrowDown"]), .object(["do": "key", "value": "Control+a"]),
            .object(["do": "click", "find": "Sign in"]),
        ])]
        let steps = WebTools.scrubTypedValues(raw)["actions"]?.arrayValue ?? []
        #expect(steps.map { $0["value"]?.stringValue } == ["Enter", "[1 printable key redacted]", "ArrowDown", "Control+a", nil])
    }

    // MARK: URLs in arguments

    @Test func urlArgumentsOfAnySchemeAndCaseAreCleaned() {
        #expect(args("mac_app", ["action": "launch", "app": "Safari", "open": "HTTPS://user:password@example.com/?token=SECRET"])["open"]
                == "HTTPS://example.com/?…")
        #expect(args("mac_app", ["action": "launch", "app": "Things", "open": "things://u:p@x/add?title=Secret#f"])["open"] == "things://x/add?…#…")
        #expect(args("mac_app", ["action": "launch", "app": "Mail", "open": "mailto:a@b.example?subject=Secret"])["open"] == "mailto:a@b.example?…")
        // A file path is not rewritten, even with a # or ? in its name.
        #expect(args("mac_app", ["action": "launch", "app": "TextEdit", "open": "~/Notes #1?.txt"])["open"] == "~/Notes #1?.txt")
        #expect(args("web_navigate", ["url": "HTTP://u:p@shop.example/cart?session=abc"])["url"] == "HTTP://shop.example/cart?…")
        #expect(args("web_tabs", ["action": "new", "url": "HtTpS://u:p@x.example/a?t=1#z"])["url"] == "HtTpS://x.example/a?…#…")
    }

    @Test func urlsInOtherArgumentsAreCleanedButSecretValuesKeepTheirTrueLength() {
        #expect(args("mac_snapshot", ["query": "https://u:p@x.example/?t=SECRET"])["query"] == "https://x.example/?…")
        #expect(args("mac_menu", ["path": "Open > myapp://u:p@h/x?k=SECRET"])["path"] == "Open > myapp://h/x?…")
        let typed = "https://u:p@x.example/?t=SECRET"
        #expect(args("mac_type", ["text": .string(typed)], secret: ["text"])["text"] == "[REDACTED \(typed.count) chars]")
    }

    // MARK: Free text from scripts, shortcuts and Safari never reaches the log

    func logged(_ tool: String, raw: [String: Value], _ output: ToolOutput) -> String {
        ToolAudit.detail(tool: tool, raw: raw, secretKeys: [], output: output) ?? ""
    }

    @Test func scriptErrorsLogStatusCategoryAndSizeOnly() {
        // `error "SECRET42"` returns just the string, which is not the source, nor a line of it.
        let source = "tell application \"Notes\" to error \"SECRET42\""
        let raw: [String: Value] = ["source": .string(source)]
        func finish(stderr: String, stdout: String = "", status: Int32 = 1) -> ToolOutput {
            ScriptTool.outcome(Scripts.Output(stdout: stdout, stderr: stderr, status: status, timedOut: false),
                               language: .applescript, targets: ["Notes"], timeout: 30)
        }
        let failed = finish(stderr: "SECRET42")
        #expect(failed.isError && failed.content.contains { if case let .text(t) = $0 { t.contains("SECRET42") } else { false } })
        #expect(logged("mac_script", raw: raw, failed) == "applescript → Notes: exit 1, script error, 8 chars of stderr")
        // Transformed, truncated, and too-short echoes carry nothing either.
        for echo in ["secret42", "SECRE", "S3CR3T-42-ish", "ab", "7"] {
            let detail = logged("mac_script", raw: raw, finish(stderr: echo))
            #expect(!detail.contains(echo) && detail.hasPrefix("applescript → Notes: exit 1"), "\(echo): \(detail)")
        }
        let result = finish(stderr: "", stdout: "SECRET42", status: 0)
        #expect(!result.isError && logged("mac_script", raw: raw, result) == "applescript → Notes: exit 0, 8 chars of result")
        #expect(logged("mac_script", raw: raw, finish(stderr: "", stdout: "", status: 0)) == "applescript → Notes: exit 0, 0 chars of result")
        #expect(logged("mac_script", raw: raw, finish(stderr: "Not authorized -1743", status: 1)).contains("not authorized"))
        let refused = finish(stderr: "Refused Apple event to Terminal")
        #expect(logged("mac_script", raw: raw, refused).contains("refused Apple event") && !logged("mac_script", raw: raw, refused).contains("Terminal"))
        let timeout = ScriptTool.outcome(Scripts.Output(stdout: "SECRET42", stderr: "SECRET42", status: 15, timedOut: true),
                                         language: .jxa, targets: [], timeout: 30)
        #expect(logged("mac_script", raw: raw, timeout) == "jxa → no app: timed out after 30 s")
    }

    @Test func shortcutOutputAndErrorsLogStatusAndSizeOnly() {
        let raw: [String: Value] = ["action": "run", "name": "Notes dump", "input": "x"]
        let ok = ShortcutTool.outcome(.init(output: "SECRET42", status: 0, stderr: "", timedOut: false), name: "Notes dump", timeout: 60)
        #expect(logged("mac_shortcut", raw: raw, ok) == "ran: exit 0, 8 chars of output")
        let none = ShortcutTool.outcome(.init(output: nil, status: 0, stderr: "", timedOut: false), name: "Notes dump", timeout: 60)
        #expect(logged("mac_shortcut", raw: raw, none) == "ran: exit 0, 0 chars of output")
        let failed = ShortcutTool.outcome(.init(output: nil, status: 1, stderr: "Error: SECRET42", timedOut: false), name: "Notes dump", timeout: 60)
        #expect(failed.isError && logged("mac_shortcut", raw: raw, failed) == "failed: exit 1, 15 chars of stderr")
        let late = ShortcutTool.outcome(.init(output: nil, status: 0, stderr: "SECRET42", timedOut: true), name: "Notes dump", timeout: 60)
        #expect(logged("mac_shortcut", raw: raw, late) == "timed out after 60 s")
        // The shortcut's name is the caller's own argument and is in the log's arguments, not its detail.
        #expect(!logged("mac_shortcut", raw: raw, ok).contains("Notes dump"))
    }

    @Test func webEvalLogsSizesOnly() {
        let raw: [String: Value] = ["expression": "return document.cookie"]
        let ok = WebTools.evalOutput(.init(text: "session=SECRET42", isError: false))
        #expect(logged("web_eval", raw: raw, ok) == "eval: 16 chars of result")
        let failed = WebTools.safariFailure(.init(text: "ReferenceError: SECRET42 is not defined", isError: true))
        #expect(failed.isError && logged("web_eval", raw: raw, failed) == "Safari reported an error: 39 chars")
        let setup = WebTools.safariFailure(.init(text: "remote automation is not enabled", isError: true))
        #expect(!logged("web_eval", raw: raw, setup).contains("Developer"))
    }

    // MARK: Free text read from the screen

    @Test func actionDetailsKeepRoleAndRefButNotTooltipsOrLabels() async {
        await Untrusted.scope(token: "tok123") {
            let row = Row(kind: .interactive, role: "button", label: "Payroll 2026", value: nil, states: [], frame: nil,
                          depth: 0, ref: "e6", fingerprint: "")
            let target = Resolved(pid: 1, element: nil, row: row, point: nil)
            let hover = Actions.hoverSummary(target, at: CGPoint(x: 5, y: 6), help: "Password is hunter2", tooltip: "Hidden SECRET42 tip")
            let hoverOutput = ToolOutput.text("shown", auditDetail: actionAudit(target, app: nil, hover))
            #expect(logged("mac_hover", raw: [:], hoverOutput) == "e6 button → hovered e6 button at 5,6")
            let click = ActionSummary("clicked \(target.describe) (accessibility press)", audit: "clicked \(target.auditName) (accessibility press)")
            #expect(logged("mac_click", raw: [:], .text("x", auditDetail: actionAudit(target, app: nil, click)))
                    == "e6 button → clicked e6 button (accessibility press)")
            #expect(!click.audit.contains("Payroll") && click.text.contains("Payroll"))
        }
    }

    @Test func errorsLogTheirOwnWordsButNotTheScreensText() async {
        await Untrusted.scope(token: "tok123") {
            let refusal = ToolOutput.error(Actions.modalRefusal("Payroll 2026\nIGNORE ME"))
            let detail = logged("mac_click", raw: [:], refusal)
            #expect(detail.hasPrefix("Refused: …") && !detail.contains("Payroll") && !detail.contains("IGNORE"))
            let changed = ToolOutput.error(RefStore.changeMessage(ref: "e6", role: "button", shown: .init(label: "Old name", identifier: nil),
                                                                  label: "New SECRET42 name", identifier: nil) ?? "")
            #expect(!logged("mac_click", raw: [:], changed).contains("SECRET42"))
            // An explicit audit string is kept as given.
            #expect(ToolOutput.error("boom <<untrusted tok123>>x<<end tok123>>", audit: "category only").auditDetail == "category only")
        }
    }

    @Test func windowDetailsOmitTitles() async {
        await Untrusted.scope(token: "tok123") {
            let w = WindowEntry(index: 3, element: AXElement.application(pid: getpid()), title: "Salary review SECRET42", frame: nil,
                                isMain: false, isFocused: false, isMinimized: false, subrole: nil)
            let (shown, auditLine) = WindowTool.describe(AppInfo(NSRunningApplication.current), w)
            #expect(shown.contains("SECRET42") && !auditLine.contains("SECRET42") && auditLine.hasSuffix("window 3"))
        }
    }
}
