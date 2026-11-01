import Foundation
import Testing
@testable import MacMCPCore

/// `mac-mcp setup` against a scripted host. The host has no way to click or answer anything, so what these tests can
/// observe is what the flow does: which panes it opens, what it asks, and what it says.
@Suite struct SetupFlowTests {
    final class FakeHost: SetupHost {
        var interactive = true
        var notInteractiveReason = "stdin is not a terminal"
        var said: [String] = []
        var sessionState: SetupSession? = SetupSession(onConsole: true, screenLocked: false, displayAsleep: false)
        var installed = true
        var running = true
        var startFailure: String?
        /// What `permissions()` returns on each call; the last repeats. Nil entries mean the agent didn't answer.
        var permissionScript: [PermissionReport?] = [PermissionReport(accessibility: .granted, screenRecording: .granted)]
        var openFails = false
        var answers: [String?] = []
        /// What `waitForReturn` returns on each call; the last repeats.
        var returns: [Bool?] = [false]
        var doctor = "DOCTOR REPORT"
        var registerResult = true

        var events: [String] = []
        private var permissionCalls = 0
        private var waitCalls = 0
        var prompts: [String] = []

        var text: String { said.joined(separator: "\n") }

        func say(_ text: String) { said.append(text) }
        func session() -> SetupSession? { sessionState }
        func appInstalled() -> Bool { installed }
        func agentRunning() -> Bool { running }
        func startAgent() -> String? { events.append("start"); if startFailure == nil { running = true }; return startFailure }
        func permissions() -> PermissionReport? {
            let result = permissionScript[min(permissionCalls, permissionScript.count - 1)]
            permissionCalls += 1
            return result
        }
        func open(_ pane: SettingsPane) -> Bool { events.append("open \(pane.url)"); return !openFails }
        func ask(_ prompt: String) -> String? {
            prompts.append(prompt)
            events.append("ask")
            return answers.isEmpty ? "" : answers.removeFirst()
        }
        func waitForReturn(seconds: TimeInterval) -> Bool? {
            let result = returns[min(waitCalls, returns.count - 1)]
            waitCalls += 1
            events.append("wait")
            return result
        }
        func doctorReport() -> String { events.append("doctor"); return doctor }
        func register(_ client: McpClient) -> Bool { events.append("register \(client.rawValue)"); return registerResult }
    }

    func report(_ a: PermissionReport.Grant, _ s: PermissionReport.Grant) -> PermissionReport { .init(accessibility: a, screenRecording: s) }
    let all = PermissionReport(accessibility: .granted, screenRecording: .granted)

    // MARK: guided

    @Test func everythingInPlaceOpensNothingAndOffersTheClients() {
        let host = FakeHost()
        host.answers = ["claude-code codex"]
        #expect(SetupFlow.run(host) == 0)
        #expect(!host.events.contains { $0.hasPrefix("open") } && !host.events.contains("wait"))
        #expect(host.events.filter { $0.hasPrefix("register") } == ["register claude-code", "register codex"])
        #expect(host.text.contains("DOCTOR REPORT") && host.text.contains("Setup is done."))
        #expect(host.text.contains("never clicks anything for you and never answers a macOS prompt"))
    }

    @Test func aMissingGrantOpensItsPaneAndWaitsUntilItShowsUp() {
        let host = FakeHost()
        host.permissionScript = [report(.missing, .granted), report(.missing, .granted), report(.missing, .granted), all]
        host.returns = [false]
        #expect(SetupFlow.run(host) == 0)
        #expect(host.events.first == "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(host.events.filter { $0.hasPrefix("open") }.count == 1)
        #expect(host.events.filter { $0 == "wait" }.count == 3)
        #expect(host.text.contains("In System Settings ▸ Privacy & Security ▸ Accessibility:"))
        #expect(host.text.contains("Switch on MacMCP") && host.text.contains("Device Control"))
        #expect(host.text.contains("macOS may ask for your password or Touch ID. That is yours to answer; setup can't."))
    }

    @Test func bothGrantsMissingAreHandledOneAfterTheOther() {
        let host = FakeHost()
        host.permissionScript = [report(.missing, .missing), report(.granted, .missing), report(.granted, .missing), report(.granted, .granted)]
        #expect(SetupFlow.run(host) == 0)
        let opened = host.events.filter { $0.hasPrefix("open") }
        #expect(opened == ["open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                           "open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"])
        #expect(host.text.contains("macOS may offer to quit and reopen MacMCP"))
    }

