import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

@Suite struct KeySpecTests {
    @Test func parsesModifiersAndNamedKeys() throws {
        #expect(try KeySpec.parse("cmd+s") == KeySpec(key: 1, flags: .maskCommand))
        #expect(try KeySpec.parse("Cmd+Shift+S") == KeySpec(key: 1, flags: [.maskCommand, .maskShift]))
        #expect(try KeySpec.parse("esc") == KeySpec(key: 53, flags: []))
        #expect(try KeySpec.parse("alt+left") == KeySpec(key: 123, flags: .maskAlternate))
        #expect(try KeySpec.parse("f5") == KeySpec(key: 96, flags: []))
        #expect(try KeySpec.parse("cmd++") == KeySpec(key: 24, flags: [.maskCommand, .maskShift]))
    }

    @Test func parsesSequences() throws {
        let seq = try KeySpec.parseSequence("cmd+a, delete")
        #expect(seq == [KeySpec(key: 0, flags: .maskCommand), KeySpec(key: 51, flags: [])])
        #expect(try KeySpec.parseSequence("down down return").count == 3)
    }

    @Test func parsesTheCommaKey() throws {
        let cmdComma = KeySpec(key: 43, flags: .maskCommand)
        #expect(try KeySpec.parseSequence("cmd+,") == [cmdComma])
        #expect(try KeySpec.parseSequence("cmd+comma") == [cmdComma])
        #expect(try KeySpec.parseSequence("cmd+,, return") == [cmdComma, KeySpec(key: 36, flags: [])])
        #expect(try KeySpec.parseSequence(["cmd+,", "esc"]) == [cmdComma, KeySpec(key: 53, flags: [])])
        #expect(throws: KeySpec.ParseError.self) { try KeySpec.parseSequence([String]()) }
    }

    @Test func namesPunctuationKeys() throws {
        for (name, char) in [("period", "."), ("slash", "/"), ("semicolon", ";"), ("quote", "'"), ("bracketleft", "["),
                             ("bracketright", "]"), ("minus", "-"), ("equal", "="), ("backslash", "\\"), ("grave", "`")] {
            #expect(try KeySpec.parse("cmd+" + name) == KeySpec.parse("cmd+" + char), "\(name)")
        }
    }

    @Test func describesModifiers() {
        #expect(KeySpec.describe([.maskCommand, .maskShift]) == "shift+cmd")
        #expect(KeySpec.describe([]) == "")
    }

    @Test func rejectsUnknownKeysWithHelp() {
        #expect(throws: KeySpec.ParseError.self) { try KeySpec.parse("cmd+banana") }
        #expect(throws: KeySpec.ParseError.self) { try KeySpec.parse("hyper+s") }
        #expect(throws: KeySpec.ParseError.self) { try KeySpec.parseSequence("  ") }
    }

    @Test func parsesClickModifiers() throws {
        #expect(try KeySpec.modifiers("cmd+shift") == [.maskCommand, .maskShift])
        #expect(try KeySpec.modifiers("") == [])
    }
}

@Suite struct DiffTests {
    func row(_ ref: String?, _ role: String, _ label: String, value: String? = nil, states: [String] = []) -> Row {
        Row(kind: ref == nil ? .text : .interactive, role: role, label: label, value: value, states: states, frame: nil,
            depth: 0, ref: ref, fingerprint: "")
    }

    @Test func reportsChangedAppearedAndGoneByRef() {
        let before = [row("e1", "textfield", "Name", value: ""), row("e2", "checkbox", "Bacon", states: ["unchecked"]),
                      row("e3", "button", "Old"), row(nil, "text", "Nothing submitted yet.")]
        let after = [row("e1", "textfield", "Name", value: "Ada"), row("e2", "checkbox", "Bacon", states: ["checked"]),
                     row("e4", "button", "New"), row(nil, "text", "Submitted: Ada")]
        #expect(Diff.lines(before: before, after: after) == [
            "~ e1 textfield \"Name\": value \"\" → \"Ada\"",
            "~ e2 checkbox \"Bacon\": states +checked -unchecked",
            "+ e4 button \"New\"",
            "- e3 button \"Old\"",
            "+ text \"Submitted: Ada\"",
            "- text \"Nothing submitted yet.\"",
        ])
    }

    @Test func identicalSnapshotsHaveNoDiff() {
        let rows = [row("e1", "button", "OK"), row(nil, "text", "Hello"), row(nil, "text", "Hello")]
        #expect(Diff.lines(before: rows, after: rows).isEmpty)
    }

    @Test func longDiffsAreCapped() {
        let after = (0..<100).map { row("e\($0)", "button", "B\($0)") }
        let lines = Diff.lines(before: [], after: after, maxLines: 10)
        #expect(lines.count == 11 && lines.last!.hasPrefix("… 90 more changes"))
    }
}

