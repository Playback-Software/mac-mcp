import CoreGraphics
import Foundation
import Testing
@testable import MacMCPCore

private final class InputTape: @unchecked Sendable {
    struct Event {
        var type: CGEventType
        var point: CGPoint
        var flags: CGEventFlags
        var key: Int64
    }
    private let lock = NSLock()
    private var events: [Event] = []
    private var checks = 0
    func record(_ event: CGEvent) {
        lock.withLock { events.append(Event(type: event.type, point: event.location, flags: event.flags, key: event.getIntegerValueField(.keyboardEventKeycode))) }
    }
    var all: [Event] { lock.withLock { events } }
    func nextCheck() -> Int { lock.withLock { checks += 1; return checks } }
}

@Suite struct SecureInputTests {
    @Test(arguments: ["click", "drag", "key", "type"])
    func cancellationReleasesOnlyPressedInputAndStopsPromptly(_ kind: String) async throws {
        let tape = InputTape()
        let environment = Input.Environment(check: { _, _ in }, post: { event in
            tape.record(event)
            if [.leftMouseDown, .keyDown].contains(event.type) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let start = ContinuousClock.now
        let work = Task {
            try await Input.$environment.withValue(environment) {
                switch kind {
                case "click": try await Input.click(at: CGPoint(x: 10, y: 20), count: 3, modifiers: .maskCommand)
                case "drag":
                    var timing = Input.DragTiming()
                    timing.holdMs = 30_000   // only cancellation gets the drag out of this hold in time
                    timing.modifiers = .maskAlternate
                    try await Input.drag(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 500, y: 600), timing: timing)
                case "key": try await Input.press(KeySpec(key: 0, flags: .maskCommand), repeat: 5)
                default: try await Input.type(String(repeating: "x", count: 100))
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await work.value }
        // Promptness is structural: exactly one press was posted (no more of the 3 clicks, 5 keys or 100 characters
        // after the cancel), and the drag didn't sit out its 30 s hold.
        #expect(start.duration(to: .now) < .seconds(10))
        let events = tape.all
        #expect(events.filter { [.leftMouseDown, .keyDown].contains($0.type) }.count == (kind == "drag" ? 2 : 1))
        #expect(events.filter { [.leftMouseUp, .keyUp].contains($0.type) }.count == (kind == "drag" ? 2 : 1))
        #expect(events.filter { [.leftMouseUp, .keyUp, .flagsChanged].contains($0.type) }.allSatisfy { $0.flags.isEmpty })
        #expect(events.filter { $0.type == .leftMouseDragged }.allSatisfy { kind == "drag" && $0.point == CGPoint(x: 10, y: 20) })
        if kind == "drag" { #expect(events.last { $0.type == .leftMouseUp }?.point == CGPoint(x: 10, y: 20)) }
    }

    @Test func cancelledMovingDragEscapesThenReturnsToSourceBeforeReleasing() async throws {
        let tape = InputTape()
        let environment = Input.Environment(check: { _, _ in }, post: { event in
            tape.record(event)
            if event.type == .leftMouseDragged { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let work = Task {
            try await Input.$environment.withValue(environment) {
                var timing = Input.DragTiming()
                timing.holdMs = 0
                try await Input.drag(from: .zero, to: CGPoint(x: 100, y: 100), timing: timing)
            }
        }
        await #expect(throws: CancellationError.self) { try await work.value }
        let events = tape.all
        let escape = try #require(events.firstIndex { $0.type == .keyDown && $0.key == 53 })
        #expect(events[escape + 1].type == .keyUp && events[escape + 1].key == 53)
        #expect(events[escape + 2].type == .leftMouseDragged && events[escape + 2].point == .zero)
        #expect(events[escape + 3].type == .leftMouseUp && events[escape + 3].point == .zero)
        #expect(events.filter { $0.type == .leftMouseUp }.count == 1)
    }

    @Test func refusalAfterDestinationDwellCancelsInsteadOfDropping() async throws {
        let tape = InputTape()
        let destination = CGPoint(x: 100, y: 100)
        let environment = Input.Environment(check: { _, _ in
            if tape.all.filter({ $0.type == .leftMouseDragged && $0.point == destination }).count == 2 {
                throw ActionError(Input.promptRefusal)
            }
        }, post: { tape.record($0) }, dragCleanup: { _, pid in
            Input.DragCleanupState(prompts: true, focused: pid, owner: pid)
        })
        await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(environment) {
                var timing = Input.DragTiming()
                timing.holdMs = 0; timing.steps = 1; timing.dwellMs = 0
                try await Input.drag(from: .zero, to: destination, timing: timing)
            }
        }
        #expect(!tape.all.contains { $0.type == .keyDown })
        #expect(tape.all.last?.type == .leftMouseUp && tape.all.last?.point == .zero)
        #expect(!tape.all.contains { $0.type == .leftMouseUp && $0.point == destination })
    }

    @Test func successfulDragDropsOnlyAtDestinationWithoutEscape() async throws {
        let tape = InputTape(), destination = CGPoint(x: 100, y: 100)
        try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.record($0) })) {
            var timing = Input.DragTiming()
            timing.holdMs = 0; timing.steps = 1; timing.dwellMs = 0
            try await Input.drag(from: .zero, to: destination, timing: timing)
        }
        #expect(tape.all.last?.type == .leftMouseUp && tape.all.last?.point == destination)
        #expect(!tape.all.contains { $0.type == .keyDown })
    }

    @Test func slowGuardRunsOutsideSwiftTasksAndCancelsHeldDragPromptly() async throws {
        let tape = InputTape(), stalled = DispatchSemaphore(value: 0), returned = Signal()
        let environment = Input.Environment(check: { _, _ in
            #expect(withUnsafeCurrentTask { $0 == nil })
            if tape.nextCheck() == 3 {
                _ = stalled.wait(timeout: .now() + 30)   // released by the test; the drag must not wait for it
                returned.fire()
            }
        }, post: { tape.record($0) })
        let start = ContinuousClock.now
        await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(environment) {
                var timing = Input.DragTiming()
                timing.holdMs = 0
                try await Input.drag(from: .zero, to: CGPoint(x: 100, y: 100), timing: timing)
            }
        }
        #expect(start.duration(to: .now) < .seconds(10))
        #expect(tape.all.contains { $0.type == .keyDown && $0.key == 53 })
        #expect(tape.all.last?.type == .leftMouseUp && tape.all.last?.point == .zero)
        let count = tape.all.count
        stalled.signal()
        await returned.wait()   // the late guard has finished; it must not post anything now
        await Task.yield()
        #expect(tape.all.count == count)
    }

    @Test func modifiersStayHeldThroughoutOneMultiClick() async throws {
        let tape = InputTape()
        try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.record($0) })) {
            try await Input.click(at: .zero, count: 2, modifiers: .maskCommand)
        }
        let clicks = tape.all.filter { $0.type == .leftMouseDown || $0.type == .leftMouseUp }
        #expect(clicks.count == 4 && clicks.allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(tape.all.filter { $0.type == .flagsChanged }.count == 1)
        #expect(tape.all.last?.type == .flagsChanged && tape.all.last?.flags.isEmpty == true)
    }

    @Test func helperFocusAndPointerUseHostWindowOrFocusedApplication() {
        #expect(Input.focusOwner(elementPID: 2, windowPID: 1, applicationPID: 1, helper: false) == 1)
        #expect(Input.focusOwner(elementPID: 2, windowPID: 2, applicationPID: 1, helper: true) == 1)
        #expect(Input.focusOwner(elementPID: 2, windowPID: 2, applicationPID: 1, helper: false) == 2)
        #expect(Input.focusOwner(elementPID: nil, windowPID: nil, applicationPID: 1, helper: false) == 1)
        #expect(Input.focusOwner(elementPID: nil, windowPID: nil, applicationPID: 2, helper: false) == 2)
        #expect(Actions.pointerReaches(targetPID: 1, targetWindow: 1, owner: 1, hitPID: 2, hitWindow: 1, remoteOwner: false))
        #expect(Actions.pointerReaches(targetPID: 1, targetWindow: 2, owner: 1, hitPID: 2, hitWindow: 2, remoteOwner: true))
        #expect(Actions.pointerReaches(targetPID: 2, targetWindow: 1, owner: 1, hitPID: 2, hitWindow: 1, remoteOwner: true))
        #expect(Actions.pointerReaches(targetPID: 1, targetWindow: 1, owner: 2, hitPID: 2, hitWindow: 1, remoteOwner: true))
        #expect(!Actions.pointerReaches(targetPID: 1, targetWindow: 1, owner: 3, hitPID: 2, hitWindow: 1, remoteOwner: false))
        #expect(!Actions.pointerReaches(targetPID: 1, targetWindow: 1, owner: 1, hitPID: 2, hitWindow: 3, remoteOwner: true))
    }

    @Test func cancelledBeforeDownDoesNotReleaseSomeoneElsesInput() async {
        let tape = InputTape()
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.record($0) })) {
                try await Input.press(KeySpec(key: 0, flags: .maskCommand))
            }
        }
        _ = try? await work.value
        #expect(tape.all.isEmpty)
    }

    @Test func deadlineDrainsDragBeforeNextAction() async throws {
        let lock = ActionLock(), tape = InputTape()
        let environment = Input.Environment(check: { _, _ in }, post: { tape.record($0) })
        let start = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await Input.$environment.withValue(environment) {
                try await lock.run("drag", deadline: 0.08) {
                    var timing = Input.DragTiming()
                    timing.holdMs = 60_000
                    try await Input.drag(from: .zero, to: CGPoint(x: 100, y: 100), timing: timing)
                }
            }
        }
        try await lock.run("next") {
            let events = tape.all
            let downs = events.filter { $0.type == .leftMouseDown }.count
            let ups = events.filter { $0.type == .leftMouseUp }.count
            #expect(downs == ups)
            // Under load the deadline can expire during move(), before anything was pressed. Cleanup must only
            // release an actual down; when there was one, it must finish before the next action takes the lock.
            if downs > 0 {
                #expect(events.last?.type == .leftMouseUp)
                #expect(events.last?.point == .zero)
            } else {
                #expect(events.allSatisfy { $0.type == .mouseMoved })
            }
        }
        #expect(start.duration(to: .now) < .seconds(30))   // not the 60 s hold
    }

    @Test func lockWaitsForAsynchronousInputCleanup() async throws {
        let lock = ActionLock(), probe = Probe()
        let first = Task {
            try await lock.run("first", deadline: 0.05) {
                try await Input.sequence {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch {
                        await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                        probe.add("released")
                        throw error
                    }
                }
            }
        }
        await waitUntil("the first call to take the lock") { await lock.status.holder == "first" }
        try await lock.run("next") { probe.add("next") }
        _ = try? await first.value
        #expect(probe.all == ["released", "next"])
    }

    @Test func revokedSessionCannotStartLateInput() async {
        let session = Input.Session(), tape = InputTape()
        session.revoke()
        await #expect(throws: CancellationError.self) {
            try await Input.$session.withValue(session) {
                try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.record($0) })) {
                    try await Input.click(at: .zero)
                }
            }
        }
        #expect(tape.all.isEmpty && session.drained)
    }

    @Test(arguments: ["type", "keys"])
    func focusOrPromptChangeStopsTheNextChunkOrKey(_ kind: String) async throws {
        let tape = InputTape()
        let environment = Input.Environment(check: { _, _ in
            if tape.nextCheck() == 2 { throw ActionError(Input.promptRefusal) }
        }, post: { tape.record($0) })
        await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(environment) {
                if kind == "type" { try await Input.type(String(repeating: "a", count: 60), pid: 42) }
                else { try await Input.press(KeySpec(key: 0, flags: .maskCommand), repeat: 3, pid: 42) }
            }
        }
        #expect(tape.all.filter { $0.type == .keyDown }.count == 1)
        #expect(tape.all.filter { $0.type == .keyUp }.count == 1)
    }

    @Test func keyboardRequiresLiveFrontmostProcessAndItsSystemWideFocus() {
        #expect(Input.keyboardRefusal(target: 1, exists: false, frontmost: 2, focused: 2, focusName: "Other")?.contains("quit") == true)
        #expect(Input.keyboardRefusal(target: 1, exists: true, frontmost: 2, focused: 1, focusName: nil)?.contains("frontmost") == true)
        #expect(Input.keyboardRefusal(target: 1, exists: true, frontmost: 1, focused: 2, focusName: "Spotlight")?.contains("Spotlight") == true)
        #expect(Input.keyboardRefusal(target: 1, exists: true, frontmost: 1, focused: nil, focusName: nil) == nil)
        #expect(Input.keyboardRefusal(target: 1, exists: true, frontmost: 1, focused: 1, focusName: nil) == nil)
    }

    @Test func anyVisibleSecurityPromptStopsInputEvenWithSafeFocus() {
        #expect(Input.promptBlocks(hasPrompts: true, targetIsPrompt: true, focusIsPrompt: false, focusKnown: true))
        #expect(Input.promptBlocks(hasPrompts: true, targetIsPrompt: false, focusIsPrompt: true, focusKnown: true))
        #expect(Input.promptBlocks(hasPrompts: true, targetIsPrompt: false, focusIsPrompt: false, focusKnown: false))
        #expect(Input.promptBlocks(hasPrompts: true, targetIsPrompt: false, focusIsPrompt: false, focusKnown: true))
        #expect(!Input.promptBlocks(hasPrompts: false, targetIsPrompt: false, focusIsPrompt: false, focusKnown: false))
    }

    @Test func eachWheelEventRevalidatesItsReceiverAndClearsModifiersOnRefusal() async {
        let tape = InputTape()
        await #expect(throws: ActionError.self) {
            try await Input.$environment.withValue(Input.Environment(check: { _, _ in }, post: { tape.record($0) })) {
                try await Input.scroll(at: .zero, dy: 10, modifiers: .maskCommand) {
                    if tape.nextCheck() == 3 { throw ActionError("Another window is on top.") }
                }
            }
        }
        #expect(tape.all.filter { $0.type == .scrollWheel }.count == 1)
        #expect(tape.all.last?.type == .flagsChanged && tape.all.last?.flags.isEmpty == true)
    }

    @Test func wheelRequiresBothWindowOwnershipAndDescendantHit() {
        #expect(Actions.wheelReaches(receiverMatches: true, insideArea: true))
        #expect(!Actions.wheelReaches(receiverMatches: false, insideArea: true))
        #expect(!Actions.wheelReaches(receiverMatches: true, insideArea: false))
    }

    @Test func wheelGuardSharesOneWindowSnapshotPerStep() async throws {
        let tape = InputTape(), snapshots = Probe(), validations = Probe()
        let window = WindowInfo(id: 1, pid: 42, owner: "Fixture", title: "", layer: 0,
                                bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)
        let environment = Input.Environment(check: { _, _ in }, post: { tape.record($0) }, windows: {
            snapshots.add("snapshot")
            return [window]
        })
        try await Input.$environment.withValue(environment) {
            try await Input.scroll(at: CGPoint(x: 10, y: 10), dy: 2) {
                validations.add("validate")
                #expect(Input.guardWindows == [window])
                #expect(WindowServer.owner(at: CGPoint(x: 10, y: 10), in: Input.guardWindows ?? []) == 42)
            }
        }
        #expect(snapshots.all.count == 4) // move, preflight, then two wheel events
        #expect(validations.all.count == 3)
    }

}

