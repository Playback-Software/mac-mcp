import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import ScreenCaptureKit
@testable import MacMCPCore

private final class BackgroundTape: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(CGEventType, pid_t?)] = []
    func post(_ event: CGEvent, pid: pid_t? = nil) { lock.withLock { events.append((event.type, pid)) } }
    var all: [(CGEventType, pid_t?)] { lock.withLock { events } }
}

@Suite struct BackgroundModeTests {
    @Test func defaultAndRelayDirectiveAreOptIn() {
        #expect(!BackgroundMode.enabled)
        #expect(AgentClient.directive(lease: nil) == nil)
        let normal = AgentClient.directive(lease: "lease", origin: "local", session: "session")
        #expect(String(decoding: normal!, as: UTF8.self) == "#mac-mcp lease=lease origin=local session=session\n")
        #expect(AgentClient.directive(lease: nil, background: true) == Data("#mac-mcp background=true\n".utf8))
    }

    @Test func routingDoesNotRepresentMouseSemanticsWithAX() {
        #expect(Actions.backgroundClickAction(button: .left, count: 1, modifiers: [], actions: [kAXPressAction]) == kAXPressAction)
        #expect(Actions.backgroundClickAction(button: .left, count: 1, modifiers: [], actions: [kAXPickAction]) == kAXPickAction)
        #expect(Actions.backgroundClickAction(button: .right, count: 1, modifiers: [], actions: [kAXShowMenuAction]) == kAXShowMenuAction)
        #expect(Actions.backgroundClickAction(button: .left, count: 2, modifiers: [], actions: [kAXPressAction]) == nil)
        #expect(Actions.backgroundClickAction(button: .left, count: 1, modifiers: .maskCommand, actions: [kAXPressAction]) == nil)
        #expect(Actions.backgroundClickAction(button: .middle, count: 1, modifiers: [], actions: [kAXPressAction]) == nil)
        #expect(Actions.backgroundClickAction(button: .left, count: 1, modifiers: [], actions: []) == nil)
    }