@Suite struct ScriptPolicyTests {
    @Test func findsTargetApps() {
        #expect(Scripts.targets(of: "tell application \"TextEdit\" to get name\ntell application id \"com.apple.finder\" to activate",
                                language: .applescript) == ["TextEdit", "com.apple.finder"])
        #expect(Scripts.targets(of: "Application('Safari').windows[0].name()", language: .jxa) == ["Safari"])
    }

    @Test func refusesShellAndObjCBridge() {
        #expect(Scripts.forbiddenConstruct(in: "do shell script \"rm -rf ~\"", language: .applescript) == "do shell script")
        #expect(Scripts.forbiddenConstruct(in: "ObjC.import('Foundation')", language: .jxa) == "objc.")
        #expect(Scripts.forbiddenConstruct(in: "app.doShellScript('id')", language: .jxa) == "doshellscript")
        #expect(Scripts.forbiddenConstruct(in: "tell application \"Finder\" to get name of window 1", language: .applescript) == nil)
    }

    @Test func onlyAllowedAppsMayBeTargeted() {
        var policy = Policy.defaults
        let source = "tell application \"TextEdit\" to get name of every document"
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy)?.contains("mac_script is off") == true)
        policy.script.allowedApps = ["com.apple.finder"]
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy)?.contains("may not control TextEdit") == true)
        policy.script.allowedApps = ["com.apple.TextEdit"]
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy) == nil)
        policy.denyApps = ["TextEdit"]
        #expect(Scripts.refusal(source: source, language: .applescript, policy: policy)?.contains("deny list") == true)
    }

    @Test func automationStatusMapsToOutcome() {
        typealias G = Scripts.AutomationGrant
        #expect(G(status: OSStatus(noErr)) == .granted)
        #expect(G(status: OSStatus(errAEEventNotPermitted)) == .denied)
        #expect(G(status: -1744) == .notAsked)
        #expect(G(status: OSStatus(procNotFound)) == .notRunning)
        #expect(G(status: -50) == .unknown(-50))
    }

    @Test func missingAutomationGrantFailsFastWithFix() {
        typealias G = Scripts.AutomationGrant
        let denied = G.denied.refusal(app: "Finder")
        #expect(denied?.hasPrefix("MacMCP is not authorized to control Finder.") == true)
        #expect(denied?.contains("Privacy & Security ▸ Automation ▸ MacMCP") == true)
        let notAsked = G.notAsked.refusal(app: "TextEdit")
        #expect(notAsked?.contains("never asked for consent") == true && notAsked?.contains("request_consent: true") == true)
        // Running the script is the only way to find out (or to launch the app first).
        for go in [G.granted, .notRunning, .unknown(-50)] { #expect(go.refusal(app: "Safari") == nil) }
        #expect(G.denied.isProblem && G.notAsked.isProblem && !G.granted.isProblem && !G.notRunning.isProblem)
    }

    @Test func policyRoundTripsAndMatchesByNameOrBundleID() throws {
        let path = NSTemporaryDirectory() + "policy-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try Policy.writeDefaultIfMissing(path: path))
        #expect(try !Policy.writeDefaultIfMissing(path: path))
        #expect(Policy.load(path: path) == Policy.defaults)
        #expect(Policy.matches(["com.apple.TextEdit"], bundleID: "com.apple.textedit", name: nil))
        #expect(Policy.matches(["Safari"], bundleID: "com.apple.Safari", name: "safari"))
        #expect(!Policy.matches(["Safari"], bundleID: "com.apple.finder", name: "Finder"))
    }
}

@Suite struct ScriptFilterEvasionTests {
    let policy = Policy(script: .init(allowedApps: ["com.apple.TextEdit"], timeoutSeconds: 30))

    @Test func scriptingIsOffWithNoAllowedApps() {
        // A script naming no app at all used to pass the empty allowlist.
        #expect(Scripts.refusal(source: "return 1 + 1", language: .applescript, policy: Policy())?.contains("is off") == true)
    }

    @Test func jxaNeedsAnOptIn() {
        let src = "var a = Application.currentApplication(); a.includeStandardAdditions = true; a['do'+'ShellScript']('id')"
        #expect(Scripts.refusal(source: src, language: .jxa, policy: policy)?.contains("JXA is off") == true)
        var on = policy
        on.script.jxa = true
        #expect(Scripts.refusal(source: "Application('TextEdit').name()", language: .jxa, policy: on) == nil)
    }