@Suite struct InputGeometryTests {
    @Test func structuralAncestorsCannotBypassNestedClipping() {
        let frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        let visible = Actions.visibleRect(frame, clips: [CGRect(x: 0, y: 50, width: 200, height: 200), CGRect(x: 40, y: 0, width: 50, height: 200)])
        #expect(visible == CGRect(x: 40, y: 50, width: 50, height: 60))
        for role in ["AXWindow", "AXSheet", "AXSplitGroup"] {
            #expect(!Actions.hitReaches(hitWithinTarget: false, targetWithinHit: true, hitRole: role, point: CGPoint(x: 20, y: 20), visible: visible))
            #expect(Actions.hitReaches(hitWithinTarget: false, targetWithinHit: true, hitRole: role, point: CGPoint(x: 60, y: 60), visible: visible))
        }
        #expect(!Actions.hitReaches(hitWithinTarget: false, targetWithinHit: true, hitRole: "AXScrollArea", point: CGPoint(x: 60, y: 60), visible: visible))
        #expect(Actions.visibleRect(frame, clips: [CGRect(x: 500, y: 500, width: 10, height: 10)]).isNull)
    }

    /// TestHost's web field is hit as the AXGroup hosting the WKWebView, an ancestor above the page's viewports.
    @Test func ancestorsOtherThanViewportsVouchOnlyForVisiblePoints() {
        let visible = CGRect(x: 40, y: 50, width: 50, height: 60)
        let inside = CGPoint(x: 60, y: 60), clipped = CGPoint(x: 20, y: 20)
        for role in ["AXGroup", "AXSheet", "AXWindow", "AXSplitGroup"] {
            #expect(Actions.hitReaches(hitWithinTarget: false, targetWithinHit: true, hitRole: role, point: inside, visible: visible))
            #expect(!Actions.hitReaches(hitWithinTarget: false, targetWithinHit: true, hitRole: role, point: clipped, visible: visible))
        }
        for role in ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXApplication"] {
            #expect(!Actions.hitReaches(hitWithinTarget: false, targetWithinHit: true, hitRole: role, point: inside, visible: visible))
        }
        // An overlay that is neither the target, inside it nor around it covers it, whatever its role.
        #expect(!Actions.hitReaches(hitWithinTarget: false, targetWithinHit: false, hitRole: "AXGroup", point: inside, visible: visible))
        #expect(Actions.hitReaches(hitWithinTarget: true, targetWithinHit: false, hitRole: "AXStaticText", point: inside, visible: visible))
        #expect(!Actions.hitReaches(hitWithinTarget: true, targetWithinHit: false, hitRole: "AXStaticText", point: clipped, visible: visible))
    }

    @Test func groupsDoNotClipAndDeepChainsKeepKnownViewports() {
        for role in ["AXGroup", "AXSplitGroup", "AXSheet"] { #expect(!Actions.clippingRoles.contains(role)) }
        #expect(Actions.clippingRoles.contains("AXWebArea"))
        let uncontainedList = Actions.clippingAncestors(of: 0, parent: { $0 < 2 ? $0 + 1 : nil },
                                                        role: { $0 == 1 ? "AXList" : "AXWindow" })
        #expect(uncontainedList == [2])
        let scrollContent = Actions.clippingAncestors(of: 0, parent: { $0 < 2 ? $0 + 1 : nil },
                                                      role: { $0 == 1 ? "AXTable" : "AXScrollArea" })
        #expect(scrollContent == [1, 2])
        let chain = Actions.clippingAncestors(of: 0, parent: { $0 < 100 ? $0 + 1 : nil },
                                              role: { $0 == 90 ? "AXScrollArea" : "AXGroup" })
        #expect(chain == [90])
        let limited = Actions.clippingAncestors(of: 0, parent: { $0 + 1 }, role: { $0 == 10 ? "AXWindow" : "AXGroup" })
        #expect(limited == [10])
        #expect(Actions.visibleRect(CGRect(x: 0, y: 0, width: 10, height: 10), clips: []).width == 10)
    }

    @Test func scrollUsesTheAxisBlockingVisibilityAndCurrentGeometry() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = CGRect(x: 200, y: 40, width: 10, height: 10)
        #expect(Actions.scrollDisplacement(target: right, viewport: viewport).x > 0)
        #expect(Actions.scrollDisplacement(target: right, viewport: viewport).y == 0)
        #expect(Actions.scrollDisplacement(target: CGRect(x: -40, y: 40, width: 10, height: 10), viewport: viewport).x < 0)
        #expect(Actions.scrollDisplacement(target: CGRect(x: 40, y: 200, width: 10, height: 10), viewport: viewport).y > 0)
        #expect(Actions.scrollDisplacement(target: CGRect(x: 40, y: -40, width: 10, height: 10), viewport: viewport).y < 0)
        #expect(Actions.scrollDisplacement(target: right, viewport: CGRect(x: 150, y: 0, width: 100, height: 100)) == .zero)
        #expect(Actions.scrollDisplacement(target: CGRect(x: 40, y: 40, width: 10, height: 10), viewport: viewport) == .zero)
    }
}