    @Test(arguments: ["AXFocused", "AXFrontmost", "AXMain", "AXMinimized", "AXPosition", "AXSize"])
    func focusAndWindowWritesAreExcluded(_ name: String) { #expect(!BackgroundMode.allows(attribute: name)) }

    @Test func onlyBackgroundAXRoutesAreAdmitted() {
        for name in [kAXValueAttribute, kAXSelectedAttribute, kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute] {
            #expect(BackgroundMode.allows(attribute: name))
        }
        for name in [kAXPressAction, kAXPickAction, kAXShowMenuAction, kAXIncrementAction, kAXDecrementAction, "AXScrollToVisible"] {
            #expect(BackgroundMode.allows(action: name))
        }
        #expect(!BackgroundMode.allows(action: kAXRaiseAction))
        #expect(!BackgroundMode.allows(action: "arbitrary action"))
    }

    @Test func focusProofUsesTheAppElementAndFailsClosed() {
        #expect(BackgroundMode.keyboardRefusal(pid: 42, elementPID: 42, windowPID: 42, matches: true, secure: false, secureInput: false) == nil)
        for state in [(nil, nil, false), (42, nil, true), (99, 42, true), (42, 99, true), (42, 42, false)] as [(pid_t?, pid_t?, Bool)] {
            #expect(BackgroundMode.keyboardRefusal(pid: 42, elementPID: state.0, windowPID: state.1,
                    matches: state.2, secure: false, secureInput: false)?.contains("background mode") == true)
        }
        #expect(BackgroundMode.keyboardRefusal(pid: 42, elementPID: 42, windowPID: 42,
                matches: true, secure: true, secureInput: false) != nil)
        #expect(BackgroundMode.keyboardRefusal(pid: 42, elementPID: 42, windowPID: 42,
                matches: true, secure: false, secureInput: true) != nil)
    }

    @Test func unverifiableGuardContextsRefuse() {
        #expect(BackgroundMode.contextRefusal(owned: true, finder: false, filePanel: false, secure: false) == nil)
        for state in [(false, false, false, false), (true, true, false, false), (true, false, true, false), (true, false, false, true)] {
            let refusal = BackgroundMode.contextRefusal(owned: state.0, finder: state.1, filePanel: state.2, secure: state.3)
            #expect(refusal?.contains("background mode") == true)
            #expect(refusal?.contains("without --background") == true)
        }
    }

    @Test(arguments: ["cmd+tab", "cmd+grave", "cmd+q", "cmd+h", "ctrl+left", "f5", "fn+a"])
    func systemFocusShortcutsAreRefused(_ spec: String) throws { #expect(BackgroundMode.keyRefusal(try KeySpec.parse(spec)) != nil) }

    @Test(arguments: [false, true])
    func keyboardSinkMatchesSessionMode(_ background: Bool) async throws {
        let tape = BackgroundTape()
        let environment = Input.Environment(check: { _, _ in }, post: { tape.post($0) }, postToPID: { tape.post($0, pid: $1) })
        try await BackgroundMode.$enabled.withValue(background) {
            try await Input.$environment.withValue(environment) {
                try await Input.press(try KeySpec.parse("cmd+a"), pid: 42)
                try await Input.type("hello", pid: 42)
            }
        }
        #expect(tape.all.map(\.0) == [.keyDown, .keyUp, .flagsChanged, .keyDown, .keyUp])
        #expect(tape.all.allSatisfy { $0.1 == (background ? 42 : nil) })
    }

    @Test func pointerOperationsRefuseBeforeAnyEventOrGuard() async throws {
        let tape = BackgroundTape()
        let environment = Input.Environment(check: { _, _ in Issue.record("pointer guard reached") }, post: { tape.post($0) },
                                             postToPID: { tape.post($0, pid: $1) })
        await BackgroundMode.$enabled.withValue(true) {
            await Input.$environment.withValue(environment) {
                let point = CGPoint(x: 10, y: 20)
                await #expect(throws: ActionError.self) { try await Input.move(to: point, pid: 42) }
                await #expect(throws: ActionError.self) { try await Input.click(at: point, pid: 42) }
                await #expect(throws: ActionError.self) { try await Input.hover(at: point, pid: 42) }
                await #expect(throws: ActionError.self) { try await Input.scroll(at: point, dy: 5, pid: 42) }
                await #expect(throws: ActionError.self) { try await Input.drag(from: point, to: point, pid: 42) }
                // Even an accidentally unguarded call into the adapter cannot post HID input in this mode.
                Input.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left), pid: 42)
                Input.post(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
            }
        }
        #expect(tape.all.isEmpty)
    }

    @Test func guardsAndCancellationKeepTargetedCleanupOffHID() async throws {
        let tape = BackgroundTape()
        let environment = Input.Environment(check: { _, _ in }, post: { tape.post($0) }, postToPID: { event, pid in
            tape.post(event, pid: pid)
            if event.type == .keyDown { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let task = Task {
            try await BackgroundMode.$enabled.withValue(true) {
                try await Input.$environment.withValue(environment) { try await Input.press(try KeySpec.parse("cmd+a"), pid: 42) }
            }
        }
        _ = await task.result
        #expect(tape.all.map(\.0) == [.keyDown, .keyUp, .flagsChanged])
        #expect(tape.all.allSatisfy { $0.1 == 42 })
        await #expect(throws: ActionError.self) {
            try await BackgroundMode.$enabled.withValue(true) {
                try await Input.$environment.withValue(environment) {
                    try await ActionRoute.$check.withValue({ _ in throw ActionError("Refused: route") }) {
                        try await Input.press(try KeySpec.parse("a"), pid: 42)
                    }
                }
            }
        }
        #expect(tape.all.count == 3)
    }

    @Test func backgroundContextSurvivesNativeGuardWorkers() async throws {
        let field = AXElement.application(pid: 42)
        let row = Row(kind: .interactive, role: "textfield", label: "Name", value: nil, states: [], frame: nil,
                      depth: 0, ref: "e1", fingerprint: "field")
        try await BackgroundMode.$enabled.withValue(true) {
            try await BackgroundMode.$target.withValue(field) {
                try await BackgroundMode.$row.withValue(row) {
                    let observed = try await Input.guardWork {
                        BackgroundMode.enabled && BackgroundMode.target == field && BackgroundMode.row == row
                    }
                    #expect(observed)
                }
            }
        }
        #expect(!BackgroundMode.enabled && BackgroundMode.target == nil && BackgroundMode.row == nil)
    }

    @Test func backgroundCaptureRequiresAWindowAndNeverFallsBackToTheDisplay() async {
        let error = NSError(domain: SCStreamErrorDomain, code: -3811)
        #expect(Capture.permitsDisplayFallback(hasApp: true, error: error))
        #expect(!Capture.permitsDisplayFallback(hasApp: false, error: error))
        await BackgroundMode.$enabled.withValue(true) {
            #expect(!Capture.permitsDisplayFallback(hasApp: true, error: error))
            await #expect(throws: ActionError.self) { _ = try await Capture.take(Capture.Request(), store: ScreenshotStore()) }
        }
    }

    @Test func backgroundInputStillChecksLeases() async throws {
        let directory = NSTemporaryDirectory() + "background-lease-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/lease"
        _ = try LeaseStore.acquire(holder: "person", reason: "test", minutes: 1, pid: 0, path: path)
        let tape = BackgroundTape()
        let environment = Input.Environment(check: { _, _ in }, post: { tape.post($0) }, postToPID: { tape.post($0, pid: $1) })
        await #expect(throws: ActionError.self) {
            try await BackgroundMode.$enabled.withValue(true) {
                try await Input.$leaseCheck.withValue(LeaseStore.InputCheck(token: nil, path: path)) {
                    try await Input.$environment.withValue(environment) { try await Input.press(try KeySpec.parse("a"), pid: 42) }
                }
            }
        }
        #expect(tape.all.isEmpty)
    }
}