    @Test func spacingAndContinuationsDontHideShellCalls() {
        for src in ["do  shell script \"id\"", "do shell ¬\n script \"id\"", "DO\tSHELL\nSCRIPT \"id\"",
                    "«event sysoexec» \"id\"", "use framework \"Foundation\"", "run  script \"x\""] {
            #expect(Scripts.refusal(source: src, language: .applescript, policy: policy) != nil, "\(src)")
        }
    }

    @Test func appsMustBeNamedLiterally() {
        for src in ["set a to \"System Events\"\ntell application a to get name", "tell app (x & \"y\") to quit",
                    "get name of window 1 of application someName", "tell application id x to activate",
                    "tell «class capp» \"System Events\" to get name",
                    "set p to current application\ntell application \"TextEdit\" to get name"] {
            #expect(Scripts.refusal(source: src, language: .applescript, policy: policy) != nil, "\(src)")
        }
        for src in ["tell application \"TextEdit\" to get name", "tell application id \"com.apple.TextEdit\" to activate",
                    "tell application \"TextEdit\"\nignoring application responses\nactivate\nend ignoring\nend tell",
                    "tell application \"TextEdit\" to set t to (path to frontmost application) as text"] {
            #expect(Scripts.refusal(source: src, language: .applescript, policy: policy) == nil, "\(src)")
        }
    }

    @Test func clipboardFollowsThePolicy() {
        var p = policy
        p.clipboardRead = false
        // Actual clipboard commands are refused by event code; an app term may legitimately contain this word.
        #expect(Scripts.refusal(source: "tell application \"TextEdit\" to get clipboard format", language: .applescript, policy: p) == nil)
        #expect(Scripts.refusal(source: "tell application \"TextEdit\" to get \"the clipboard\"", language: .applescript, policy: p) == nil)
    }

    @Test func codeViewDropsStringsAndComments() {
        #expect(Scripts.code(of: "say \"do shell script\" -- do shell script\n(* (* nested *) restart *)x", language: .applescript)
            == "say \"\"  \n x")
        #expect(Scripts.code(of: "f('a\\'b') // c\n/* d */g(`t`)", language: .jxa) == "f('')  \n g(`t`)")
    }
}

@Suite struct InputMathTests {
    @Test func typedChunksNeverSplitACharacter() {
        let text = String(repeating: "a", count: 19) + "😀" + "👨‍👩‍👧‍👦" + String(repeating: "b", count: 30)
        let chunks = Input.unicodeChunks(text)
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
        for chunk in chunks {   // each chunk decodes on its own: no lone surrogate at either end
            #expect(String(utf16CodeUnits: chunk, count: chunk.count).utf16.count == chunk.count)
            #expect(!UTF16.isLeadSurrogate(chunk.last!) && !UTF16.isTrailSurrogate(chunk.first!))
        }
    }

    @Test func scrollSharesAddUpExactly() {
        #expect(Input.shares(100, steps: 40).reduce(0, +) == -100)
        #expect(Input.shares(45, steps: 40).reduce(0, +) == -45)
        #expect(Input.shares(-7, steps: 3) == [3, 2, 2])
        #expect(Input.shares(1, steps: 40).reduce(0, +) == -1)   // a small dx alongside a big dy stays small
        #expect(Input.shares(0, steps: 5) == [0, 0, 0, 0, 0])
    }
}

@Suite struct PressOutcomeTests {
    @Test func successIsPressed() {
        #expect(Actions.pressOutcome(.success, cancelled: false) == .pressed)
    }

    @Test func noReplyFromABusyAppIsNotRetriedWithTheMouse() {
        // A press that opens a sheet or menu often times out although it worked; a second click would press twice.
        #expect(Actions.pressOutcome(.cannotComplete, cancelled: false) == .unanswered)
    }

    @Test func cancellationAndRealFailuresFallThrough() {
        #expect(Actions.pressOutcome(.cannotComplete, cancelled: true) == .failed)
        #expect(Actions.pressOutcome(.actionUnsupported, cancelled: false) == .failed)
        #expect(Actions.pressOutcome(.invalidUIElement, cancelled: false) == .failed)
    }
}

@Suite struct SavePanelHintTests {
    @Test func pathInASaveNameFieldGetsAWarning() {
        let hint = Actions.savePanelNameHint(fieldLabel: "Save As:", typed: "/Users/you/Desktop/x.txt")
        #expect(hint?.contains("⇧⌘G") == true)
    }

    @Test func plainNamesAndOtherFieldsAreLeftAlone() {
        #expect(Actions.savePanelNameHint(fieldLabel: "Save As:", typed: "x.txt") == nil)
        #expect(Actions.savePanelNameHint(fieldLabel: "Search", typed: "a/b") == nil)
        #expect(Actions.savePanelNameHint(fieldLabel: nil, typed: "a/b") == nil)
    }
}