@Suite struct SecureTypingVerificationTests {
    @Test func implicitTypingKeepsCaretAndVerifiesInsertionOrSelectionInUTF16() throws {
        #expect(Actions.typingMode(nil, hasRef: false) == .insert)
        #expect(Actions.typingMode(nil, hasRef: true) == .replace)
        #expect(Actions.typingMode("append", hasRef: false) == .append)
        #expect(Actions.expectedTypedValue(original: "a😀bc", text: "X", mode: .insert, selection: CFRange(location: 3, length: 0)) == "a😀Xbc")
        #expect(Actions.expectedTypedValue(original: "abcd", text: "X", mode: .insert, selection: CFRange(location: 1, length: 2)) == "aXd")
        #expect(Actions.expectedTypedValue(original: "abcd", text: "X", mode: .insert) == nil)
        #expect(Actions.expectedTypedValue(original: "abcd", text: "X", mode: .insert, selection: CFRange(location: Int.max, length: 1)) == nil)
        #expect(throws: ActionError.self) { try Actions.requireAppendCaret(false) }
        try Actions.requireAppendCaret(true)
    }

    @Test func appendVerifiesOriginalPlusTextIncludingWhitespace() throws {
        #expect(Actions.expectedTypedValue(original: "old ", text: " new ", mode: .append) == "old  new ")
        try Actions.verifyTypedValue("old  new ", expected: " new ", mode: .append, original: "old ")
        #expect(throws: ActionError.self) { try Actions.verifyTypedValue("already-tail", expected: "tail", mode: .append, original: "already-tail") }
        #expect(throws: ActionError.self) { try Actions.verifyTypedValue("oldnew", expected: "new", mode: .append, original: "old ") }
        #expect(Actions.expectedTypedValue(original: nil, text: "new", mode: .append) == nil)
    }