    @Test func returnSkipsAStepAndTheRunEndsNonzero() {
        let host = FakeHost()
        host.permissionScript = [report(.missing, .granted)]
        host.returns = [true]
        #expect(SetupFlow.run(host) == 1)
        #expect(host.text.contains("Skipped.") && host.text.contains("Setup is not finished"))
        // It still goes on to the rest: Screen Recording, the doctor's report and the offer.
        #expect(host.events.contains("doctor") && host.prompts.count == 1)
    }

    @Test func endOfInputSkipsToo() {
        let host = FakeHost()
        host.permissionScript = [report(.granted, .missing)]
        host.returns = [nil]
        host.answers = [nil]
        #expect(SetupFlow.run(host) == 1)
        #expect(host.text.contains("Skipped."))
    }

    @Test func givesUpAfterTheLimit() {
        let host = FakeHost()
        host.permissionScript = [report(.missing, .granted)]
        #expect(SetupFlow.run(host, maxPolls: 4) == 1)
        #expect(host.events.filter { $0 == "wait" }.count == 4)
        #expect(host.text.contains("Gave up waiting"))
    }

    @Test func anAgentThatStopsAnsweringWhileMacOSRestartsItIsWaitedFor() {
        let host = FakeHost()
        host.permissionScript = [report(.granted, .missing), nil, nil, report(.granted, .granted)]
        #expect(SetupFlow.run(host) == 0)
        #expect(host.text.contains("The agent isn't answering"))
        #expect(host.text.components(separatedBy: "The agent isn't answering").count == 2)   // said once
    }

    @Test func aGrantThatIsOnButFailsSaysToTurnItOffAndOn() {
        let host = FakeHost()
        let stale = report(.granted, .needsAttention("a test capture FAILED"))
        host.permissionScript = [stale, stale, all]
        #expect(SetupFlow.run(host) == 0)
        #expect(host.text.contains("Screen Recording is on but isn't working (a test capture FAILED)"))
        #expect(host.text.contains("Switch MacMCP off, then on again."))
    }

    @Test func aPaneThatWontOpenIsNamedSoThePersonCanOpenItThemselves() {
        let host = FakeHost()
        host.openFails = true
        host.permissionScript = [report(.missing, .granted), all]
        #expect(SetupFlow.run(host) == 0)
        #expect(host.text.contains("couldn't open it. Open System Settings ▸ Privacy & Security ▸ Accessibility yourself."))
    }

    @Test func aStoppedAgentIsStartedOnlyIfThePersonAgrees() {
        let yes = FakeHost()
        yes.running = false
        yes.answers = ["", ""]
        #expect(SetupFlow.run(yes) == 0)
        #expect(yes.events.first == "ask" && yes.events[1] == "start")
        #expect(yes.prompts[0].contains("setup doesn't answer those"))

        let no = FakeHost()
        no.running = false
        no.answers = ["n"]
        #expect(SetupFlow.run(no) == 1)
        #expect(!no.events.contains("start") && !no.events.contains { $0.hasPrefix("open") } && !no.events.contains("doctor"))

        let eof = FakeHost()
        eof.running = false
        eof.answers = [nil]
        #expect(SetupFlow.run(eof) == 1 && !eof.events.contains("start"))

        let fails = FakeHost()
        fails.running = false
        fails.startFailure = "launchctl bootstrap failed (5)"
        fails.answers = ["y"]
        #expect(SetupFlow.run(fails) == 1)
        #expect(fails.text.contains("couldn't start it: launchctl bootstrap failed (5)"))
    }

    @Test func stopsEarlyWithoutTheAppOrASession() {
        let noApp = FakeHost()
        noApp.installed = false
        #expect(SetupFlow.run(noApp) == 1)
        #expect(noApp.text.contains("scripts/build.sh") && noApp.events.isEmpty)

        for session in [SetupSession(onConsole: false, screenLocked: false, displayAsleep: false),
                        SetupSession(onConsole: true, screenLocked: true, displayAsleep: false),
                        SetupSession(onConsole: true, screenLocked: false, displayAsleep: true)] {
            let host = FakeHost()
            host.sessionState = session
            #expect(SetupFlow.run(host) == 1)
            #expect(host.events.isEmpty && host.text.contains("run `mac-mcp setup` again"))
        }
    }

    @Test func theClientOfferHandlesSeveralNamesTyposAndSkipping() {
        let host = FakeHost()
        host.answers = ["cursor vscode emacs"]
        #expect(SetupFlow.run(host) == 1)   // a name it didn't know
        #expect(host.events.filter { $0.hasPrefix("register") } == ["register cursor", "register vscode"])
        #expect(host.text.contains("emacs isn't a client I know"))

        let skip = FakeHost()
        skip.answers = [""]
        #expect(SetupFlow.run(skip) == 0)
        #expect(!skip.events.contains { $0.hasPrefix("register") })

        let failing = FakeHost()
        failing.answers = ["codex"]
        failing.registerResult = false
        #expect(SetupFlow.run(failing) == 1)
        #expect(failing.text.contains("claude-code, claude-desktop, codex, cursor, vscode"))
    }