    @Test func replacementPreservesWhitespaceAndNormalizesOnlyLineEndings() throws {
        try Actions.verifyTypedValue(" a\r\nb\r", expected: " a\nb\n", mode: .replace)
        #expect(throws: ActionError.self) { try Actions.verifyTypedValue("a", expected: " a ", mode: .replace) }
        #expect(throws: ActionError.self) { try Actions.verifyTypedValue("a", expected: "a\n", mode: .replace) }
    }

    @Test func mismatchedReadableValueIsNeverSubmittedAndNeverEchoed() async {
        var submitted = false
        do {
            _ = try await Actions.verifyAndSubmit(value: "private-existing", expected: "private-requested", typedCount: 17, submit: true) { submitted = true }
            Issue.record("Mismatch accepted")
        } catch {
            #expect(!String(describing: error).contains("private-existing"))
            #expect(!String(describing: error).contains("private-requested"))
        }
        #expect(!submitted)
    }

    @Test func lostReadbackDoesNotTurnAReadableFieldIntoUnverifiedSubmission() async {
        var submitted = false
        await #expect(throws: ActionError.self) {
            _ = try await Actions.verifyAndSubmit(value: nil, expected: "expected", typedCount: 8, submit: true, previouslyReadable: true) {
                submitted = true
            }
        }
        #expect(!submitted)
    }

    @Test func matchingValueIsVerifiedBeforeSubmitAndUnreadableIsUnverified() async throws {
        var submitted = false
        #expect(try await Actions.verifyAndSubmit(value: "ok", expected: "ok", typedCount: 2, submit: true) { submitted = true })
        #expect(submitted)
        #expect(try await !Actions.verifyAndSubmit(value: nil, expected: "ok", typedCount: 2, submit: true) {})
        #expect(try await !Actions.verifyAndSubmit(value: "ok", expected: nil, typedCount: 2, submit: false) {})
    }
}