    @Test func theDoctorReportComesBeforeTheOffer() throws {
        let host = FakeHost()
        host.answers = ["codex"]
        _ = SetupFlow.run(host)
        let doctor = try #require(host.events.firstIndex(of: "doctor"))
        let register = try #require(host.events.firstIndex(of: "register codex"))
        #expect(doctor < register)
    }

    // MARK: no terminal

    @Test func withoutATerminalItPrintsTheStepsAndDoesNothingElse() {
        let host = FakeHost()
        host.interactive = false
        host.permissionScript = [report(.missing, .needsAttention("capture failed"))]
        #expect(SetupFlow.run(host) == 1)
        #expect(host.events.isEmpty)   // no pane opened, nothing asked, nothing waited for, no registering
        let text = host.text
        #expect(text.hasPrefix("mac-mcp setup (stdin is not a terminal: printing the steps and checking once)"))
        #expect(text.contains("!!  Accessibility is not granted to MacMCP"))
        #expect(text.contains("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"))
        #expect(text.contains("- Switch on MacMCP"))
        #expect(text.contains("!!  Screen Recording is not granted to MacMCP"))
        #expect(text.contains("Privacy_ScreenCapture") && text.contains("Switch MacMCP off, then on again."))
        #expect(text.contains("Setup never changes this itself.") && text.contains("mac-mcp install --client NAME"))
        #expect(text.contains("Run `mac-mcp setup` in Terminal on the Mac"))
    }

    @Test func withoutATerminalAllGoodExitsZero() {
        let host = FakeHost()
        host.interactive = false
        #expect(SetupFlow.run(host) == 0)
        #expect(!host.text.contains("!!") && host.events.isEmpty)
    }

    @Test func withoutATerminalEachMissingThingFailsTheRun() {
        func run(_ configure: (FakeHost) -> Void) -> (Int32, String) {
            let host = FakeHost()
            host.interactive = false
            configure(host)
            return (SetupFlow.run(host), host.text)
        }
        var (code, text) = run { $0.running = false }
        #expect(code == 1 && text.contains("agent isn't running") && text.contains("can't tell"))
        (code, text) = run { $0.installed = false }
        #expect(code == 1 && text.contains("isn't installed"))
        (code, text) = run { $0.sessionState = SetupSession(onConsole: true, screenLocked: true, displayAsleep: false) }
        #expect(code == 1 && text.contains("the screen is locked"))
        (code, text) = run { $0.permissionScript = [nil] }
        #expect(code == 1 && text.contains("can't tell"))
        // Over SSH the session can't be seen, which isn't a failure by itself.
        (code, text) = run { $0.sessionState = nil }
        #expect(code == 0 && text.contains("not checked") && !text.contains("!!"))
    }

    // MARK: reading the doctor

    @Test func readsTheGrantsBackFromTheDoctorsOwnLines() {
        func parse(_ a: Bool, _ s: Bool, _ failure: String? = nil) -> PermissionReport? {
            let report = ["mac-mcp 0.1.2 — agent pid 1, client: x", "", "Permissions (granted to MacMCP.app, \(Paths.bundleID))"]
                + PermissionReport.lines(accessibility: a, screenRecording: s, captureFailure: failure)
                + ["", "Automation (mac_script, granted to MacMCP per app)", "      no apps in script.allowed_apps"]
            return PermissionReport.parse(report.joined(separator: "\n"))
        }
        #expect(parse(true, true) == all)
        #expect(parse(false, true) == report(.missing, .granted))
        #expect(parse(true, false) == report(.granted, .missing))
        #expect(parse(false, false) == report(.missing, .missing))
        if case let .needsAttention(detail)? = parse(true, true, "no windows")?.screenRecording {
            #expect(detail.contains("no windows") && detail.contains("turn MacMCP off and on again"))
        } else {
            Issue.record("a failed test capture should read as needing attention")
        }
        #expect(parse(true, true, "x")?.accessibility == .granted)
    }

    @Test func aReportWithoutThePermissionLinesParsesToNil() {
        #expect(PermissionReport.parse("") == nil)
        #expect(PermissionReport.parse("Session\n  OK  GUI session on console: yes") == nil)
        // A health problem that mentions Accessibility is not the permission line.
        #expect(PermissionReport.parse("  !!  MacMCP has lost Accessibility (\"Device Control\") permission: a person must re-enable it") == nil)
    }

    @Test func settingsURLsAreTheSecurityPanes() {
        #expect(SettingsPane.accessibility.url == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(SettingsPane.screenRecording.url == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
